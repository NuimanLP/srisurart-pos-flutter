import { randomUUID } from 'node:crypto';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { buildTenantSnapshot } from '../src/backup/tenant-snapshot.js';
import { newUuid } from '../src/common/ids.js';
import { QueueProcessorsModule } from '../src/queue/queue.module.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedOpenShift,
  seedProduct,
  seedSettings,
  TENANT_TABLES_DEPTH_FIRST,
  type TenantFixture,
  type TestApp,
} from './support/fixture.js';
import { testId } from './support/test-ids.js';

/**
 * QR payment accounts survive the backup round trip (contract §3): the tenant export carries
 * `sa_payment_accounts` (image included, soft-deleted rows included) and each bill's
 * `paymentAccountId`; the owner import writes them back; the replace import deletes and
 * re-inserts the accounts; a bill whose account is missing from the file gets NULL.
 */
type Json = Record<string, any>;

const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4, 5]);

describe('payment accounts: export / import round trip (e2e)', () => {
  let fixture: TestApp;
  let source: TenantFixture;
  let target: TenantFixture;
  const SOURCE = testId('payment-accounts-backup-source');
  const TARGET = testId('payment-accounts-backup-target');
  const P = testId('pa-backup-product');

  const server = () => fixture.app.getHttpServer();
  const ownerOf = (f: TenantFixture) =>
    accessToken({
      tenantId: f.tenantId,
      userId: f.userId,
      role: 'owner',
      deviceId: f.backofficeDeviceId,
      deviceRole: 'backoffice',
    });
  const posOf = (f: TenantFixture) =>
    accessToken({ tenantId: f.tenantId, userId: f.userId, role: 'owner', deviceId: f.posDeviceId, deviceRole: 'pos' });
  const write = (token: string, method: 'post' | 'delete', path: string, body?: unknown) =>
    request(server())
      [method](`/api/v1${path}`)
      .set('Authorization', `Bearer ${token}`)
      .set('Idempotency-Key', randomUUID())
      .send(body as object);

  async function importOk(snapshot: Json, query = ''): Promise<Json> {
    const token = ownerOf(target);
    const res = await request(server())
      .post(`/api/v1/backup/import${query}`)
      .set('Authorization', `Bearer ${token}`)
      .send(snapshot);
    expect(res.status, JSON.stringify(res.body)).toBe(202);
    const jobId = res.body.data.jobId as string;
    const start = Date.now();
    while (Date.now() - start < 45000) {
      const s = await request(server()).get(`/api/v1/backup/import/${jobId}`).set('Authorization', `Bearer ${token}`);
      if (s.body.data.status === 'succeeded' || s.body.data.status === 'failed') {
        const row = (await fixture.admin.query(`SELECT result, error FROM import_jobs WHERE id = $1`, [jobId]))[0];
        expect(s.body.data.status, String(row.error)).toBe('succeeded');
        return row.result;
      }
      await new Promise((r) => setTimeout(r, 150));
    }
    throw new Error('import job did not finish');
  }

  const accountsOf = async (tenantId: string) =>
    (await fixture.admin.query(
      `SELECT id, nickname, bank_code, kind, promptpay_id, image, image_mime, is_default, sort_order,
              deleted_at IS NOT NULL AS deleted
         FROM payment_accounts WHERE tenant_id = $1::uuid ORDER BY sort_order, id`,
      [tenantId],
    )) as Json[];
  const saleAccounts = async (tenantId: string) =>
    (await fixture.admin.query(
      `SELECT id, payment_account_id FROM sales WHERE tenant_id = $1::uuid ORDER BY id`,
      [tenantId],
    )) as Json[];

  beforeAll(async () => {
    fixture = await createTestApp([QueueProcessorsModule]);
  });

  afterAll(async () => {
    for (const tid of [SOURCE, TARGET]) {
      for (const table of TENANT_TABLES_DEPTH_FIRST) {
        await fixture.admin.query(`DELETE FROM ${table} WHERE tenant_id = $1::uuid`, [tid]);
      }
      await fixture.admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [tid]);
    }
    await fixture.app.close();
  });

  beforeEach(async () => {
    source = await resetTenant(fixture.admin, SOURCE, { cache: fixture.cache });
    target = await resetTenant(fixture.admin, TARGET, { cache: fixture.cache });
    await seedSettings(fixture.admin, TARGET, { shopName: 'ร้านปลายทาง' });
    await seedOpenShift(fixture.admin, SOURCE, source.posDeviceId);
    await seedProduct(fixture.admin, SOURCE, { id: P, partNo: 'PA-B1', name: 'Part', price: 100, cost: 60, stock: 10 });
  });

  /** The source shop: a default PromptPay, an image account used on a bill and then deleted. */
  async function seedSourceShop(): Promise<{ promptpayId: string; imageId: string; qrSale: string; imageSale: string; cashSale: string }> {
    const owner = ownerOf(source);
    const promptpayId = newUuid();
    const imageId = newUuid();
    expect(
      (
        await write(owner, 'post', '/payment-accounts', {
          id: promptpayId,
          nickname: 'บัญชีร้าน',
          bankCode: 'KBANK',
          kind: 'promptpay',
          promptpayId: '0812345678',
          isDefault: true,
        })
      ).status,
    ).toBe(201);
    expect(
      (
        await write(owner, 'post', '/payment-accounts', {
          id: imageId,
          nickname: 'รูป QR',
          bankCode: 'SCB',
          kind: 'image',
          imageBase64: PNG.toString('base64'),
          imageMime: 'image/png',
          sortOrder: 1,
        })
      ).status,
    ).toBe(201);
    const sale = async (paymentMethod: string, paymentAccountId: string | null) => {
      const id = newUuid();
      const res = await write(posOf(source), 'post', '/sales', {
        id,
        subtotal: '100.00',
        discount: '0.00',
        total: '100.00',
        paymentMethod,
        paymentAccountId,
        items: [{ lineNo: 1, productId: P, name: 'Part', qty: 1, price: '100.00' }],
      });
      expect(res.status, JSON.stringify(res.body)).toBe(201);
      return id;
    };
    const qrSale = await sale('โอน/QR', promptpayId);
    const imageSale = await sale('โอน/QR', imageId);
    const cashSale = await sale('เงินสด', null);
    expect((await write(owner, 'delete', `/payment-accounts/${imageId}`)).status).toBe(200);
    return { promptpayId, imageId, qrSale, imageSale, cashSale };
  }

  it('the export carries every account (image, deleted ones) and each bill\'s paymentAccountId', async () => {
    const ids = await seedSourceShop();
    const { snapshot } = await buildTenantSnapshot(fixture.admin.manager, SOURCE);
    expect(snapshot.__meta.recordCounts.paymentAccounts).toBe(2);
    expect(snapshot.sa_payment_accounts).toEqual([
      expect.objectContaining({ id: ids.promptpayId, kind: 'promptpay', promptpayId: '0812345678', isDefault: true }),
      expect.objectContaining({
        id: ids.imageId,
        kind: 'image',
        imageBase64: PNG.toString('base64'),
        imageMime: 'image/png',
        isDefault: false,
        deletedAt: expect.any(String),
      }),
    ]);
    const byId = new Map((snapshot.sa_sales as Json[]).map((s) => [s.id, s]));
    expect(byId.get(ids.qrSale)!.paymentAccountId).toBe(ids.promptpayId);
    expect(byId.get(ids.imageSale)!.paymentAccountId).toBe(ids.imageId);
    expect(byId.get(ids.cashSale)!).not.toHaveProperty('paymentAccountId');
  });

  it('the owner import writes them back: same rows, same image bytes, same bill references', async () => {
    const ids = await seedSourceShop();
    const { snapshot } = await buildTenantSnapshot(fixture.admin.manager, SOURCE);
    await importOk(JSON.parse(JSON.stringify(snapshot)));

    const strip = (rows: Json[]) => rows.map(({ image, ...rest }) => ({ ...rest, image: image?.toString('base64') ?? null }));
    expect(strip(await accountsOf(TARGET))).toEqual(strip(await accountsOf(SOURCE)));
    expect(await saleAccounts(TARGET)).toEqual(await saleAccounts(SOURCE));
    // The live API reads the restored accounts: the deleted one stays hidden.
    const res = await request(server()).get('/api/v1/payment-accounts').set('Authorization', `Bearer ${ownerOf(target)}`);
    expect(res.body.data.map((a: Json) => a.id)).toEqual([ids.promptpayId]);
  });

  it('replace mode deletes and re-inserts the accounts; a bill whose account the file lacks gets NULL', async () => {
    const ids = await seedSourceShop();
    // The target already has its own account and a bill on it — both belong to the data replaced.
    await seedOpenShift(fixture.admin, TARGET, target.posDeviceId);
    await seedProduct(fixture.admin, TARGET, { id: P, partNo: 'PA-B1', name: 'Part', price: 100, cost: 60, stock: 10 });
    const own = newUuid();
    await write(ownerOf(target), 'post', '/payment-accounts', {
      id: own,
      nickname: 'บัญชีเดิม',
      bankCode: 'BBL',
      kind: 'promptpay',
      promptpayId: '0899999999',
      isDefault: true,
    });
    const targetSale = await write(posOf(target), 'post', '/sales', {
      id: newUuid(),
      subtotal: '100.00',
      discount: '0.00',
      total: '100.00',
      paymentMethod: 'โอน/QR',
      paymentAccountId: own,
      items: [{ lineNo: 1, productId: P, name: 'Part', qty: 1, price: '100.00' }],
    });
    expect(targetSale.status).toBe(201);

    const { snapshot } = await buildTenantSnapshot(fixture.admin.manager, SOURCE);
    const file = JSON.parse(JSON.stringify(snapshot)) as Json;
    // The file lost the image account: its bill must come back with no account, not fail.
    file.sa_payment_accounts = file.sa_payment_accounts.filter((a: Json) => a.id !== ids.imageId);
    const result = await importOk(file, `?mode=replace&confirmShopName=${encodeURIComponent('ร้านปลายทาง')}`);
    expect(result.deleted.payment_accounts).toBe(1);

    expect((await accountsOf(TARGET)).map((a) => a.id)).toEqual([ids.promptpayId]);
    const refs = new Map((await saleAccounts(TARGET)).map((s) => [s.id, s.payment_account_id]));
    expect(refs.get(ids.qrSale)).toBe(ids.promptpayId);
    expect(refs.get(ids.imageSale)).toBeNull();
    expect(refs.get(ids.cashSale)).toBeNull();
  });

  it('pre-flight refuses a file with two live defaults (400), before writing anything', async () => {
    await seedSourceShop();
    const { snapshot } = await buildTenantSnapshot(fixture.admin.manager, SOURCE);
    const file = JSON.parse(JSON.stringify(snapshot)) as Json;
    file.sa_payment_accounts = file.sa_payment_accounts.map((a: Json) => ({ ...a, isDefault: true, deletedAt: undefined }));
    const res = await request(server())
      .post('/api/v1/backup/import')
      .set('Authorization', `Bearer ${ownerOf(target)}`)
      .send(file);
    expect(res.status).toBe(400);
    expect(res.body.error.message).toMatch(/more than one active account is the default/);
    expect(await accountsOf(TARGET)).toEqual([]);
  });
});
