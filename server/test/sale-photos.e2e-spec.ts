import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import request from 'supertest';
import sharp from 'sharp';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { newUuid } from '../src/common/ids.js';
import { PRODUCT_IMAGE_MAX_BYTES } from '../src/product-images/image-pipeline.js';
import { salePhotos } from '../src/product-images/image-store.js';
import { QueueProcessorsModule } from '../src/queue/queue.module.js';
import {
  accessToken,
  clearTenantCache,
  createTestApp,
  resetTenant,
  seedOpenShift,
  seedProduct,
  TENANT_TABLES_DEPTH_FIRST,
  type TenantFixture,
  type TestApp,
} from './support/fixture.js';
import { testId } from './support/test-ids.js';

/**
 * Sale photo evidence (10_SALE_PHOTO_EVIDENCE.md §4): `PUT /sales/:saleId/photos/:photoId`
 * (every row of the §4.3 rejection table), `GET …/photos` and `GET …/photos/:photoId/:variant`,
 * and that a replace-import leaves both the rows and the `sale-photos` volume alone.
 */
// Own directories, set before the app boots and restored after: e2e files share one process.
const SALE_DIR = mkdtempSync(join(tmpdir(), 'sale-photos-e2e-'));
const PRODUCT_DIR = mkdtempSync(join(tmpdir(), 'sale-photos-e2e-products-'));
const EXPORTS_DIR = mkdtempSync(join(tmpdir(), 'sale-photos-e2e-exports-'));
const prevEnv = {
  SALE_PHOTOS_DIR: process.env.SALE_PHOTOS_DIR,
  PRODUCT_IMAGES_DIR: process.env.PRODUCT_IMAGES_DIR,
  EXPORT_DIR: process.env.EXPORT_DIR,
};
process.env.SALE_PHOTOS_DIR = SALE_DIR;
process.env.PRODUCT_IMAGES_DIR = PRODUCT_DIR;
process.env.EXPORT_DIR = EXPORTS_DIR;

const TENANT = testId('sale-photos-e2e-a');
const OTHER = testId('sale-photos-e2e-b');

type Json = Record<string, any>;

/** A real JPEG; colours far apart give different bytes (near ones encode identically). */
const jpeg = (r: number, g = 60, b = 60, width = 1600, height = 1200) =>
  sharp({ create: { width, height, channels: 3, background: { r, g, b } } }).jpeg().toBuffer();

/** supertest body parser that keeps the raw bytes (the image, or an error envelope). */
const binary = (res: unknown, cb: (err: Error | null, body: Buffer) => void) => {
  const stream = res as NodeJS.ReadableStream;
  const chunks: Buffer[] = [];
  stream.on('data', (c: Buffer) => chunks.push(c));
  stream.on('end', () => cb(null, Buffer.concat(chunks)));
};

