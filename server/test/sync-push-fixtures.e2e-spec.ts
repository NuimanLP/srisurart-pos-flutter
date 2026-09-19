import type { INestApplication } from '@nestjs/common';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import { SyncService } from '../src/sync/sync.service.js';
import {
  createTestApp,
  resetTenant,
  seedMechanic,
  seedOpenShift,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';

const TENANT = '28328328-8328-4283-8283-283283283283';
const POS_DEVICE_TOKEN = 'pos-device-token-01';
const FIXTURES_DIR = join(
  fileURLToPath(new URL('.', import.meta.url)),
  '../../docs/Backend_design/fixtures/sync-push',
);

interface FixtureFile {
  name: string;
  description: string;
  request: {
    headers: Record<string, string>;
    body: {
      outboxRemaining: number;
      ops: any[];
    };
  };
  response: {
    status: number;
    body: any;
  };
}

function loadFixture(filename: string): FixtureFile {
  return JSON.parse(readFileSync(join(FIXTURES_DIR, filename), 'utf8'));
}

describe('POST /sync/push Contract Tests against Fixtures (09 §4.1, slice 20-s)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;

  const push = (body: unknown, token: string | null = POS_DEVICE_TOKEN) => {
    const req = request(app.getHttpServer()).post('/api/v1/sync/push');
    if (token) req.set('X-Device-Token', token);
    return req.send(body as object);
  };

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { posDeviceNo: 1, cache });

    // Enrol POS device token (pos-device-token-01)
    const posTokenHash = createHash('sha256').update(POS_DEVICE_TOKEN).digest('hex');
    await admin.query(
      `UPDATE devices SET token_hash = $1 WHERE tenant_id = $2::uuid AND id = $3`,
      [posTokenHash, TENANT, fixture.posDeviceId],
    );
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it('all 18 fixture files exist in docs/Backend_design/fixtures/sync-push', () => {
    const files = readdirSync(FIXTURES_DIR).filter((f) => f.endsWith('.json'));
    expect(files.sort()).toEqual([
      'batch.no-active-user-403.json',
      'batch.stop-at-retry.json',
      'credit-payment.applied.json',
      'credit-payment.rejected-overpayment.json',
      'customer-create.applied.json',
      'customer-update.applied.json',
      'drawer-entry.applied.json',
      'return-create.applied.json',
      'return-create.rejected-price.json',
      'sale-create.applied.json',
      'sale-create.client-id-reused.json',
      'sale-create.rejected-stock.json',
      'sale-create.replay-by-id.json',
      'sale-create.replay-by-key.json',
      'sale-void-offline.applied.json',
      'sale-void-offline.rejected-online-bill.json',
      'shift-open.applied.json',
      'shift-open.archived-previous.json',
    ]);
  });

  describe('Shift & Cash Drawer Fixtures', () => {
    it('shift-open.applied.json & drawer-entry.applied.json & shift-open.archived-previous.json', async () => {
      // 1. shift-open.applied.json
      const fShiftOpen = loadFixture('shift-open.applied.json');
      const resShiftOpen = await push(fShiftOpen.request.body);
      expect(resShiftOpen.status).toBe(fShiftOpen.response.status);
      expect(resShiftOpen.body).toEqual(fShiftOpen.response.body);

      // 2. drawer-entry.applied.json
      const fDrawerEntry = loadFixture('drawer-entry.applied.json');
      const resDrawerEntry = await push(fDrawerEntry.request.body);
      expect(resDrawerEntry.status).toBe(fDrawerEntry.response.status);
      expect(resDrawerEntry.body).toEqual(fDrawerEntry.response.body);

      // 3. shift-open.archived-previous.json (auto-archives sh_off_001)
      const fShiftArchived = loadFixture('shift-open.archived-previous.json');
      const resShiftArchived = await push(fShiftArchived.request.body);
      expect(resShiftArchived.status).toBe(fShiftArchived.response.status);
      expect(resShiftArchived.body).toEqual(fShiftArchived.response.body);
    });
  });

  describe('Customer Fixtures', () => {
    it('customer-create.applied.json & customer-update.applied.json', async () => {
      // 1. customer-create.applied.json
      const fCustCreate = loadFixture('customer-create.applied.json');
      const resCustCreate = await push(fCustCreate.request.body);
      expect(resCustCreate.status).toBe(fCustCreate.response.status);
      expect(resCustCreate.body).toEqual(fCustCreate.response.body);

      // 2. customer-update.applied.json
      const fCustUpdate = loadFixture('customer-update.applied.json');
      const resCustUpdate = await push(fCustUpdate.request.body);
      expect(resCustUpdate.status).toBe(fCustUpdate.response.status);
      expect(resCustUpdate.body).toEqual(fCustUpdate.response.body);
    });
  });

  describe('Mechanic & Credit Payment Fixtures', () => {
    it('credit-payment.applied.json & credit-payment.rejected-overpayment.json', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedMechanic(admin, TENANT, {
        id: 'm1',
        code: 'M01',
        name: 'ช่างสมชาย',
        creditBalance: 1500,
      });

      // 1. credit-payment.applied.json (pays 500 -> balance 1000)
      const fCpApplied = loadFixture('credit-payment.applied.json');
      const resCpApplied = await push(fCpApplied.request.body);
      expect(resCpApplied.status).toBe(fCpApplied.response.status);
      expect(resCpApplied.body).toEqual(fCpApplied.response.body);

      // 2. credit-payment.rejected-overpayment.json (pays 5000 against balance 1000)
      // Note: fixture expects outstandingBalance: '1500.00'
      // Reset mechanic to 1500 to match exact fixture expectation
      await admin.query(
        `UPDATE mechanics SET credit_balance = 1500.00 WHERE tenant_id = $1::uuid AND id = 'm1'`,
        [TENANT],
      );
      const fCpRejected = loadFixture('credit-payment.rejected-overpayment.json');
      const resCpRejected = await push(fCpRejected.request.body);
      expect(resCpRejected.status).toBe(fCpRejected.response.status);
      expect(resCpRejected.body).toEqual(fCpRejected.response.body);
    });
  });

  describe('Sales, Stock & Returns Fixtures', () => {
    it('sale-create.applied.json, replay-by-key, replay-by-id, client-id-reused, rejected-stock', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedProduct(admin, TENANT, {
        id: 'p1',
        partNo: 'HN-15412-KVB',
        name: 'Oil Filter',
        price: 85,
        cost: 50,
        stock: 48,
      });

      // 1. sale-create.applied.json (sells 3 -> stock 45)
      const fSaleApplied = loadFixture('sale-create.applied.json');
      const resSaleApplied = await push(fSaleApplied.request.body);
      expect(resSaleApplied.status).toBe(fSaleApplied.response.status);
      expect(resSaleApplied.body).toEqual(fSaleApplied.response.body);

      // 2. sale-create.replay-by-key.json (B1 replay with same idempotency key)
      const fReplayKey = loadFixture('sale-create.replay-by-key.json');
      const resReplayKey = await push(fReplayKey.request.body);
      expect(resReplayKey.status).toBe(fReplayKey.response.status);
      expect(resReplayKey.body).toEqual(fReplayKey.response.body);

      // 3. sale-create.replay-by-id.json (B2 replay by client id with fresh key)
      const fReplayId = loadFixture('sale-create.replay-by-id.json');
      const resReplayId = await push(fReplayId.request.body);
      expect(resReplayId.status).toBe(fReplayId.response.status);
      expect(resReplayId.body).toEqual(fReplayId.response.body);

      // 4. sale-create.client-id-reused.json (client id matches but total differs -> CLIENT_ID_REUSED)
      const fIdReused = loadFixture('sale-create.client-id-reused.json');
      const resIdReused = await push(fIdReused.request.body);
      expect(resIdReused.status).toBe(fIdReused.response.status);
      expect(resIdReused.body).toEqual(fIdReused.response.body);

      // 5. sale-create.rejected-stock.json (stock is 10, requested is 50 -> INSUFFICIENT_STOCK)
      await admin.query(
        `UPDATE products SET stock = 10 WHERE tenant_id = $1::uuid AND id = 'p1'`,
        [TENANT],
      );
      const fStockRejected = loadFixture('sale-create.rejected-stock.json');
      const resStockRejected = await push(fStockRejected.request.body);
      expect(resStockRejected.status).toBe(fStockRejected.response.status);
      expect(resStockRejected.body).toEqual(fStockRejected.response.body);
    });

    it('return-create.applied.json & return-create.rejected-price.json', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      // Setup sale s_off_001
      await seedProduct(admin, TENANT, {
        id: 'p1',
        partNo: 'HN-15412-KVB',
        name: 'Oil Filter',
        price: 85,
        cost: 50,
        stock: 48,
      });
      const fSaleApplied = loadFixture('sale-create.applied.json');
      await push(fSaleApplied.request.body);

      // 1. return-create.applied.json (returns 1 at 85.00 -> stock 46)
      const fRetApplied = loadFixture('return-create.applied.json');
      const resRetApplied = await push(fRetApplied.request.body);
      expect(resRetApplied.status).toBe(fRetApplied.response.status);
      expect(resRetApplied.body).toEqual(fRetApplied.response.body);

      // 2. return-create.rejected-price.json (attempts return at 120.00 -> RETURN_PRICE_MISMATCH)
      const fRetPriceMismatch = loadFixture('return-create.rejected-price.json');
      const resRetPriceMismatch = await push(fRetPriceMismatch.request.body);
      expect(resRetPriceMismatch.status).toBe(fRetPriceMismatch.response.status);
      expect(resRetPriceMismatch.body).toEqual(fRetPriceMismatch.response.body);
    });
  });

  describe('Offline Void Fixtures', () => {
    it('sale-void-offline.applied.json & sale-void-offline.rejected-online-bill.json', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedProduct(admin, TENANT, {
        id: 'p1',
        partNo: 'HN-15412-KVB',
        name: 'Oil Filter',
        price: 85,
        cost: 50,
        stock: 48,
      });

      // Create offline sale s_off_001
      const fSaleApplied = loadFixture('sale-create.applied.json');
      await push(fSaleApplied.request.body);

      // 1. sale-void-offline.applied.json (voids s_off_001 -> restores stock 45 to 48)
      const fVoidApplied = loadFixture('sale-void-offline.applied.json');
      const resVoidApplied = await push(fVoidApplied.request.body);
      expect(resVoidApplied.status).toBe(fVoidApplied.response.status);
      expect(resVoidApplied.body).toEqual(fVoidApplied.response.body);

      // 2. sale-void-offline.rejected-online-bill.json
      // Seed an online bill with sold_offline = false
      await admin.query(
        `INSERT INTO sales (
          tenant_id, id, receipt_no, total, subtotal, discount, payment_method,
          sold_offline, user_id
        ) VALUES (
          $1::uuid, 's_online_123', 'RC01-2569-09-0099', 100, 100, 0, 'เงินสด',
          false, $2::uuid
        )`,
        [TENANT, fixture.userId],
      );

      const fVoidOnlineRejected = loadFixture('sale-void-offline.rejected-online-bill.json');
      const resVoidOnlineRejected = await push(fVoidOnlineRejected.request.body);
      expect(resVoidOnlineRejected.status).toBe(fVoidOnlineRejected.response.status);
      expect(resVoidOnlineRejected.body).toEqual(fVoidOnlineRejected.response.body);
    });
  });

  describe('Batch Fixtures & Invariants B3 and C13', () => {
    it('batch.stop-at-retry.json: Invariant B3 stops at first retry and leaves subsequent ops unprocessed', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedProduct(admin, TENANT, {
        id: 'p1',
        partNo: 'HN-15412-KVB',
        name: 'Oil Filter',
        price: 100,
        cost: 50,
        stock: 10,
      });

      const fStopRetry = loadFixture('batch.stop-at-retry.json');

      // Make op_2 fail with transient error (retry)
      const syncService = app.get(SyncService);
      const origProcessSingleOp = syncService.processSingleOp.bind(syncService);
      const spy = vi
        .spyOn(syncService, 'processSingleOp')
        .mockImplementation(async (actor, device, op) => {
          if (op.opId === 'op_2') {
            throw new Error('Simulated transient lock timeout');
          }
          return origProcessSingleOp(actor, device, op);
        });

      const res = await push(fStopRetry.request.body);
      spy.mockRestore();

      expect(res.status).toBe(fStopRetry.response.status);
      expect(res.body).toEqual(fStopRetry.response.body);

      // Assert that ops 3 and 4 were never executed / written to database
      const sales = (await admin.query(
        `SELECT id FROM sales WHERE tenant_id = $1::uuid AND id IN ('s_batch_2', 's_batch_3', 's_batch_4')`,
        [TENANT],
      )) as { id: string }[];
      expect(sales).toHaveLength(0);
    });

    it('batch.no-active-user-403.json: Invariant C13 returns 403 when tenant has no active user', async () => {
      // Deactivate all users for tenant
      await admin.query(
        `UPDATE users SET is_active = false WHERE tenant_id = $1::uuid`,
        [TENANT],
      );

      const fNoUser = loadFixture('batch.no-active-user-403.json');
      const res = await push(fNoUser.request.body);

      expect(res.status).toBe(fNoUser.response.status);
      expect(res.body).toEqual(fNoUser.response.body);

      // Verify no sale was created
      const sales = await admin.query(
        `SELECT id FROM sales WHERE tenant_id = $1::uuid AND id = 's_1'`,
        [TENANT],
      );
      expect(sales).toHaveLength(0);
    });
  });

  describe('Invariant B1: overrideCreditLimit replay & single audit log row', () => {
    it('sale with overrideCreditLimit commit answered lost -> push returns applied with single audit_log row', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedProduct(admin, TENANT, {
        id: 'p1',
        partNo: 'HN-15412-KVB',
        name: 'Oil Filter',
        price: 85,
        cost: 50,
        stock: 48,
      });

      await seedMechanic(admin, TENANT, {
        id: 'm1',
        code: 'M01',
        name: 'ช่างสมชาย',
        creditLimit: 100,
        creditBalance: 100, // at credit limit
      });

      const saleOp = {
        opId: 'op_b1_sale',
        idempotencyKey: 'k_b1_sale',
        type: 'sale.create',
        payload: {
          id: 's_b1_001',
          receiptNo: 'RC01-2569-09-0088',
          date: '2026-09-15T02:00:00.000Z',
          subtotal: '255.00',
          discount: '0.00',
          total: '255.00',
          paymentMethod: 'เครดิตช่าง',
          mechanicId: 'm1',
          overrideCreditLimit: true,
          items: [
            {
              lineNo: 1,
              productId: 'p1',
              partNo: 'HN-15412-KVB',
              name: 'Oil Filter',
              qty: 3,
              price: '85.00',
            },
          ],
        },
      };

      // 1. Initial push
      const res1 = await push({ outboxRemaining: 0, ops: [saleOp] });
      expect(res1.status).toBe(200);
      expect(res1.body.data.results[0].status).toBe('applied');

      // 2. Replay push (client lost response and resends)
      const res2 = await push({ outboxRemaining: 0, ops: [saleOp] });
      expect(res2.status).toBe(200);
      expect(res2.body.data.results[0].status).toBe('applied');
      expect(res2.body.data.results[0].response.id).toBe('s_b1_001');

      // 3. Verify exactly ONE row in audit_log for sale.credit_limit_override
      const auditRows = (await admin.query(
        `SELECT action, user_id, entity, entity_id FROM audit_log
         WHERE tenant_id = $1::uuid AND action = 'sale.credit_limit_override' AND entity_id = 'm1'`,
        [TENANT],
      )) as { action: string; user_id: string; entity: string; entity_id: string }[];
      expect(auditRows).toHaveLength(1);
      expect(auditRows[0].user_id).toBe(fixture.userId);
    });
  });

  describe('Invariant B2: Delete idempotency_keys & push ALL 8 op types -> never double mutates money or stock', () => {
    it('proves all 8 op types return applied and do not double-mutate state upon idempotency key loss', async () => {
      // Setup master data
      await seedProduct(admin, TENANT, {
        id: 'p_b2',
        partNo: 'B2-PART',
        name: 'B2 Part',
        price: 100,
        cost: 60,
        stock: 50,
      });

      await seedMechanic(admin, TENANT, {
        id: 'm_b2',
        code: 'M-B2',
        name: 'ช่าง B2',
        creditBalance: 2000,
      });

      // Op 1: shift.open
      const opShift = {
        opId: 'op_b2_shift',
        idempotencyKey: 'k_b2_shift',
        type: 'shift.open',
        payload: {
          id: 'sh_b2_001',
          startingCash: '1000.00',
          openedAt: '2026-09-15T01:00:00.000Z',
        },
      };
      const resShift1 = await push({ outboxRemaining: 0, ops: [opShift] });
      expect(resShift1.body.data.results[0].status).toBe('applied');

      // Delete idempotency key and replay Op 1
      await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid`, [TENANT]);
      const resShift2 = await push({
        outboxRemaining: 0,
        ops: [{ ...opShift, idempotencyKey: 'k_b2_shift_new' }],
      });
      expect(resShift2.body.data.results[0].status).toBe('applied');
      expect(resShift2.body.data.results[0].response.id).toBe('sh_b2_001');

      // Op 2: drawer.entry
      const opDrawer = {
        opId: 'op_b2_drawer',
        idempotencyKey: 'k_b2_drawer',
        type: 'drawer.entry',
        payload: {
          id: 'de_b2_001',
          type: 'in',
          amount: '200.00',
          note: 'B2 Entry',
          createdAt: '2026-09-15T01:10:00.000Z',
        },
      };
      const resDrawer1 = await push({ outboxRemaining: 0, ops: [opDrawer] });
      expect(resDrawer1.body.data.results[0].status).toBe('applied');
      expect(resDrawer1.body.data.results[0].response.balanceAfter).toBe('1200.00');

      // Delete idempotency key and replay Op 2 -> balance must remain 1200.00 (not 1400.00)
      await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid`, [TENANT]);
      const resDrawer2 = await push({
        outboxRemaining: 0,
        ops: [{ ...opDrawer, idempotencyKey: 'k_b2_drawer_new' }],
      });
      expect(resDrawer2.body.data.results[0].status).toBe('applied');
      expect(resDrawer2.body.data.results[0].response.balanceAfter).toBe('1200.00');

      // Op 3: customer.create
      const opCustCreate = {
        opId: 'op_b2_cust',
        idempotencyKey: 'k_b2_cust',
        type: 'customer.create',
        payload: {
          id: 'c_b2_001',
          name: 'Customer B2',
          phone: '0822222222',
        },
      };
      const resCust1 = await push({ outboxRemaining: 0, ops: [opCustCreate] });
      expect(resCust1.body.data.results[0].status).toBe('applied');

      // Delete idempotency key and replay Op 3
      await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid`, [TENANT]);
      const resCust2 = await push({
        outboxRemaining: 0,
        ops: [{ ...opCustCreate, idempotencyKey: 'k_b2_cust_new' }],
      });
      expect(resCust2.body.data.results[0].status).toBe('applied');
      expect(resCust2.body.data.results[0].response.id).toBe('c_b2_001');

      // Op 4: customer.update
      const opCustUpdate = {
        opId: 'op_b2_cust_up',
        idempotencyKey: 'k_b2_cust_up',
        type: 'customer.update',
        payload: {
          id: 'c_b2_001',
          phone: '0833333333',
        },
      };
      const resCustUp1 = await push({ outboxRemaining: 0, ops: [opCustUpdate] });
      expect(resCustUp1.body.data.results[0].status).toBe('applied');

      // Delete idempotency key and replay Op 4
      await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid`, [TENANT]);
      const resCustUp2 = await push({
        outboxRemaining: 0,
        ops: [{ ...opCustUpdate, idempotencyKey: 'k_b2_cust_up_new' }],
      });
      expect(resCustUp2.body.data.results[0].status).toBe('applied');
      expect(resCustUp2.body.data.results[0].response.phone).toBe('0833333333');

      // Op 5: credit_payment.create
      const opCp = {
        opId: 'op_b2_cp',
        idempotencyKey: 'k_b2_cp',
        type: 'credit_payment.create',
        payload: {
          id: 'cp_b2_001',
          mechanicId: 'm_b2',
          amount: '500.00',
          paymentMethod: 'เงินสด',
          date: '2026-09-15T01:20:00.000Z',
        },
      };
      const resCp1 = await push({ outboxRemaining: 0, ops: [opCp] });
      expect(resCp1.body.data.results[0].status).toBe('applied');
      expect(resCp1.body.data.results[0].response.balanceAfter).toBe('1500.00');

      // Delete idempotency key and replay Op 5 -> balance must remain 1500.00 (not 1000.00)
      await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid`, [TENANT]);
      const resCp2 = await push({
        outboxRemaining: 0,
        ops: [{ ...opCp, idempotencyKey: 'k_b2_cp_new' }],
      });
      expect(resCp2.body.data.results[0].status).toBe('applied');
      expect(resCp2.body.data.results[0].response.balanceAfter).toBe('1500.00');

      // Op 6: sale.create
      const opSale = {
        opId: 'op_b2_sale',
        idempotencyKey: 'k_b2_sale',
        type: 'sale.create',
        payload: {
          id: 's_b2_001',
          receiptNo: 'RC01-2569-09-0077',
          date: '2026-09-15T02:00:00.000Z',
          subtotal: '200.00',
          discount: '0.00',
          total: '200.00',
          paymentMethod: 'เงินสด',
          customerId: 'c_b2_001',
          items: [
            {
              lineNo: 1,
              productId: 'p_b2',
              partNo: 'B2-PART',
              name: 'B2 Part',
              qty: 2,
              price: '100.00',
            },
          ],
        },
      };
      const resSale1 = await push({ outboxRemaining: 0, ops: [opSale] });
      expect(resSale1.body.data.results[0].status).toBe('applied');
      expect(resSale1.body.data.results[0].response.products[0].stock).toBe(48);

      // Check customer spend and product stock
      const stockAfterSale1 = (await admin.query(
        `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = 'p_b2'`,
        [TENANT],
      ))[0].stock;
      expect(stockAfterSale1).toBe(48);

      // Delete idempotency key and replay Op 6 -> stock must remain 48 (not 46)
      await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid`, [TENANT]);
      const resSale2 = await push({
        outboxRemaining: 0,
        ops: [{ ...opSale, idempotencyKey: 'k_b2_sale_new' }],
      });
      expect(resSale2.body.data.results[0].status).toBe('applied');
      const stockAfterSale2 = (await admin.query(
        `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = 'p_b2'`,
        [TENANT],
      ))[0].stock;
      expect(stockAfterSale2).toBe(48);

      // Op 7: return.create
      const opReturn = {
        opId: 'op_b2_ret',
        idempotencyKey: 'k_b2_ret',
        type: 'return.create',
        payload: {
          id: 'ret_b2_001',
          saleId: 's_b2_001',
          cnNo: 'CN01-2569-09-0011',
          date: '2026-09-15T03:00:00.000Z',
          refundMethod: 'เงินสด',
          reason: 'B2 return',
          subtotal: '100.00',
          total: '100.00',
          items: [{ productId: 'p_b2', qty: 1, price: '100.00' }],
        },
      };
      const resRet1 = await push({ outboxRemaining: 0, ops: [opReturn] });
      expect(resRet1.body.data.results[0].status).toBe('applied');
      const stockAfterRet1 = (await admin.query(
        `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = 'p_b2'`,
        [TENANT],
      ))[0].stock;
      expect(stockAfterRet1).toBe(49);

      // Delete idempotency key and replay Op 7 -> stock must remain 49 (not 50)
      await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid`, [TENANT]);
      const resRet2 = await push({
        outboxRemaining: 0,
        ops: [{ ...opReturn, idempotencyKey: 'k_b2_ret_new' }],
      });
      expect(resRet2.body.data.results[0].status).toBe('applied');
      const stockAfterRet2 = (await admin.query(
        `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = 'p_b2'`,
        [TENANT],
      ))[0].stock;
      expect(stockAfterRet2).toBe(49);

      // Op 8: sale.void_offline
      // Create another sale s_b2_002 to void
      const opSaleToVoid = {
        opId: 'op_b2_sale2',
        idempotencyKey: 'k_b2_sale2',
        type: 'sale.create',
        payload: {
          id: 's_b2_002',
          receiptNo: 'RC01-2569-09-0078',
          date: '2026-09-15T02:30:00.000Z',
          subtotal: '100.00',
          discount: '0.00',
          total: '100.00',
          paymentMethod: 'เงินสด',
          items: [
            {
              lineNo: 1,
              productId: 'p_b2',
              partNo: 'B2-PART',
              name: 'B2 Part',
              qty: 1,
              price: '100.00',
            },
          ],
        },
      };
      await push({ outboxRemaining: 0, ops: [opSaleToVoid] });
      // Stock is now 48

      const opVoid = {
        opId: 'op_b2_void',
        idempotencyKey: 'k_b2_void',
        type: 'sale.void_offline',
        payload: {
          saleId: 's_b2_002',
          reason: 'B2 cancel',
        },
      };
      const resVoid1 = await push({ outboxRemaining: 0, ops: [opVoid] });
      expect(resVoid1.body.data.results[0].status).toBe('applied');
      const stockAfterVoid1 = (await admin.query(
        `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = 'p_b2'`,
        [TENANT],
      ))[0].stock;
      expect(stockAfterVoid1).toBe(49);

      // Delete idempotency key and replay Op 8 -> stock must remain 49 (not 50)
      await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid`, [TENANT]);
      const resVoid2 = await push({
        outboxRemaining: 0,
        ops: [{ ...opVoid, idempotencyKey: 'k_b2_void_new' }],
      });
      expect(resVoid2.body.data.results[0].status).toBe('applied');
      const stockAfterVoid2 = (await admin.query(
        `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = 'p_b2'`,
        [TENANT],
      ))[0].stock;
      expect(stockAfterVoid2).toBe(49);
    });
  });
});
