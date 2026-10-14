import { existsSync, readFileSync } from 'node:fs';
import request from 'supertest';
import { backupDataJson } from './support/zip.js';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { newUuid } from '../src/common/ids.js';
import { QueueProcessorsModule } from '../src/queue/queue.module.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedOpenShift,
  TENANT_TABLES_DEPTH_FIRST,
  type TenantFixture,
  type TestApp,
} from './support/fixture.js';
import { testId } from './support/test-ids.js';

/**
 * Settings → กู้คืนข้อมูล on the API build: the shop owner imports a backup into their own shop
 * through `POST /api/v1/backup/import` (+ `GET …/:jobId`, `GET …` for the latest job).
 *
 * Two files: the one the app's own backup button saves (`frontend/test/app_export_fixture_test.dart`)
 * and a sanitized copy of the owner's real sample (`test/fixtures/owner-backup-sanitized.json`:
 * the old app's random RC numbers, a few of this server's own, an open cash drawer, a parked
 * bill). The owner's real file — never committed (customer names and phones) — runs the same
 * flow with `SAMPLE_FILE=/path/to/backup.json corepack pnpm test:e2e test/owner-import.e2e-spec.ts`.
 */
type Json = Record<string, any>;

describe('owner import: POST /backup/import (e2e)', () => {
  let fixture: TestApp;
  let shop: TenantFixture;
  let ownerToken: string;
  let posToken: string;
  const TENANT_ID = testId('owner-import-e2e-shop');
  const OTHER_TENANT_ID = testId('owner-import-e2e-other');

  const appExport = (): Json =>
    JSON.parse(readFileSync(new URL('../../frontend/test/fixtures/app_export_from_synthetic.json', import.meta.url), 'utf8'));
  const ownerSample = (): Json =>
    JSON.parse(
      readFileSync(process.env.SAMPLE_FILE ?? new URL('./fixtures/owner-backup-sanitized.json', import.meta.url), 'utf8'),
    );

  const server = () => fixture.app.getHttpServer();
  const post = (token: string, body: unknown, query = '') =>
    request(server()).post(`/api/v1/backup/import${query}`).set('Authorization', `Bearer ${token}`).send(body as object);
  const status = (token: string, jobId: string) =>
    request(server()).get(`/api/v1/backup/import/${jobId}`).set('Authorization', `Bearer ${token}`);
  const replaceQuery = (name: string) => `?mode=replace&confirmShopName=${encodeURIComponent(name)}`;

  async function waitForJob(jobId: string): Promise<Json> {
    const start = Date.now();
    while (Date.now() - start < 45000) {
      const res = await status(ownerToken, jobId);
      expect(res.status).toBe(200);
      if (res.body.data.status === 'succeeded' || res.body.data.status === 'failed') return res.body.data;
      await new Promise((r) => setTimeout(r, 150));
    }
    throw new Error('import job did not finish');
  }

  /** POST, wait, and expect success — returns the job's `import_jobs.result`. */
  async function importOk(body: Json, query = ''): Promise<Json> {
    const res = await post(ownerToken, body, query);
    expect(res.status, JSON.stringify(res.body)).toBe(202);
    const done = await waitForJob(res.body.data.jobId);
    const row = (await fixture.admin.query(`SELECT result, error FROM import_jobs WHERE id = $1`, [res.body.data.jobId]))[0];
    expect(done.status, String(row.error)).toBe('succeeded');
    return row.result;
  }

  const count = async (table: string) =>
    Number((await fixture.admin.query(`SELECT count(*)::int AS n FROM ${table} WHERE tenant_id = $1`, [TENANT_ID]))[0].n);
  const stock = async (productId: string) =>
    Number(
      (await fixture.admin.query(`SELECT stock FROM products WHERE tenant_id = $1 AND id = $2`, [TENANT_ID, productId]))[0]
        .stock,
    );

  /** The Buddhist year-month the tenant is in now (never hard-coded — CLAUDE.md, PR #525). */
  const currentPeriod = async (): Promise<string> =>
    (
      await fixture.admin.query(
        `SELECT (EXTRACT(YEAR FROM now() AT TIME ZONE t.timezone)::int + 543) || '-' ||
                to_char(now() AT TIME ZONE t.timezone, 'MM') AS period
           FROM tenants t WHERE t.id = $1::uuid`,
        [TENANT_ID],
      )
    )[0].period;

  /** A write from the till (`pos` device), with its own Idempotency-Key. */
  const till = (method: 'post', path: string, body: unknown) =>
    request(server())
      [method](`/api/v1${path}`)
      .set('Authorization', `Bearer ${posToken}`)
      .set('Idempotency-Key', newUuid())
      .send(body as object);

  beforeAll(async () => {
    fixture = await createTestApp([QueueProcessorsModule]);
  });

  afterAll(async () => {
    for (const tid of [TENANT_ID, OTHER_TENANT_ID]) {
      for (const table of TENANT_TABLES_DEPTH_FIRST) {
        await fixture.admin.query(`DELETE FROM ${table} WHERE tenant_id = $1::uuid`, [tid]);
      }
      await fixture.admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [tid]);
    }
    await fixture.app.close();
  });

  beforeEach(async () => {
    shop = await resetTenant(fixture.admin, TENANT_ID, { cache: fixture.cache });
    await resetTenant(fixture.admin, OTHER_TENANT_ID, { cache: fixture.cache });
    ownerToken = accessToken({
      tenantId: TENANT_ID,
      userId: shop.userId,
      role: 'owner',
      deviceId: shop.backofficeDeviceId,
      deviceRole: 'backoffice',
    });
    posToken = accessToken({
      tenantId: TENANT_ID,
      userId: shop.userId,
      role: 'owner',
      deviceId: shop.posDeviceId,
      deviceRole: 'pos',
    });
  });

  it('imports the app\'s own backup file: 202, the worker succeeds, the data is there, audited as the owner', async () => {
    const snap = appExport();
    const result = await importOk(snap);
    expect(result.mode).toBe('empty-only');

    expect(await count('sales')).toBe(snap.sa_sales.length);
    expect(await count('returns')).toBe(snap.sa_returns.length);
    const audit = await fixture.admin.query(
      `SELECT user_id, platform_admin_id FROM audit_log WHERE tenant_id = $1 AND action = 'backup.imported'`,
      [TENANT_ID],
    );
    expect(audit).toEqual([{ user_id: shop.userId, platform_admin_id: null }]);

    // A second import into the now non-empty shop, without replace, is refused.
    const again = await post(ownerToken, snap);
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe('TENANT_NOT_EMPTY');

    // A client-named job: polled by its own id; the same id again is refused.
    const named = newUuid();
    const first = await post(ownerToken, snap, `${replaceQuery(snap.sa_settings.shopName)}&jobId=${named}`);
    expect(first.status, JSON.stringify(first.body)).toBe(202);
    expect(first.body.data.jobId).toBe(named);
    expect((await waitForJob(named)).status).toBe('succeeded');
    const reused = await post(ownerToken, snap, `${replaceQuery(snap.sa_settings.shopName)}&jobId=${named}`);
    expect(reused.status).toBe(409);
    expect(reused.body.error.code).toBe('IMPORT_JOB_EXISTS');
    expect((await post(ownerToken, snap, '?jobId=nope')).status).toBe(400);
  }, 90000);

  it('the owner\'s sample shape imports into an empty shop, raises doc_counters, and the shop then trades', async () => {
    const snap = ownerSample();
    // One number of this server's own format in the current period: the next sale must not repeat it.
    const period = await currentPeriod();
    const imported = snap.sa_sales.find((s: Json) => !s.voided);
    imported.receiptNo = `RC01-${period}-0042`;

    const result = await importOk(snap);
    expect(result.docCounters).toBeGreaterThanOrEqual(1);
    expect(await count('sales')).toBe(snap.sa_sales.length);
    expect(await count('products')).toBe(snap.sa_products.length);
    expect(await count('parked_sales')).toBe(snap.sa_parked.length);
    // The file's open drawer is archived: no shift is active after an import.
    expect(Number((await fixture.admin.query(`SELECT count(*)::int AS n FROM shifts WHERE tenant_id = $1 AND is_active`, [TENANT_ID]))[0].n)).toBe(0);
    const counter = await fixture.admin.query(
      `SELECT last_no FROM doc_counters WHERE tenant_id = $1 AND device_id = $2 AND doc_type = 'receipt' AND period = $3`,
      [TENANT_ID, shop.posDeviceId, period],
    );
    expect(counter).toEqual([{ last_no: 42 }]);

    await tradeAfterImport(snap, period, 42);
  }, 120000);

  /**
   * The POC flow the owner needs after an import: open a shift, sell, take back part of an
   * imported bill and of the new one, take a credit payment, close the shift — with stock right.
   */
  async function tradeAfterImport(snap: Json, period: string, importedSeq = 0): Promise<void> {
    const open = await till('post', '/shifts/open', { id: newUuid(), startingCash: '1000.00' });
    expect(open.status, JSON.stringify(open.body)).toBe(200);

    const product = snap.sa_products.find((p: Json) => Number(p.stock) >= 3);
    const before = await stock(product.id);
    const saleId = newUuid();
    const sale = await till('post', '/sales', {
      id: saleId,
      subtotal: `${Number(product.price).toFixed(2)}`,
      discount: '0.00',
      total: `${Number(product.price).toFixed(2)}`,
      paymentMethod: 'เงินสด',
      customerId: null,
      customerName: null,
      mechanicId: null,
      mechanicName: null,
      mechanicDelta: null,
      overrideCreditLimit: false,
      items: [{ lineNo: 1, productId: product.id, partNo: product.partNo, name: product.name, nameTH: product.nameTH ?? null, qty: 1, price: `${Number(product.price).toFixed(2)}` }],
    });
    expect(sale.status, JSON.stringify(sale.body)).toBe(201);
    expect(sale.body.data.receiptNo).toMatch(new RegExp(`^RC01-${period}-\\d{4}$`));
    expect(Number(sale.body.data.receiptNo.slice(-4))).toBeGreaterThan(importedSeq);
    expect(await stock(product.id)).toBe(before - 1);

    // A return against the new bill…
    const ret = await till('post', '/returns', {
      id: newUuid(),
      saleId,
      refundMethod: 'เงินสด',
      reason: 'ทดสอบ',
      items: [{ productId: product.id, name: product.name, qty: 1, price: `${Number(product.price).toFixed(2)}`, originalQty: 1 }],
    });
    expect(ret.status, JSON.stringify(ret.body)).toBe(201);
    expect(await stock(product.id)).toBe(before);

    // …and against an imported bill nothing was returned from yet (server side; the app cannot
    // offer it — it never pulls history).
    const returned = new Set(snap.sa_returns.map((r: Json) => r.saleId));
    const old = snap.sa_sales.find((s: Json) => !s.voided && !returned.has(s.id) && s.items?.length);
    const line = old.items[0];
    const oldStock = await stock(line.productId);
    const oldRet = await till('post', '/returns', {
      id: newUuid(),
      saleId: old.id,
      refundMethod: 'เงินสด',
      reason: 'ทดสอบบิลนำเข้า',
      items: [{ productId: line.productId, name: line.name, qty: 1, price: `${Number(line.price).toFixed(2)}`, originalQty: line.qty }],
    });
    expect(oldRet.status, JSON.stringify(oldRet.body)).toBe(201);
    expect(await stock(line.productId)).toBe(oldStock + 1);

    const mechanic = snap.sa_mechanics.find((m: Json) => Number(m.creditBalance) >= 100);
    if (mechanic) {
      const cp = await till('post', `/mechanics/${mechanic.id}/credit-payments`, {
        id: newUuid(),
        mechanicId: mechanic.id,
        amount: '100.00',
        paymentMethod: 'เงินสด',
        note: 'ทดสอบ',
        date: new Date().toISOString(),
      });
      expect(cp.status, JSON.stringify(cp.body)).toBe(201);
    }

    const close = await till('post', '/shifts/close', { physicalCash: '1000.00' });
    expect(close.status, JSON.stringify(close.body)).toBe(200);
  }

  it('replace mode: a shop with bills is replaced only with the typed shop name, the old data is kept in a file', async () => {
    // The shop trades first: one imported history, then a new shift (a bill-bearing shop).
    await importOk(appExport());
    await seedOpenShift(fixture.admin, TENANT_ID, shop.posDeviceId, { userId: shop.userId });
    const oldSales = await count('sales');
    expect(oldSales).toBeGreaterThan(0);
    const shopName = appExport().sa_settings.shopName as string;

    const snap = ownerSample();
    const noFlag = await post(ownerToken, snap);
    expect(noFlag.status).toBe(409);
    expect(noFlag.body.error.code).toBe('TENANT_NOT_EMPTY');
    const wrong = await post(ownerToken, snap, replaceQuery('ร้านอื่น'));
    expect(wrong.status).toBe(400);
    expect(wrong.body.error.code).toBe('CONFIRM_SHOP_NAME_MISMATCH');
    const badMode = await post(ownerToken, snap, '?mode=merge');
    expect(badMode.status).toBe(400);

    // NFC + surrounding spaces are tolerated, as the owner may type them.
    const result = await importOk(snap, replaceQuery(`  ${shopName.normalize('NFD')} `));
    expect(result.mode).toBe('replace');
    expect(result.deleted.sales).toBe(oldSales);
    expect(result.deleted.shifts).toBeGreaterThan(0);

    // Only the file's data is left.
    expect(await count('sales')).toBe(snap.sa_sales.length);
    expect(await count('products')).toBe(snap.sa_products.length);
    expect(await count('customers')).toBe(snap.sa_customers.length);
    expect(Number((await fixture.admin.query(`SELECT count(*)::int AS n FROM shifts WHERE tenant_id = $1 AND is_active`, [TENANT_ID]))[0].n)).toBe(0);
    // Devices, users and the audit trail are untouched.
    expect(await count('devices')).toBe(2);
    expect(await count('users')).toBe(1);

    // The replaced data is in the pre-import file, in the export's shape (the backup ZIP).
    const file = result.preImportExport.file as string;
    expect(existsSync(file)).toBe(true);
    expect(file.endsWith('.zip')).toBe(true);
    const copy = await backupDataJson(readFileSync(file));
    expect(copy.sa_sales).toHaveLength(oldSales);
    expect(copy.__meta.version).toBe(2);

    const audit = await fixture.admin.query(
      `SELECT after FROM audit_log WHERE tenant_id = $1 AND action = 'backup.imported' ORDER BY created_at DESC LIMIT 1`,
      [TENANT_ID],
    );
    expect(audit[0].after).toMatchObject({ mode: 'replace', deleted: { sales: oldSales }, preImportExport: { file } });
    expect(audit[0].after.inserted.sales).toBe(snap.sa_sales.length);

    await tradeAfterImport(snap, await currentPeriod());
  }, 150000);

  it('refuses a session without an enrolled device and a non-owner role with 403', async () => {
    const noDevice = accessToken({ tenantId: TENANT_ID, userId: shop.userId, role: 'owner' });
    const r1 = await post(noDevice, { __meta: { version: 2 } });
    expect(r1.status).toBe(403);
    expect(r1.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');

    const notOwner = accessToken({ tenantId: TENANT_ID, userId: shop.userId, role: 'cashier', deviceId: shop.posDeviceId, deviceRole: 'pos' });
    const r2 = await post(notOwner, { __meta: { version: 2 } });
    expect(r2.status).toBe(403);
    expect(r2.body.error.code).toBe('FORBIDDEN');
  });

  it('never shows another shop\'s job (404)', async () => {
    const res = await post(ownerToken, appExport());
    expect(res.status).toBe(202);
    const otherOwner = accessToken({
      tenantId: OTHER_TENANT_ID,
      role: 'owner',
      deviceId: testId(`bo:${OTHER_TENANT_ID}`),
      deviceRole: 'backoffice',
    });
    const cross = await status(otherOwner, res.body.data.jobId);
    expect(cross.status).toBe(404);
    await waitForJob(res.body.data.jobId);
  }, 90000);

  it('refuses a shop that already has bills (409) and a bad file (400), writing no job', async () => {
    const bad = await post(ownerToken, { sa_products: [] });
    expect(bad.status).toBe(400);
    const oldApp = await post(ownerToken, { __meta: { version: 2 }, sa_products: [{ id: 'p1', stock: 1 }] });
    expect(oldApp.status).toBe(400);
    expect(oldApp.body.error.code).toBe('INVALID_ID');

    // A shop that has traded (here: an open shift) is not empty any more.
    await seedOpenShift(fixture.admin, TENANT_ID, shop.posDeviceId, { userId: shop.userId });
    const busy = await post(ownerToken, appExport());
    expect(busy.status).toBe(409);
    expect(await count('import_jobs')).toBe(0);
  });
});
