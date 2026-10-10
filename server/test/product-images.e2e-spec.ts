import { randomUUID } from 'node:crypto';
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import request from 'supertest';
import sharp from 'sharp';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { importUploadDir } from '../src/backup/export-file.js';
import { imageFilePath } from '../src/product-images/image-store.js';
import { QueueProcessorsModule } from '../src/queue/queue.module.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedProduct,
  TENANT_TABLES_DEPTH_FIRST,
  type TestApp,
  type TenantFixture,
} from './support/fixture.js';
import { testId } from './support/test-ids.js';
import { backupDataJson, unzipEntries, zipOf, zipWithRawNames } from './support/zip.js';

/**
 * Product images (owner request 2026-10-10, contract `product-images-contract.md` §1–§4):
 * `PUT`/`DELETE /products/:id/image` (owner-only, idempotent, sharp, orphan cleanup), the
 * product wire's `imageKey` on the pull, and the backup ZIP export/import with images.
 */
// Own directories, set before the app boots and restored after: e2e files share one process.
const IMAGES_DIR = mkdtempSync(join(tmpdir(), 'product-images-e2e-'));
const EXPORTS_DIR = mkdtempSync(join(tmpdir(), 'product-images-e2e-exports-'));
const prevImages = process.env.PRODUCT_IMAGES_DIR;
const prevExports = process.env.EXPORT_DIR;
process.env.PRODUCT_IMAGES_DIR = IMAGES_DIR;
process.env.EXPORT_DIR = EXPORTS_DIR;

const TENANT = testId('product-images-e2e-a');
const OTHER = testId('product-images-e2e-b');
const TARGET = testId('product-images-e2e-c');

type Json = Record<string, any>;

/** A real JPEG; colours far apart give different bytes (near ones encode identically). */
const jpeg = (r: number, g = 60, b = 60, width = 1600, height = 1200) =>
  sharp({ create: { width, height, channels: 3, background: { r, g, b } } }).jpeg().toBuffer();