describe('sale photos (e2e)', () => {
  let fixture: TestApp;
  let shop: TenantFixture;
  let other: TenantFixture;
  let posToken: string;
  let backofficeToken: string;
  let webToken: string;
  let otherPosToken: string;

  const server = () => fixture.app.getHttpServer();
  const auth = (token: string) => ({ Authorization: `Bearer ${token}` });
  const takenAt = () => new Date(Date.now() - 60_000).toISOString();

  const put = (
    saleId: string,
    photoId: string,
    bytes: Buffer | string,
    opts: { token?: string | null; key?: string | null; type?: string; takenAt?: string; sortOrder?: string } = {},
  ) => {
    const q = new URLSearchParams({ takenAt: opts.takenAt ?? takenAt(), sortOrder: opts.sortOrder ?? '0' });
    const req = request(server())
      .put(`/api/v1/sales/${saleId}/photos/${photoId}?${q}`)
      .set('Content-Type', opts.type ?? 'image/jpeg');
    if (opts.token !== null) req.set(auth(opts.token ?? posToken));
    if (opts.key !== null) req.set('Idempotency-Key', opts.key ?? `salephoto-${photoId}`);
    return req.send(bytes);
  };
  const list = (saleId: string, token = posToken) =>
    request(server()).get(`/api/v1/sales/${saleId}/photos`).set(auth(token));
  const bytesOf = (saleId: string, photoId: string, variant: string, token = posToken) =>
    request(server())
      .get(`/api/v1/sales/${saleId}/photos/${photoId}/${variant}`)
      .set(auth(token))
      .buffer(true)
      .parse(binary);
  const envelope = (res: { body: Buffer }) => JSON.parse(res.body.toString('utf8')) as Json;

  const seedSale = async (tenantId: string, id: string, voided = false) => {
    await fixture.admin.query(
      `INSERT INTO sales (tenant_id, id, receipt_no, subtotal, discount, total, payment_method, voided)
       VALUES ($1::uuid, $2::uuid, $3, 100, 0, 100, 'เงินสด', $4)`,
      [tenantId, id, `RC-SP-${id.slice(0, 8)}`, voided],
    );
    return id;
  };
  const rows = async (tenantId: string, saleId?: string) =>
    (await fixture.admin.query(
      `SELECT id, sale_id, image_key, source_sha256, sort_order, uploaded_by, device_id
         FROM sale_photos WHERE tenant_id = $1 ${saleId ? 'AND sale_id = $2' : ''} ORDER BY sort_order, created_at`,
      saleId ? [tenantId, saleId] : [tenantId],
    )) as Json[];
  const filesIn = (root: string, tenantId: string) => {
    try {
      return readdirSync(join(root, tenantId)).sort();
    } catch {
      return [];
    }
  };
  const keyOf = async (photoId: string) =>
    (await fixture.admin.query(`SELECT image_key FROM sale_photos WHERE id = $1`, [photoId]))[0].image_key as string;

  beforeAll(async () => {
    fixture = await createTestApp([QueueProcessorsModule]);
  });

  beforeEach(async () => {
    shop = await resetTenant(fixture.admin, TENANT, { cache: fixture.cache });
    other = await resetTenant(fixture.admin, OTHER, { cache: fixture.cache });
    rmSync(SALE_DIR, { recursive: true, force: true });
    rmSync(PRODUCT_DIR, { recursive: true, force: true });
    posToken = accessToken({
      tenantId: TENANT,
      userId: shop.userId,
      role: 'owner',
      deviceId: shop.posDeviceId,
      deviceRole: 'pos',
    });
    backofficeToken = accessToken({
      tenantId: TENANT,
      userId: shop.userId,
      role: 'owner',
      deviceId: shop.backofficeDeviceId,
      deviceRole: 'backoffice',
    });
    webToken = accessToken({ tenantId: TENANT, userId: shop.userId, role: 'owner' });
    otherPosToken = accessToken({
      tenantId: OTHER,
      userId: other.userId,
      role: 'owner',
      deviceId: other.posDeviceId,
      deviceRole: 'pos',
    });
  });

  afterAll(async () => {
    for (const tid of [TENANT, OTHER]) {
      for (const table of TENANT_TABLES_DEPTH_FIRST) {
        await fixture.admin.query(`DELETE FROM ${table} WHERE tenant_id = $1::uuid`, [tid]);
      }
      await fixture.admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [tid]);
    }
    await fixture.app.close();
    for (const dir of [SALE_DIR, PRODUCT_DIR, EXPORTS_DIR]) rmSync(dir, { recursive: true, force: true });
    for (const [name, prev] of Object.entries(prevEnv)) {
      if (prev === undefined) delete process.env[name];
      else process.env[name] = prev;
    }
  });

  describe('PUT → GET list → GET bytes', () => {
    it('uploads: 200 + SalePhoto, files in sale-photos only, no EXIF; the list and both variants read back', async () => {
      const saleId = await seedSale(TENANT, testId('sp-happy'));
      const photoId = newUuid();
      const at = '2026-10-12T07:05:11.000Z';
      const phone = await sharp({ create: { width: 2000, height: 1500, channels: 3, background: { r: 200, g: 40, b: 40 } } })
        .jpeg()
        .withMetadata({ orientation: 1 })
        .toBuffer();
      const res = await put(saleId, photoId, phone, { takenAt: at, sortOrder: '2' });
      expect(res.status, JSON.stringify(res.body)).toBe(200);
      expect(Object.keys(res.body.data).sort()).toEqual(
        ['createdAt', 'height', 'id', 'saleId', 'sortOrder', 'takenAt', 'width'].sort(),
      );
      expect(res.body.data).toMatchObject({ id: photoId, saleId, sortOrder: 2, width: 1600, height: 1200, takenAt: at });

      const [row] = await rows(TENANT, saleId);
      expect(row).toMatchObject({ uploaded_by: shop.userId, device_id: shop.posDeviceId });
      expect(filesIn(SALE_DIR, TENANT)).toEqual([`${row.image_key}_p.webp`, `${row.image_key}_t.webp`]);
      expect(filesIn(PRODUCT_DIR, TENANT)).toEqual([]);
      const meta = await sharp(readFileSync(salePhotos.imageFilePath(TENANT, row.image_key, 'p'))).metadata();
      expect([meta.format, meta.exif, meta.icc]).toEqual(['webp', undefined, undefined]);

      const listed = await list(saleId, backofficeToken); // any device role reads
      expect(listed.status).toBe(200);
      expect(listed.headers['cache-control']).toBe('no-store');
      expect(listed.body.data).toEqual([res.body.data]);

      for (const v of ['t', 'p'] as const) {
        const got = await bytesOf(saleId, photoId, v, webToken);
        expect(got.status).toBe(200);
        expect(got.headers['content-type']).toBe('image/webp');
        expect(got.headers['cache-control']).toBe('no-store');
        expect(got.headers['x-content-type-options']).toBe('nosniff');
        expect(got.body.equals(readFileSync(salePhotos.imageFilePath(TENANT, row.image_key, v)))).toBe(true);
      }
    });

    it('lists in sort_order, then created_at; a bill with no photos (or none at all) is []', async () => {
      const saleId = await seedSale(TENANT, testId('sp-order'));
      const ids = [newUuid(), newUuid(), newUuid()];
      for (const [i, order] of [
        [0, '3'],
        [1, '0'],
        [2, '1'],
      ] as const) {
        expect((await put(saleId, ids[i], await jpeg(30 + i * 70), { sortOrder: order })).status).toBe(200);
      }
      expect((await list(saleId)).body.data.map((p: Json) => p.id)).toEqual([ids[1], ids[2], ids[0]]);
      expect((await list(testId('sp-no-such-bill'))).body.data).toEqual([]);
    });

    it('a voided bill still takes photos', async () => {
      const saleId = await seedSale(TENANT, testId('sp-voided'), true);
      expect((await put(saleId, newUuid(), await jpeg(90))).status).toBe(200);
    });
  });

  describe('replays', () => {
    it('the same Idempotency-Key + bytes replays 200 with the same body; other bytes = 409 IDEMPOTENCY_KEY_REUSED', async () => {
      const saleId = await seedSale(TENANT, testId('sp-key'));
      const photoId = newUuid();
      const img = await jpeg(120);
      const first = await put(saleId, photoId, img, { key: 'k-replay' });
      expect(first.status).toBe(200);
      const again = await put(saleId, photoId, img, { key: 'k-replay', sortOrder: '4' });
      expect(again.status).toBe(200);
      expect(again.body.data).toEqual(first.body.data);
      const reused = await put(saleId, photoId, await jpeg(10), { key: 'k-replay' });
      expect(reused.status).toBe(409);
      expect(reused.body.error.code).toBe('IDEMPOTENCY_KEY_REUSED');
      expect(await rows(TENANT, saleId)).toHaveLength(1);
    });

    it('photoId replay: a new key with the same bytes = 200 + the stored row; other bytes = 409 CLIENT_ID_REUSED', async () => {
      const saleId = await seedSale(TENANT, testId('sp-pid'));
      const otherSale = await seedSale(TENANT, testId('sp-pid-other'));
      const photoId = newUuid();
      const img = await jpeg(150);
      const first = await put(saleId, photoId, img, { key: 'k-1' });
      expect(first.status).toBe(200);

      const later = await put(saleId, photoId, img, { key: 'k-2', sortOrder: '3', takenAt: takenAt() });
      expect(later.status).toBe(200);
      expect(later.body.data).toEqual(first.body.data);

      const changed = await put(saleId, photoId, await jpeg(20), { key: 'k-3' });
      expect(changed.status).toBe(409);
      expect(changed.body.error.code).toBe('CLIENT_ID_REUSED');
      const moved = await put(otherSale, photoId, img, { key: 'k-4' });
      expect(moved.status).toBe(409);
      expect(moved.body.error.code).toBe('CLIENT_ID_REUSED');

      expect(await rows(TENANT)).toHaveLength(1);
      // The refused uploads' own files are gone again; the stored photo's stay.
      expect(filesIn(SALE_DIR, TENANT)).toEqual([`${await keyOf(photoId)}_p.webp`, `${await keyOf(photoId)}_t.webp`]);
    });
  });

  describe('five per bill', () => {
    it('the 6th photo is 409 SALE_PHOTO_LIMIT and leaves no file behind', async () => {
      const saleId = await seedSale(TENANT, testId('sp-limit'));
      for (let i = 0; i < 5; i++) {
        expect((await put(saleId, newUuid(), await jpeg(i * 50), { sortOrder: String(i) })).status).toBe(200);
      }
      const before = filesIn(SALE_DIR, TENANT);
      const sixth = await put(saleId, newUuid(), await jpeg(255, 255, 0));
      expect(sixth.status).toBe(409);
      expect(sixth.body.error).toMatchObject({ code: 'SALE_PHOTO_LIMIT', message: 'บิลนี้มีรูปหลักฐานครบ 5 รูปแล้ว' });
      expect(filesIn(SALE_DIR, TENANT)).toEqual(before);
      expect(await rows(TENANT, saleId)).toHaveLength(5);
    });

    it('concurrent uploads past the limit: with 4 stored, three at once give exactly one more', async () => {
      const saleId = await seedSale(TENANT, testId('sp-race'));
      for (let i = 0; i < 4; i++) {
        expect((await put(saleId, newUuid(), await jpeg(i * 60, 200), { sortOrder: String(i) })).status).toBe(200);
      }
      const images = await Promise.all([jpeg(10, 10, 250), jpeg(250, 10, 250), jpeg(10, 250, 250)]);
      // Hold every INSERT into sale_photos (SHARE blocks ROW EXCLUSIVE, not reads) until all three
      // uploads are parked on a lock, so their transactions overlap for certain. Without the
      // bill's FOR UPDATE all three would count 4 and insert: 7 photos.
      const blocker = fixture.admin.createQueryRunner();
      await blocker.connect();
      let results: Awaited<ReturnType<typeof put>>[];
      try {
        await blocker.startTransaction();
        await blocker.query(`LOCK TABLE sale_photos IN SHARE MODE`);
        const pending = Promise.all(images.map((img) => put(saleId, newUuid(), img, { sortOrder: '4' })));
        const start = Date.now();
        for (;;) {
          const [{ n }] = await fixture.admin.query(
            `SELECT count(*)::int AS n FROM pg_stat_activity
              WHERE datname = current_database() AND wait_event_type = 'Lock'
                AND (query LIKE '%INSERT INTO sale_photos%' OR query LIKE '%FROM sales WHERE%')`,
          );
          if (n >= 3) break;
          if (Date.now() - start > 20_000) throw new Error(`only ${n} uploads reached the lock`);
          await new Promise((r) => setTimeout(r, 50));
        }
        await blocker.commitTransaction();
        results = await pending;
      } finally {
        if (blocker.isTransactionActive) await blocker.rollbackTransaction();
        await blocker.release();
      }
      expect(results.map((r) => r.status).sort()).toEqual([200, 409, 409]);
      for (const r of results.filter((x) => x.status === 409)) expect(r.body.error.code).toBe('SALE_PHOTO_LIMIT');
      expect(await rows(TENANT, saleId)).toHaveLength(5);
    });
  });

  describe('the §4.3 rejection order', () => {
    it('a backoffice device or a web session sending an image body gets 403 DEVICE_ROLE_FORBIDDEN, not 400; no token 401', async () => {
      const saleId = await seedSale(TENANT, testId('sp-role'));
      const img = await jpeg(77);
      for (const token of [backofficeToken, webToken]) {
        const res = await put(saleId, newUuid(), img, { token });
        expect(res.status).toBe(403);
        expect(res.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');
      }
      expect((await put(saleId, newUuid(), img, { token: null })).status).toBe(401);
      expect(await rows(TENANT)).toHaveLength(0);
      expect(filesIn(SALE_DIR, TENANT)).toEqual([]);
    });

    it('a suspended shop: 403 TENANT_SUSPENDED for the pos device (a backoffice device gets DEVICE_ROLE_FORBIDDEN first)', async () => {
      const saleId = await seedSale(TENANT, testId('sp-suspended'));
      await fixture.admin.query(`UPDATE tenants SET status = 'suspended' WHERE id = $1::uuid`, [TENANT]);
      await clearTenantCache(fixture.cache, TENANT);
      const img = await jpeg(81);
      const pos = await put(saleId, newUuid(), img);
      expect([pos.status, pos.body.error.code]).toEqual([403, 'TENANT_SUSPENDED']);
      // TenantGuard checks the device role (step 5) before the shop's status (step 6), so a
      // backoffice device never learns the shop is suspended here — both answers are a 403
      // before the body is read, which is what §4.3 rows 1–2 protect.
      const bo = await put(saleId, newUuid(), img, { token: backofficeToken });
      expect([bo.status, bo.body.error.code]).toEqual([403, 'DEVICE_ROLE_FORBIDDEN']);
      expect(await rows(TENANT)).toHaveLength(0);
      expect(filesIn(SALE_DIR, TENANT)).toEqual([]);
    });

    it('a failed file write is 500: no claim is taken, no row; the same key then succeeds', async () => {
      const saleId = await seedSale(TENANT, testId('sp-write-fail'));
      const photoId = newUuid();
      const img = await jpeg(140, 20, 200);
      // A regular file where the volume's root should be: mkdir under it fails (ENOTDIR/EEXIST).
      const blocker = join(mkdtempSync(join(tmpdir(), 'sale-photos-e2e-blocked-')), 'not-a-dir');
      writeFileSync(blocker, 'x');
      process.env.SALE_PHOTOS_DIR = blocker;
      try {
        const res = await put(saleId, photoId, img, { key: 'k-write-fail' });
        expect(res.status).toBe(500);
      } finally {
        process.env.SALE_PHOTOS_DIR = SALE_DIR;
      }
      expect(await rows(TENANT)).toHaveLength(0);
      expect(
        (await fixture.admin.query(`SELECT 1 FROM idempotency_keys WHERE tenant_id = $1 AND key = 'k-write-fail'`, [TENANT]))
          .length,
      ).toBe(0);
      expect((await put(saleId, photoId, img, { key: 'k-write-fail' })).status).toBe(200);
    });

    it('503 IDEMPOTENCY_KEY_IN_FLIGHT while the original holds the key — and its files are NOT cleaned up', async () => {
      const saleId = await seedSale(TENANT, testId('sp-in-flight'));
      const photoId = newUuid();
      // The "original" request: a claim row inserted and not yet committed.
      const original = fixture.admin.createQueryRunner();
      await original.connect();
      try {
        await original.startTransaction();
        await original.query(
          `INSERT INTO idempotency_keys (tenant_id, key, endpoint, request_hash, status)
           VALUES ($1::uuid, 'k-in-flight', $2, 'x', 'in_progress')`,
          [TENANT, `PUT /api/v1/sales/${saleId}/photos/${photoId}`],
        );
        const res = await put(saleId, photoId, await jpeg(30, 160, 90), { key: 'k-in-flight' });
        expect([res.status, res.body.error.code]).toEqual([503, 'IDEMPOTENCY_KEY_IN_FLIGHT']);
        // This request created the files (none existed); a cleanup would have removed them at
        // once. They stay: they are the in-flight original's files too.
        expect(filesIn(SALE_DIR, TENANT)).toHaveLength(2);
      } finally {
        await original.rollbackTransaction();
        await original.release();
      }
      expect(await rows(TENANT)).toHaveLength(0);
    });

    it('the same photoId with the same bytes on another bill is 409 CLIENT_ID_REUSED, not a replay', async () => {
      const first = await seedSale(TENANT, testId('sp-pid-bill-1'));
      const second = await seedSale(TENANT, testId('sp-pid-bill-2'));
      const photoId = newUuid();
      const img = await jpeg(210, 120, 30);
      expect((await put(first, photoId, img, { key: 'k-bill-1' })).status).toBe(200);
      const other = await put(second, photoId, img, { key: 'k-bill-2' });
      expect([other.status, other.body.error.code]).toEqual([409, 'CLIENT_ID_REUSED']);
      expect(await rows(TENANT, second)).toHaveLength(0);
      expect((await list(second)).body.data).toEqual([]);
    });

    it('more than 3 MB is 413 PRODUCT_IMAGE_TOO_LARGE', async () => {
      const saleId = await seedSale(TENANT, testId('sp-big'));
      const big = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(PRODUCT_IMAGE_MAX_BYTES)]);
      const res = await put(saleId, newUuid(), big);
      expect(res.status).toBe(413);
      expect(res.body.error.code).toBe('PRODUCT_IMAGE_TOO_LARGE');
    });

    it('a bad id is 400 INVALID_ID, then a missing key 400 IDEMPOTENCY_KEY_INVALID, then the query 400 BAD_REQUEST', async () => {
      const saleId = await seedSale(TENANT, testId('sp-order-of-checks'));
      const img = await jpeg(33);
      const badId = await put('NOT-A-UUID', newUuid(), img, { key: null, sortOrder: '9' });
      expect([badId.status, badId.body.error.code]).toEqual([400, 'INVALID_ID']);
      const upper = await put(saleId.toUpperCase(), newUuid(), img);
      expect([upper.status, upper.body.error.code]).toEqual([400, 'INVALID_ID']);
      const noKey = await put(saleId, newUuid(), 'not an image', { key: null, sortOrder: '9' });
      expect([noKey.status, noKey.body.error.code]).toEqual([400, 'IDEMPOTENCY_KEY_INVALID']);
      // The query is judged before the body.
      const badOrder = await put(saleId, newUuid(), 'not an image', { sortOrder: '5' });
      expect([badOrder.status, badOrder.body.error.code]).toEqual([400, 'BAD_REQUEST']);
      const future = await put(saleId, newUuid(), img, { takenAt: new Date(Date.now() + 11 * 60_000).toISOString() });
      expect([future.status, future.body.error.code]).toEqual([400, 'BAD_REQUEST']);
      const notIso = await put(saleId, newUuid(), img, { takenAt: 'yesterday' });
      expect([notIso.status, notIso.body.error.code]).toEqual([400, 'BAD_REQUEST']);
      expect(await rows(TENANT)).toHaveLength(0);
    });

    it('an invalid image is 400 PRODUCT_IMAGE_INVALID: SVG, a truncated PNG, more than 4 MP, a JSON body', async () => {
      const saleId = await seedSale(TENANT, testId('sp-invalid'));
      const png = await sharp({ create: { width: 800, height: 600, channels: 3, background: { r: 1, g: 2, b: 3 } } })
        .png()
        .toBuffer();
      const huge = await sharp({ create: { width: 2049, height: 2048, channels: 3, background: { r: 9, g: 9, b: 9 } } })
        .png({ compressionLevel: 9 })
        .toBuffer();
      for (const [body, type] of [
        ['<svg xmlns="http://www.w3.org/2000/svg"/>', 'image/png'],
        [png.subarray(0, png.length >> 1), 'image/png'],
        [huge, 'image/png'],
        ['{"x":1}', 'application/json'],
      ] as const) {
        const res = await put(saleId, newUuid(), body as Buffer | string, { type });
        expect([res.status, res.body.error.code], type).toEqual([400, 'PRODUCT_IMAGE_INVALID']);
      }
      expect(filesIn(SALE_DIR, TENANT)).toEqual([]);
    });

    it('an unknown bill — or another shop’s — is 404 SALE_NOT_FOUND and the files just written are removed', async () => {
      const otherSale = await seedSale(OTHER, testId('sp-other-bill'));
      for (const saleId of [testId('sp-nobody'), otherSale]) {
        const res = await put(saleId, newUuid(), await jpeg(200, 200, 10));
        expect([res.status, res.body.error.code]).toEqual([404, 'SALE_NOT_FOUND']);
      }
      expect(filesIn(SALE_DIR, TENANT)).toEqual([]);
      expect(await rows(OTHER)).toHaveLength(0);
    });
  });

  describe('reads', () => {
    it('another shop reads [] for my bill and 404 for its bytes', async () => {
      const saleId = await seedSale(TENANT, testId('sp-cross'));
      const photoId = newUuid();
      expect((await put(saleId, photoId, await jpeg(44))).status).toBe(200);
      const theirList = await list(saleId, otherPosToken);
      expect([theirList.status, theirList.body.data]).toEqual([200, []]);
      const theirBytes = await bytesOf(saleId, photoId, 't', otherPosToken);
      expect(theirBytes.status).toBe(404);
      expect(envelope(theirBytes).error.code).toBe('NOT_FOUND');
    });

    it('bytes: wrong saleId, other variant, missing file = 404; bad id = 400; no token = 401', async () => {
      const saleId = await seedSale(TENANT, testId('sp-bytes'));
      const photoId = newUuid();
      expect((await put(saleId, photoId, await jpeg(66))).status).toBe(200);
      expect((await bytesOf(testId('sp-bytes-wrong'), photoId, 'p')).status).toBe(404);
      for (const v of ['x', 'original', 'T']) expect((await bytesOf(saleId, photoId, v)).status).toBe(404);
      const bad = await bytesOf(saleId, 'nope', 'p');
      expect([bad.status, envelope(bad).error.code]).toEqual([400, 'INVALID_ID']);
      expect((await request(server()).get(`/api/v1/sales/${saleId}/photos/${photoId}/p`)).status).toBe(401);
      expect((await request(server()).get(`/api/v1/sales/${saleId}/photos`)).status).toBe(401);
      rmSync(salePhotos.imageFilePath(TENANT, await keyOf(photoId), 'p'));
      expect((await bytesOf(saleId, photoId, 'p')).status).toBe(404);
      expect((await bytesOf(saleId, photoId, 't')).status).toBe(200);
    });
  });

  describe('replace-import (owner decision C)', () => {
    const appExport = (): Json =>
      JSON.parse(
        readFileSync(new URL('../../frontend/test/fixtures/app_export_from_synthetic.json', import.meta.url), 'utf8'),
      );
    const ownerToken = () =>
      accessToken({
        tenantId: TENANT,
        userId: shop.userId,
        role: 'owner',
        deviceId: shop.backofficeDeviceId,
        deviceRole: 'backoffice',
      });
    async function importOk(body: Json, query = ''): Promise<Json> {
      const res = await request(server())
        .post(`/api/v1/backup/import${query}`)
        .set(auth(ownerToken()))
        .send(body);
      expect(res.status, JSON.stringify(res.body)).toBe(202);
      const start = Date.now();
      while (Date.now() - start < 45_000) {
        const row = (
          await fixture.admin.query(`SELECT status, result, error FROM import_jobs WHERE id = $1`, [res.body.data.jobId])
        )[0];
        if (row?.status === 'succeeded') return row.result;
        if (row?.status === 'failed') throw new Error(`import failed: ${row.error}`);
        await new Promise((r) => setTimeout(r, 150));
      }
      throw new Error('import job did not finish');
    }

    it('keeps every sale_photos row and every file in sale-photos (old orphans included); the bill comes back with its photos', async () => {
      const snap = appExport();
      await importOk(snap);
      const saleId = (
        await fixture.admin.query(`SELECT id FROM sales WHERE tenant_id = $1 ORDER BY id LIMIT 1`, [TENANT])
      )[0].id as string;
      const photoId = newUuid();
      const uploaded = await put(saleId, photoId, await jpeg(180, 90, 30));
      expect(uploaded.status).toBe(200);

      // An unreferenced, old file in sale-photos: the import's orphan sweep would remove it if it
      // were ever pointed at this volume — it must stay bound to product-images.
      const orphan = 'f'.repeat(32);
      mkdirSync(join(SALE_DIR, TENANT), { recursive: true });
      for (const v of ['t', 'p'] as const) {
        const path = salePhotos.imageFilePath(TENANT, orphan, v);
        writeFileSync(path, 'old');
        utimesSync(path, new Date('2020-01-01T00:00:00Z'), new Date('2020-01-01T00:00:00Z'));
      }
      const filesBefore = filesIn(SALE_DIR, TENANT);
      const rowsBefore = await rows(TENANT);

      const result = await importOk(snap, `?mode=replace&confirmShopName=${encodeURIComponent(snap.sa_settings.shopName)}`);
      expect(result.mode).toBe('replace');
      expect(result.deleted.sales).toBeGreaterThan(0);

      expect(await rows(TENANT)).toEqual(rowsBefore);
      expect(filesIn(SALE_DIR, TENANT)).toEqual(filesBefore);
      for (const v of ['t', 'p'] as const) expect(existsSync(salePhotos.imageFilePath(TENANT, orphan, v))).toBe(true);
      // The same file brought the bill back under the same id: its photo is there again.
      const listed = await list(saleId);
      expect(listed.body.data).toEqual([uploaded.body.data]);
      expect((await bytesOf(saleId, photoId, 'p')).status).toBe(200);
    }, 150_000);
  });
});

