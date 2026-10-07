import { readFileSync } from 'node:fs';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
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
 * Settings → กู้คืนข้อมูล on the API build: the shop owner imports a backup into their own,
 * still-empty shop through `POST /api/v1/backup/import` (+ `GET …/:jobId`). The file is the
 * one the app's own backup button saves (`frontend/test/app_export_fixture_test.dart`).
 */
describe('owner import: POST /backup/import (e2e)', () => {
  let fixture: TestApp;
  let shop: TenantFixture;
  let ownerToken: string;
  const TENANT_ID = testId('owner-import-e2e-shop');
  const OTHER_TENANT_ID = testId('owner-import-e2e-other');

  const appExport = () =>
    JSON.parse(readFileSync(new URL('../../frontend/test/fixtures/app_export_from_synthetic.json', import.meta.url), 'utf8'));

  const post = (token: string, body: unknown) =>
    request(fixture.app.getHttpServer()).post('/api/v1/backup/import').set('Authorization', `Bearer ${token}`).send(body as object);
  const status = (token: string, jobId: string) =>
    request(fixture.app.getHttpServer()).get(`/api/v1/backup/import/${jobId}`).set('Authorization', `Bearer ${token}`);

  async function waitForJob(jobId: string): Promise<Record<string, any>> {
    const start = Date.now();
    while (Date.now() - start < 30000) {
      const res = await status(ownerToken, jobId);
      expect(res.status).toBe(200);
      if (res.body.data.status === 'succeeded' || res.body.data.status === 'failed') return res.body.data;
      await new Promise((r) => setTimeout(r, 150));
    }
    throw new Error('import job did not finish');
  }

  const count = async (table: string) =>
    Number((await fixture.admin.query(`SELECT count(*)::int AS n FROM ${table} WHERE tenant_id = $1`, [TENANT_ID]))[0].n);

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
  });

  it('imports the app\'s own backup file: 202, the worker succeeds, the data is there, audited as the owner', async () => {
    const snap = appExport();
    const res = await post(ownerToken, snap);
    expect(res.status).toBe(202);
    const { jobId } = res.body.data;

    const done = await waitForJob(jobId);
    expect(done.error).toBeUndefined();
    expect(done.status).toBe('succeeded');

    expect(await count('sales')).toBe(snap.sa_sales.length);
    expect(await count('returns')).toBe(snap.sa_returns.length);
    const audit = await fixture.admin.query(
      `SELECT user_id, platform_admin_id FROM audit_log WHERE tenant_id = $1 AND action = 'backup.imported'`,
      [TENANT_ID],
    );
    expect(audit).toEqual([{ user_id: shop.userId, platform_admin_id: null }]);

    // A second import into the now non-empty shop is refused.
    expect((await post(ownerToken, snap)).status).toBe(409);
  }, 60000);

  it('refuses a session without an enrolled device and a non-owner role with 403', async () => {
    const noDevice = accessToken({ tenantId: TENANT_ID, userId: shop.userId, role: 'owner' });
    const r1 = await post(noDevice, appExport());
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
  }, 60000);

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