describe('product images (e2e)', () => {
  let fixture: TestApp;
  let shop: TenantFixture;
  let target: TenantFixture;
  let ownerToken: string;
  let otherToken: string;
  let targetToken: string;

  const server = () => fixture.app.getHttpServer();
  const auth = (token: string) => ({ Authorization: `Bearer ${token}` });
  const put = (
    productId: string,
    bytes: Buffer | string,
    opts: { token?: string; key?: string | null; type?: string } = {},
  ) => {
    const req = request(server())
      .put(`/api/v1/products/${productId}/image`)
      .set(auth(opts.token ?? ownerToken))
      .set('Content-Type', opts.type ?? 'image/jpeg');
    if (opts.key !== null) req.set('Idempotency-Key', opts.key ?? randomUUID());
    return req.send(bytes);
  };
  const del = (productId: string, token = ownerToken, key = randomUUID()) =>
    request(server()).delete(`/api/v1/products/${productId}/image`).set(auth(token)).set('Idempotency-Key', key);
  const filesOf = (tenantId: string, key: string) =>
    [imageFilePath(tenantId, key, 't'), imageFilePath(tenantId, key, 'p')].map((p) => existsSync(p));
  const tenantFiles = (tenantId: string) => {
    try {
      return readdirSync(join(IMAGES_DIR, tenantId));
    } catch {
      return [];
    }
  };
  const product = (id: string, partNo: string) =>
    seedProduct(fixture.admin, TENANT, { id, partNo, name: partNo, price: 100, cost: 50, stock: 5 });
  const imageKeyInDb = async (tenantId: string, id: string) =>
    (await fixture.admin.query(`SELECT image_key FROM products WHERE tenant_id = $1 AND id = $2`, [tenantId, id]))[0]
      ?.image_key ?? null;

  beforeAll(async () => {
    fixture = await createTestApp([QueueProcessorsModule]);
  });

  beforeEach(async () => {
    shop = await resetTenant(fixture.admin, TENANT, { cache: fixture.cache });
    await resetTenant(fixture.admin, OTHER, { cache: fixture.cache });
    target = await resetTenant(fixture.admin, TARGET, { cache: fixture.cache });
    rmSync(IMAGES_DIR, { recursive: true, force: true });
    ownerToken = accessToken({
      tenantId: TENANT,
      userId: shop.userId,
      role: 'owner',
      deviceId: shop.backofficeDeviceId,
      deviceRole: 'backoffice',
    });
    otherToken = accessToken({ tenantId: OTHER, role: 'owner' });
    targetToken = accessToken({
      tenantId: TARGET,
      userId: target.userId,
      role: 'owner',
      deviceId: target.backofficeDeviceId,
      deviceRole: 'backoffice',
    });
  });

  afterAll(async () => {
    for (const tid of [TENANT, OTHER, TARGET]) {
      for (const table of TENANT_TABLES_DEPTH_FIRST) {
        await fixture.admin.query(`DELETE FROM ${table} WHERE tenant_id = $1::uuid`, [tid]);
      }
      await fixture.admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [tid]);
    }
    await fixture.app.close();
    rmSync(IMAGES_DIR, { recursive: true, force: true });
    rmSync(EXPORTS_DIR, { recursive: true, force: true });
    if (prevImages === undefined) delete process.env.PRODUCT_IMAGES_DIR;
    else process.env.PRODUCT_IMAGES_DIR = prevImages;
    if (prevExports === undefined) delete process.env.EXPORT_DIR;
    else process.env.EXPORT_DIR = prevExports;
  });

  describe('PUT / DELETE /products/:id/image', () => {
    it('uploads: both WebP variants on disk, imageKey on the product wire and on the keyset pull', async () => {
      const id = await product(testId('pi-p1'), 'PI-001');
      const cursor = (
        await fixture.admin.query(
          `SELECT to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS c FROM products WHERE tenant_id = $1 AND id = $2`,
          [TENANT, id],
        )
      )[0].c as string;

      const res = await put(id, await jpeg(200));
      expect(res.status, JSON.stringify(res.body)).toBe(200);
      const key = res.body.data.imageKey as string;
      expect(key).toMatch(/^[0-9a-f]{32}$/);
      expect(res.body.data).toMatchObject({ id, partNo: 'PI-001' });
      expect(filesOf(TENANT, key)).toEqual([true, true]);
      const meta = await sharp(readFileSync(imageFilePath(TENANT, key, 'p'))).metadata();
      expect([meta.format, meta.width, meta.height]).toEqual(['webp', 1024, 768]);
      expect((await sharp(readFileSync(imageFilePath(TENANT, key, 't'))).metadata()).width).toBe(256);
      expect(await imageKeyInDb(TENANT, id)).toBe(key);

      const byId = await request(server()).get(`/api/v1/products/${id}`).set(auth(ownerToken));
      expect(byId.body.data.imageKey).toBe(key);
      // Setting the image bumped updated_at, so the keyset pull past the old cursor carries it.
      const pull = await request(server())
        .get(`/api/v1/products?updatedSince=${encodeURIComponent(cursor)}`)
        .set(auth(ownerToken));
      expect(pull.status).toBe(200);
      expect(pull.body.data.find((p: Json) => p.id === id)?.imageKey).toBe(key);
      // A product with no image reads null, never absent.
      const bare = await product(testId('pi-p1b'), 'PI-001B');
      const bareRes = await request(server()).get(`/api/v1/products/${bare}`).set(auth(ownerToken));
      expect(bareRes.body.data.imageKey).toBeNull();
    });

    it('is idempotent over the bytes: the same key + bytes replays, the same key + other bytes is 409', async () => {
      const id = await product(testId('pi-p2'), 'PI-002');
      const key = randomUUID();
      const first = await put(id, await jpeg(10), { key });
      const again = await put(id, await jpeg(10), { key });
      expect(first.status).toBe(200);
      expect(again.status).toBe(200);
      expect(again.body.data).toEqual(first.body.data);
      const changed = await put(id, await jpeg(240), { key });
      expect(changed.status).toBe(409);
      expect(changed.body.error.code).toBe('IDEMPOTENCY_KEY_REUSED');
      // The refused upload's files did not stay behind.
      expect(tenantFiles(TENANT).sort()).toEqual(
        [`${first.body.data.imageKey}_p.webp`, `${first.body.data.imageKey}_t.webp`].sort(),
      );
      const noKey = await put(id, await jpeg(120), { key: null });
      expect(noKey.status).toBe(400);
      expect(noKey.body.error.code).toBe('IDEMPOTENCY_KEY_INVALID');
    });

    it('replace removes the old files; delete clears imageKey and removes the files', async () => {
      const id = await product(testId('pi-p3'), 'PI-003');
      const a = (await put(id, await jpeg(30))).body.data.imageKey as string;
      const b = (await put(id, await jpeg(230))).body.data.imageKey as string;
      expect(b).not.toBe(a);
      expect(filesOf(TENANT, a)).toEqual([false, false]);
      expect(filesOf(TENANT, b)).toEqual([true, true]);

      const cleared = await del(id);
      expect(cleared.status).toBe(200);
      expect(cleared.body.data.imageKey).toBeNull();
      expect(await imageKeyInDb(TENANT, id)).toBeNull();
      expect(filesOf(TENANT, b)).toEqual([false, false]);
      // Deleting an image that is already gone is fine.
      expect((await del(id)).status).toBe(200);
    });

    it('removes an old key only once no product of the shop references it', async () => {
      const p1 = await product(testId('pi-p4'), 'PI-004');
      const p2 = await product(testId('pi-p5'), 'PI-005');
      const same = await jpeg(40);
      const k1 = (await put(p1, same)).body.data.imageKey as string;
      const k2 = (await put(p2, same)).body.data.imageKey as string;
      expect(k2).toBe(k1); // content-addressed

      await put(p1, await jpeg(140));
      expect(filesOf(TENANT, k1)).toEqual([true, true]); // p2 still shows it
      await del(p2);
      expect(filesOf(TENANT, k1)).toEqual([false, false]);
    });

    it('owner only: another role is 403 OWNER_ONLY and writes nothing', async () => {
      const id = await product(testId('pi-p6'), 'PI-006');
      const cashier = accessToken({ tenantId: TENANT, userId: shop.userId, role: 'cashier' });
      const res = await put(id, await jpeg(50), { token: cashier });
      expect(res.status).toBe(403);
      expect(res.body.error.code).toBe('OWNER_ONLY');
      expect(tenantFiles(TENANT)).toEqual([]);
      const removed = await del(id, cashier);
      expect(removed.status).toBe(403);
      expect(removed.body.error.code).toBe('OWNER_ONLY');
    });

    it("another shop's product is 404, and the upload leaves no file", async () => {
      const id = await product(testId('pi-p7'), 'PI-007');
      const res = await put(id, await jpeg(60), { token: otherToken });
      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('PRODUCT_NOT_FOUND');
      expect(tenantFiles(OTHER)).toEqual([]);
      expect((await del(id, otherToken)).status).toBe(404);
      expect(await imageKeyInDb(TENANT, id)).toBeNull();
      expect((await put(testId('pi-nope'), await jpeg(61))).status).toBe(404);
    });

    it('a file that is not a JPEG/PNG/WebP is 400 PRODUCT_IMAGE_INVALID', async () => {
      const id = await product(testId('pi-p8'), 'PI-008');
      for (const [bytes, type] of [
        ['definitely not an image', 'image/jpeg'],
        ['<svg xmlns="http://www.w3.org/2000/svg"/>', 'image/png'],
        [await sharp({ create: { width: 4, height: 4, channels: 3, background: 'red' } }).gif().toBuffer(), 'image/webp'],
        [(await jpeg(70)).subarray(0, 500), 'image/jpeg'],
        ['{"image":"x"}', 'application/json'],
      ] as Array<[Buffer | string, string]>) {
        const res = await put(id, bytes, { type });
        expect(res.status, `${type}: ${JSON.stringify(res.body)}`).toBe(400);
        expect(res.body.error.code).toBe('PRODUCT_IMAGE_INVALID');
      }
      expect(tenantFiles(TENANT)).toEqual([]);
    });

    it('more than 3 MB is 413 PRODUCT_IMAGE_TOO_LARGE', async () => {
      const id = await product(testId('pi-p9'), 'PI-009');
      const big = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(3 * 1024 * 1024)]);
      const res = await put(id, big);
      expect(res.status).toBe(413);
      expect(res.body.error.code).toBe('PRODUCT_IMAGE_TOO_LARGE');
    });
  });

  describe('backup ZIP', () => {
    async function waitForExport(jobId: string): Promise<Json> {
      const start = Date.now();
      while (Date.now() - start < 45000) {
        const res = await request(server()).get(`/api/v1/backup/jobs/${jobId}`).set(auth(ownerToken));
        if (res.body.data?.status === 'completed') return res.body.data;
        if (res.body.data?.status === 'failed') throw new Error(`export failed: ${res.body.data.error}`);
        await new Promise((r) => setTimeout(r, 150));
      }
      throw new Error('export did not finish');
    }

    async function exportZip(): Promise<Buffer> {
      const started = await request(server()).post('/api/v1/backup/export').set(auth(ownerToken));
      expect(started.status).toBe(202);
      const job = await waitForExport(started.body.data.jobId);
      const dl = await request(server())
        .get(job.data.downloadPath)
        .set(auth(ownerToken))
        .buffer(true)
        .parse((res, cb) => {
          const chunks: Buffer[] = [];
          res.on('data', (c: Buffer) => chunks.push(c));
          res.on('end', () => cb(null, Buffer.concat(chunks)));
        });
      expect(dl.status).toBe(200);
      expect(dl.headers['content-type']).toBe('application/zip');
      return dl.body as Buffer;
    }

    const importInto = (token: string, body: Buffer | Json, query = '') => {
      const req = request(server()).post(`/api/v1/backup/import${query}`).set(auth(token));
      return Buffer.isBuffer(body) ? req.set('Content-Type', 'application/zip').send(body) : req.send(body);
    };

    async function importOk(token: string, body: Buffer | Json, query = ''): Promise<Json> {
      const res = await importInto(token, body, query);
      expect(res.status, JSON.stringify(res.body)).toBe(202);
      const jobId = res.body.data.jobId as string;
      const start = Date.now();
      while (Date.now() - start < 45000) {
        const row = (await fixture.admin.query(`SELECT status, result, error FROM import_jobs WHERE id = $1`, [jobId]))[0];
        if (row.status === 'succeeded') return row.result;
        if (row.status === 'failed') throw new Error(`import failed: ${row.error}`);
        await new Promise((r) => setTimeout(r, 150));
      }
      throw new Error('import did not finish');
    }

    it('round trip: the export ZIP carries each image; importing it re-creates the image files', async () => {
      const withImage = await product(testId('pi-z1'), 'PI-Z1');
      await product(testId('pi-z2'), 'PI-Z2');
      const key = (await put(withImage, await jpeg(90))).body.data.imageKey as string;

      const zip = await exportZip();
      const entries = await unzipEntries(zip);
      expect([...entries.keys()].sort()).toEqual(['data.json', `images/${key}.webp`]);
      expect(entries.get(`images/${key}.webp`)).toEqual(readFileSync(imageFilePath(TENANT, key, 'p')));
      const data = await backupDataJson(zip);
      expect(data.sa_products.find((p: Json) => p.id === withImage).imageKey).toBe(key);
      expect(data.sa_products.find((p: Json) => p.id === testId('pi-z2')).imageKey).toBeUndefined();

      const result = await importOk(targetToken, zip);
      expect(result.images).toEqual({ imported: 1, missing: 0, rejected: 0 });
      const imported = await imageKeyInDb(TARGET, withImage);
      expect(imported).toMatch(/^[0-9a-f]{32}$/);
      expect(filesOf(TARGET, imported)).toEqual([true, true]);
      expect(await imageKeyInDb(TARGET, testId('pi-z2'))).toBeNull();
      // The uploaded ZIP is gone once the job is done.
      expect(readdirSync(join(EXPORTS_DIR, TARGET, 'import'))).toEqual([]);
      const pulled = await request(server()).get(`/api/v1/products/${withImage}`).set(auth(targetToken));
      expect(pulled.body.data.imageKey).toBe(imported);

      // Replace import with a file whose product has no image: the old files are swept, and the
      // pre-import copy (a ZIP) still holds the image it replaced.
      const noImages = structuredClone(data);
      for (const p of noImages.sa_products) delete p.imageKey;
      const shopName = (
        await fixture.admin.query(
          `SELECT COALESCE(s.shop_name, t.shop_name) AS n FROM tenants t LEFT JOIN settings s ON s.tenant_id = t.id WHERE t.id = $1`,
          [TARGET],
        )
      )[0].n as string;
      const replaced = await importOk(
        targetToken,
        await zipOf([['data.json', JSON.stringify(noImages)]]),
        `?mode=replace&confirmShopName=${encodeURIComponent(shopName)}`,
      );
      expect(replaced.images).toEqual({ imported: 0, missing: 0, rejected: 0 });
      expect(await imageKeyInDb(TARGET, withImage)).toBeNull();
      expect(tenantFiles(TARGET)).toEqual([]);
      const copy = await unzipEntries(readFileSync(replaced.preImportExport.file));
      expect(copy.has(`images/${imported}.webp`)).toBe(true);
    }, 120000);

    it('a legacy .json import still works, with no images', async () => {
      const id = await product(testId('pi-j1'), 'PI-J1');
      await put(id, await jpeg(100));
      const data = await backupDataJson(await exportZip());
      const result = await importOk(targetToken, data);
      expect(result.images).toBeUndefined();
      expect(await imageKeyInDb(TARGET, id)).toBeNull();
      expect(tenantFiles(TARGET)).toEqual([]);
    }, 90000);

    it('an image the ZIP lacks, or one sharp refuses, imports as no image', async () => {
      const id1 = await product(testId('pi-m1'), 'PI-M1');
      const id2 = await product(testId('pi-m2'), 'PI-M2');
      const data = await backupDataJson(await exportZip());
      const broken = '3'.repeat(32);
      data.sa_products.find((p: Json) => p.id === id1).imageKey = broken;
      data.sa_products.find((p: Json) => p.id === id2).imageKey = '4'.repeat(32);
      const zip = await zipOf([
        ['data.json', JSON.stringify(data)],
        [`images/${broken}.webp`, 'RIFF....WEBP but not really'],
      ]);
      const result = await importOk(targetToken, zip);
      expect(result.images).toEqual({ imported: 0, missing: 1, rejected: 1 });
      expect(await imageKeyInDb(TARGET, id1)).toBeNull();
      expect(await imageKeyInDb(TARGET, id2)).toBeNull();
    }, 90000);

    it('refuses a malicious ZIP with 400 BACKUP_ZIP_INVALID before any job, and keeps no upload', async () => {
      const data = JSON.stringify({ __meta: { version: 2 }, sa_products: [] });
      for (const zip of [
        await zipWithRawNames([
          ['data.json', data],
          ['../../evil.webp', 'x'],
        ]),
        await zipOf([
          ['data.json', data],
          ['run.sh', 'echo hi'],
        ]),
        await zipOf([['notes.txt', 'no data.json at all']]),
        Buffer.from('PK not a zip'),
      ]) {
        const res = await importInto(targetToken, zip);
        expect(res.status, JSON.stringify(res.body)).toBe(400);
        expect(res.body.error.code).toBe('BACKUP_ZIP_INVALID');
      }
      const jobs = await fixture.admin.query(`SELECT count(*)::int AS n FROM import_jobs WHERE tenant_id = $1`, [TARGET]);
      expect(jobs[0].n).toBe(0);
      expect(readdirSync(importUploadDir())).toEqual([]);
    });
  });
});