describe('sale photo reads hold no pooled connection (DB_POOL_SIZE = 1)', () => {
  let fixture: TestApp;
  const TENANT_1 = testId('sale-photos-e2e-pool');
  const prevPool = process.env.DB_POOL_SIZE;

  beforeAll(async () => {
    process.env.DB_POOL_SIZE = '1';
    fixture = await createTestApp();
  });

  afterAll(async () => {
    for (const table of TENANT_TABLES_DEPTH_FIRST) {
      await fixture.admin.query(`DELETE FROM ${table} WHERE tenant_id = $1::uuid`, [TENANT_1]);
    }
    await fixture.admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT_1]);
    await fixture.app.close();
    if (prevPool === undefined) delete process.env.DB_POOL_SIZE;
    else process.env.DB_POOL_SIZE = prevPool;
  });

  it('byte streams, list reads and a POST /sales at once all finish with one connection in the pool', async () => {
    const shop = await resetTenant(fixture.admin, TENANT_1, { cache: fixture.cache });
    const token = accessToken({
      tenantId: TENANT_1,
      userId: shop.userId,
      role: 'owner',
      deviceId: shop.posDeviceId,
      deviceRole: 'pos',
    });
    const saleId = testId('sp-pool-sale');
    await fixture.admin.query(
      `INSERT INTO sales (tenant_id, id, receipt_no, subtotal, discount, total, payment_method)
       VALUES ($1::uuid, $2::uuid, 'RC-SP-POOL', 100, 0, 100, 'เงินสด')`,
      [TENANT_1, saleId],
    );
    const photoId = newUuid();
    const up = await request(fixture.app.getHttpServer())
      .put(`/api/v1/sales/${saleId}/photos/${photoId}?takenAt=${new Date().toISOString()}&sortOrder=0`)
      .set('Authorization', `Bearer ${token}`)
      .set('Idempotency-Key', newUuid())
      .set('Content-Type', 'image/jpeg')
      .send(await jpeg(5, 5, 5, 2000, 1500));
    expect(up.status, JSON.stringify(up.body)).toBe(200);

    const productId = testId('sp-pool-product');
    await seedProduct(fixture.admin, TENANT_1, { id: productId, partNo: 'SP-POOL', name: 'Pool', price: 85, cost: 50, stock: 10 });
    await seedOpenShift(fixture.admin, TENANT_1, shop.posDeviceId, { userId: shop.userId });
    const newSaleId = testId('sp-pool-new-sale');
    const sale = request(fixture.app.getHttpServer())
      .post('/api/v1/sales')
      .set('Authorization', `Bearer ${token}`)
      .set('Idempotency-Key', newUuid())
      .send({
        id: newSaleId,
        subtotal: '85.00',
        discount: '0.00',
        total: '85.00',
        paymentMethod: 'เงินสด',
        items: [{ lineNo: 1, productId, name: 'Pool', qty: 1, price: '85.00' }],
      });
    const reads = Array.from({ length: 12 }, (_, i) =>
      i % 2 === 0
        ? request(fixture.app.getHttpServer())
            .get(`/api/v1/sales/${saleId}/photos/${photoId}/p`)
            .set('Authorization', `Bearer ${token}`)
            .buffer(true)
            .parse(binary)
        : request(fixture.app.getHttpServer()).get(`/api/v1/sales/${saleId}/photos`).set('Authorization', `Bearer ${token}`),
    );
    const [saleRes, ...results] = await Promise.all([sale, ...reads]);
    expect(saleRes.status, JSON.stringify(saleRes.body)).toBe(201);
    expect(results.map((r) => r.status)).toEqual(Array(12).fill(200));
    const stock = await fixture.admin.query(`SELECT stock FROM products WHERE tenant_id = $1 AND id = $2`, [
      TENANT_1,
      productId,
    ]);
    expect(stock[0].stock).toBe(9);
  });
});
