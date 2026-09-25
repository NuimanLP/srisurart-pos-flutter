import type { INestApplication } from '@nestjs/common';
import { createHash } from 'node:crypto';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import {
  accessToken,
  clearTenantCache,
  createTestApp,
  resetTenant,
  seedMechanic,
  seedOpenShift,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';

const TENANT = '28328328-8328-4283-8283-283283283283';
const POS_DEVICE_TOKEN = 'pos-device-token-01';
const BO_DEVICE_TOKEN = 'bo-device-token-01';

describe('POST /sync/push (e2e)', () => {
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

    // Enrol POS device token
    const posTokenHash = createHash('sha256').update(POS_DEVICE_TOKEN).digest('hex');
    await admin.query(
      `UPDATE devices SET token_hash = $1 WHERE tenant_id = $2::uuid AND id = $3`,
      [posTokenHash, TENANT, fixture.posDeviceId],
    );

    // Enrol Backoffice device token
    const boTokenHash = createHash('sha256').update(BO_DEVICE_TOKEN).digest('hex');
    await admin.query(
      `UPDATE devices SET token_hash = $1 WHERE tenant_id = $2::uuid AND id = $3`,
      [boTokenHash, TENANT, fixture.backofficeDeviceId],
    );
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  describe('Authentication and DeviceTokenGuard', () => {
    it('rejects request without X-Device-Token header (401)', async () => {
      const res = await push({ outboxRemaining: 0, ops: [] }, null);
      expect(res.status).toBe(401);
      expect(res.body.error.message).toContain('X-Device-Token');
    });

    it('rejects request with unknown device token (401)', async () => {
      const res = await push({ outboxRemaining: 0, ops: [] }, 'unknown-token');
      expect(res.status).toBe(401);
      expect(res.body.error.message).toContain('Invalid device token');
    });

    it('rejects request when device is retired (401)', async () => {
      await admin.query(
        `UPDATE devices SET retired_at = now() WHERE tenant_id = $1::uuid AND id = $2`,
        [TENANT, fixture.posDeviceId],
      );
      const res = await push({ outboxRemaining: 0, ops: [] });
      expect(res.status).toBe(401);
      expect(res.body.error.message).toContain('Device has been retired');
    });

    it('rejects request when device role is not pos (403)', async () => {
      const res = await push(
        {
          outboxRemaining: 0,
          ops: [
            {
              opId: 'op_1',
              idempotencyKey: 'k_1',
              type: 'customer.create',
              payload: { id: 'c1', name: 'Test' },
            },
          ],
        },
        BO_DEVICE_TOKEN,
      );
      expect(res.status).toBe(403);
      expect(res.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');
    });

    it('rejects request when tenant is suspended (403)', async () => {
      await admin.query(`UPDATE tenants SET status = 'suspended' WHERE id = $1::uuid`, [
        TENANT,
      ]);
      const res = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_1',
            idempotencyKey: 'k_1',
            type: 'customer.create',
            payload: { id: 'c1', name: 'Test' },
          },
        ],
      });
      expect(res.status).toBe(403);
      expect(res.body.error.code).toBe('TENANT_SUSPENDED');
    });

    it('C13: rejects whole request with 403 when tenant has no active user (batch.no-active-user-403.json)', async () => {
      await admin.query(`UPDATE users SET is_active = FALSE WHERE tenant_id = $1::uuid`, [
        TENANT,
      ]);

      const res = await push({
        outboxRemaining: 1,
        ops: [
          {
            opId: 'op_1',
            idempotencyKey: 'k_1',
            type: 'sale.create',
            payload: {
              id: 's_1',
              receiptNo: 'RC01-2569-09-0054',
              date: '2026-09-15T05:10:00.000Z',
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เงินสด',
              items: [],
            },
          },
        ],
      });

      expect(res.status).toBe(403);
      expect(res.body).toEqual({
        status: 'error',
        error: {
          code: 'FORBIDDEN',
          message: 'No active user found for tenant',
        },
      });
    });
  });

  describe('Push Queue Operations (Fixtures)', () => {
    it('shift-open.applied: open shift op applied when no prior shift is active', async () => {
      const res = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_shift_001',
            idempotencyKey: 'k_sh_001',
            type: 'shift.open',
            payload: {
              id: 'sh_off_001',
              startingCash: '1000.00',
              openedAt: '2026-09-15T01:00:00.000Z',
            },
          },
        ],
      });

      expect(res.status).toBe(200);
      expect(res.body).toEqual({
        status: 'success',
        data: {
          results: [
            {
              opId: 'op_shift_001',
              status: 'applied',
              response: {
                id: 'sh_off_001',
                startingCash: '1000.00',
                openedAt: '2026-09-15T01:00:00.000Z',
                autoArchived: false,
              },
            },
          ],
        },
      });

      // Verify in DB
      const shifts = await admin.query(
        `SELECT id, starting_cash, is_active FROM shifts WHERE tenant_id = $1::uuid AND id = 'sh_off_001'`,
        [TENANT],
      );
      expect(shifts).toHaveLength(1);
      expect(shifts[0].is_active).toBe(true);
    });

    it('shift-open.archived-previous: open shift auto-archives previously unclosed shift', async () => {
      // Prior shift sh_off_001 active
      await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
        id: 'sh_off_001',
        startingCash: 1000,
      });

      const res = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_shift_002',
            idempotencyKey: 'k_sh_002',
            type: 'shift.open',
            payload: {
              id: 'sh_off_002',
              startingCash: '1000.00',
              openedAt: '2026-09-16T01:00:00.000Z',
            },
          },
        ],
      });

      expect(res.status).toBe(200);
      expect(res.body).toEqual({
        status: 'success',
        data: {
          results: [
            {
              opId: 'op_shift_002',
              status: 'applied',
              response: {
                id: 'sh_off_002',
                startingCash: '1000.00',
                openedAt: '2026-09-16T01:00:00.000Z',
                autoArchived: true,
                archivedShiftId: 'sh_off_001',
              },
            },
          ],
        },
      });

      const prior = await admin.query(
        `SELECT is_active, auto_archived FROM shifts WHERE tenant_id = $1::uuid AND id = 'sh_off_001'`,
        [TENANT],
      );
      expect(prior[0].is_active).toBe(false);
      expect(prior[0].auto_archived).toBe(true);
    });

    // 08 §11's example and the tenant-timezone `date_str` rule. Moved here from
    // `shifts.e2e-spec.ts` (#411): the online `POST /shifts/open` no longer reads
    // `openedAt`, so a device-recorded open time only ever arrives through a push.
    it('shift.open keeps the device openedAt: A date_str = 15, B = 16, and 23:30Z lands on the Bangkok day', async () => {
      const open = (id: string, openedAt: string) => ({
        opId: `op_${id}`,
        idempotencyKey: `k_${id}`,
        type: 'shift.open',
        payload: { id, startingCash: '1000.00', openedAt },
      });
      const res = await push({
        outboxRemaining: 0,
        ops: [
          open('sh_A', '2026-09-15T08:00:00.000Z'),
          open('sh_B', '2026-09-16T08:00:00.000Z'),
          // 2026-09-16 23:30 UTC = 2026-09-17 06:30 in Asia/Bangkok (+07:00)
          open('sh_late_utc', '2026-09-16T23:30:00.000Z'),
        ],
      });
      expect(res.status).toBe(200);
      expect(
        (res.body.data.results as { status: string }[]).map((r) => r.status),
      ).toEqual(['applied', 'applied', 'applied']);

      const rows = (await admin.query(
        `SELECT id, date_str, opened_at FROM shifts WHERE tenant_id = $1::uuid ORDER BY id`,
        [TENANT],
      )) as { id: string; date_str: string; opened_at: Date }[];
      expect(rows.map((r) => [r.id, r.date_str, r.opened_at.toISOString()])).toEqual([
        ['sh_A', '2026-09-15', '2026-09-15T08:00:00.000Z'],
        ['sh_B', '2026-09-16', '2026-09-16T08:00:00.000Z'],
        ['sh_late_utc', '2026-09-17', '2026-09-16T23:30:00.000Z'],
      ]);
    });

    it('shift.open refuses an unparseable openedAt instead of failing the batch', async () => {
      const res = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_bad_open',
            idempotencyKey: 'k_bad_open',
            type: 'shift.open',
            payload: { id: 'sh_bad', startingCash: '100.00', openedAt: 'not-a-date' },
          },
        ],
      });
      expect(res.status).toBe(200);
      expect(res.body.data.results[0]).toMatchObject({
        opId: 'op_bad_open',
        status: 'rejected',
        code: 'BAD_REQUEST',
      });
      const rows = await admin.query(
        `SELECT id FROM shifts WHERE tenant_id = $1::uuid AND id = 'sh_bad'`,
        [TENANT],
      );
      expect(rows).toHaveLength(0);
    });

    it('sale.create and return.create keep the device date and mark the bill sold_offline', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedProduct(admin, TENANT, {
        id: 'p411',
        partNo: 'P-411',
        name: 'Filter',
        price: 85,
        cost: 50,
        stock: 10,
      });
      // Two minutes ago: inside `[opened_at − 5 min, now + 5 min]`, so kept verbatim (§10).
      const deviceDate = new Date(Date.now() - 2 * 60 * 1000).toISOString();
      const res = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_s411',
            idempotencyKey: 'k_s411',
            type: 'sale.create',
            payload: {
              id: 's_411',
              date: deviceDate,
              subtotal: '85.00',
              discount: '0.00',
              total: '85.00',
              paymentMethod: 'เงินสด',
              items: [{ lineNo: 1, productId: 'p411', name: 'Filter', qty: 1, price: '85.00' }],
            },
          },
          {
            opId: 'op_r411',
            idempotencyKey: 'k_r411',
            type: 'return.create',
            payload: {
              id: 'cn_411',
              saleId: 's_411',
              date: deviceDate,
              refundMethod: 'เงินสด',
              items: [{ productId: 'p411', name: 'Filter', qty: 1, price: '85.00' }],
            },
          },
        ],
      });
      expect(res.status).toBe(200);
      expect(
        (res.body.data.results as { status: string }[]).map((r) => r.status),
      ).toEqual(['applied', 'applied']);

      const sale = (await admin.query(
        `SELECT date, sold_offline FROM sales WHERE tenant_id = $1::uuid AND id = 's_411'`,
        [TENANT],
      )) as { date: Date; sold_offline: boolean }[];
      expect(sale[0].date.toISOString()).toBe(deviceDate);
      expect(sale[0].sold_offline).toBe(true);
      const ret = (await admin.query(
        `SELECT date FROM returns WHERE tenant_id = $1::uuid AND sale_id = 's_411'`,
        [TENANT],
      )) as { date: Date }[];
      expect(ret[0].date.toISOString()).toBe(deviceDate);
    });

    it('drawer-entry.applied: cash drawer entry pushed to server successfully', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
        id: 'sh_off_001',
        startingCash: 1000,
      });

      const res = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_drawer_001',
            idempotencyKey: 'k_de_001',
            type: 'drawer.entry',
            payload: {
              id: 'de_off_001',
              type: 'in',
              amount: '500.00',
              note: 'สำรองเงินทอน',
              createdAt: '2026-09-15T01:30:00.000Z',
            },
          },
        ],
      });

      expect(res.status).toBe(200);
      expect(res.body).toEqual({
        status: 'success',
        data: {
          results: [
            {
              opId: 'op_drawer_001',
              status: 'applied',
              response: {
                id: 'de_off_001',
                type: 'in',
                amount: '500.00',
                note: 'สำรองเงินทอน',
                balanceAfter: '1500.00',
              },
            },
          ],
        },
      });
    });

    it('sale-create.applied, replay-by-key, replay-by-id, client-id-reused', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
        id: 'sh_off_001',
        startingCash: 1000,
      });
      await seedProduct(admin, TENANT, {
        id: 'p1',
        partNo: 'HN-15412-KVB',
        name: 'Oil Filter',
        price: 85,
        cost: 50,
        stock: 48,
      });

      const salePayload = {
        id: 's_off_001',
        receiptNo: 'RC01-2569-09-0042',
        date: '2026-09-15T02:00:00.000Z',
        subtotal: '255.00',
        discount: '0.00',
        total: '255.00',
        paymentMethod: 'เงินสด',
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
      };

      // 1. sale-create.applied
      const res1 = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_sale_001',
            idempotencyKey: 'k_sale_001',
            type: 'sale.create',
            payload: salePayload,
          },
        ],
      });

      expect(res1.status).toBe(200);
      expect(res1.body).toEqual({
        status: 'success',
        data: {
          results: [
            {
              opId: 'op_sale_001',
              status: 'applied',
              response: {
                id: 's_off_001',
                receiptNo: 'RC01-2569-09-0042',
                total: '255.00',
                pointsGranted: 25,
                products: [{ id: 'p1', stock: 45 }],
              },
            },
          ],
        },
      });

      // Verify sold_offline column in DB
      const saleRow = await admin.query(
        `SELECT sold_offline, shift_id FROM sales WHERE tenant_id = $1::uuid AND id = 's_off_001'`,
        [TENANT],
      );
      expect(saleRow[0].sold_offline).toBe(true);

      // 2. sale-create.replay-by-key
      const res2 = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_sale_001_retry',
            idempotencyKey: 'k_sale_001',
            type: 'sale.create',
            payload: salePayload,
          },
        ],
      });
      expect(res2.status).toBe(200);
      expect(res2.body.data.results[0]).toEqual({
        opId: 'op_sale_001_retry',
        status: 'applied',
        response: {
          id: 's_off_001',
          receiptNo: 'RC01-2569-09-0042',
          total: '255.00',
          pointsGranted: 25,
          products: [{ id: 'p1', stock: 45 }],
        },
      });

      // 3. sale-create.replay-by-id (idempotency key expired/deleted)
      await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid`, [TENANT]);
      const res3 = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_sale_001_reid',
            idempotencyKey: 'k_sale_fresh_key',
            type: 'sale.create',
            payload: salePayload,
          },
        ],
      });
      expect(res3.status).toBe(200);
      expect(res3.body.data.results[0]).toEqual({
        opId: 'op_sale_001_reid',
        status: 'applied',
        response: {
          id: 's_off_001',
          receiptNo: 'RC01-2569-09-0042',
          total: '255.00',
          pointsGranted: 25,
          products: [{ id: 'p1', stock: 45 }],
        },
      });

      // 4. sale-create.client-id-reused (mismatched total)
      const res4 = await push({
        outboxRemaining: 1,
        ops: [
          {
            opId: 'op_sale_mismatch',
            idempotencyKey: 'k_sale_diff',
            type: 'sale.create',
            payload: {
              ...salePayload,
              subtotal: '999.00',
              total: '999.00',
              items: [
                {
                  lineNo: 1,
                  productId: 'p1',
                  name: 'Oil Filter',
                  qty: 1,
                  price: '999.00',
                },
              ],
            },
          },
        ],
      });
      expect(res4.status).toBe(200);
      expect(res4.body).toEqual({
        status: 'success',
        data: {
          results: [
            {
              opId: 'op_sale_mismatch',
              status: 'rejected',
              code: 'CLIENT_ID_REUSED',
              message: 'รหัสรายการซ้ำกับรายการอื่น กรุณาตรวจสอบ',
              details: {
                type: 'sale.create',
                id: 's_off_001',
              },
            },
          ],
        },
      });
    });

    it('sale-create.rejected-stock: rejected when stock insufficient at sync time', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedProduct(admin, TENANT, {
        id: 'p1',
        partNo: 'HN-15412-KVB',
        name: 'Oil Filter',
        price: 85,
        cost: 50,
        stock: 10,
      });

      const res = await push({
        outboxRemaining: 1,
        ops: [
          {
            opId: 'op_sale_002',
            idempotencyKey: 'k_sale_002',
            type: 'sale.create',
            payload: {
              id: 's_off_002',
              receiptNo: 'RC01-2569-09-0043',
              date: '2026-09-15T02:10:00.000Z',
              subtotal: '4250.00',
              discount: '0.00',
              total: '4250.00',
              paymentMethod: 'เงินสด',
              items: [
                {
                  lineNo: 1,
                  productId: 'p1',
                  partNo: 'HN-15412-KVB',
                  name: 'Oil Filter',
                  qty: 50,
                  price: '85.00',
                },
              ],
            },
          },
        ],
      });

      expect(res.status).toBe(200);
      expect(res.body).toEqual({
        status: 'success',
        data: {
          results: [
            {
              opId: 'op_sale_002',
              status: 'rejected',
              code: 'INSUFFICIENT_STOCK',
              message: 'สต็อกไม่พอ',
              details: {
                productId: 'p1',
                requested: 50,
                available: 10,
              },
            },
          ],
        },
      });
    });

    it('return-create.applied and return-create.rejected-price', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedProduct(admin, TENANT, {
        id: 'p1',
        partNo: 'HN-15412-KVB',
        name: 'Oil Filter',
        price: 85,
        cost: 50,
        stock: 45,
      });

      // First create sale s_off_001
      await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_sale_001',
            idempotencyKey: 'k_sale_001',
            type: 'sale.create',
            payload: {
              id: 's_off_001',
              receiptNo: 'RC01-2569-09-0042',
              date: '2026-09-15T02:00:00.000Z',
              subtotal: '255.00',
              discount: '0.00',
              total: '255.00',
              paymentMethod: 'เงินสด',
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
          },
        ],
      });

      // 1. return-create.rejected-price (price is 120.00 instead of 85.00)
      const resPriceMismatch = await push({
        outboxRemaining: 1,
        ops: [
          {
            opId: 'op_ret_002',
            idempotencyKey: 'k_ret_002',
            type: 'return.create',
            payload: {
              id: 'ret_off_002',
              saleId: 's_off_001',
              cnNo: 'CN01-2569-09-0006',
              date: '2026-09-15T03:15:00.000Z',
              refundMethod: 'เงินสด',
              reason: 'สินค้าชำรุด',
              subtotal: '120.00',
              total: '120.00',
              items: [{ productId: 'p1', qty: 1, price: '120.00' }],
            },
          },
        ],
      });

      expect(resPriceMismatch.status).toBe(200);
      expect(resPriceMismatch.body).toEqual({
        status: 'success',
        data: {
          results: [
            {
              opId: 'op_ret_002',
              status: 'rejected',
              code: 'RETURN_PRICE_MISMATCH',
              message: 'ราคาคืนไม่ตรงกับราคาที่ขายจริง',
              details: {
                productId: 'p1',
                expectedPrice: '85.00',
                actualPrice: '120.00',
              },
            },
          ],
        },
      });

      // 2. return-create.applied
      const resApplied = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_ret_001',
            idempotencyKey: 'k_ret_001',
            type: 'return.create',
            payload: {
              id: 'ret_off_001',
              saleId: 's_off_001',
              cnNo: 'CN01-2569-09-0005',
              date: '2026-09-15T03:00:00.000Z',
              refundMethod: 'เงินสด',
              reason: 'สินค้าชำรุด',
              subtotal: '85.00',
              total: '85.00',
              items: [{ productId: 'p1', qty: 1, price: '85.00' }],
            },
          },
        ],
      });

      expect(resApplied.status).toBe(200);
      expect(resApplied.body).toEqual({
        status: 'success',
        data: {
          results: [
            {
              opId: 'op_ret_001',
              status: 'applied',
              response: {
                id: 'ret_off_001',
                cnNo: 'CN01-2569-09-0005',
                saleId: 's_off_001',
                total: '85.00',
                refundMethod: 'เงินสด',
                stockRestored: [{ id: 'p1', stock: 43 }],
              },
            },
          ],
        },
      });
    });

    it('credit-payment.applied and rejected-overpayment', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedMechanic(admin, TENANT, {
        id: 'm1',
        code: 'M01',
        name: 'ช่างหนึ่ง',
        creditLimit: 10000,
        creditBalance: 1500,
      });

      // 1. Overpayment rejected
      const resOver = await push({
        outboxRemaining: 1,
        ops: [
          {
            opId: 'op_cp_002',
            idempotencyKey: 'k_cp_002',
            type: 'credit_payment.create',
            payload: {
              id: 'cp_off_002',
              mechanicId: 'm1',
              amount: '5000.00',
              paymentMethod: 'เงินสด',
              date: '2026-09-15T04:30:00.000Z',
            },
          },
        ],
      });

      expect(resOver.status).toBe(200);
      expect(resOver.body).toEqual({
        status: 'success',
        data: {
          results: [
            {
              opId: 'op_cp_002',
              status: 'rejected',
              code: 'OVERPAYMENT',
              message: 'ยอดชำระเกินยอดหนี้คงค้าง',
              details: {
                mechanicId: 'm1',
                outstandingBalance: '1500.00',
                attemptedAmount: '5000.00',
              },
            },
          ],
        },
      });

      // 2. Applied
      const resApplied = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_cp_001',
            idempotencyKey: 'k_cp_001',
            type: 'credit_payment.create',
            payload: {
              id: 'cp_off_001',
              mechanicId: 'm1',
              amount: '500.00',
              paymentMethod: 'เงินสด',
              date: '2026-09-15T04:00:00.000Z',
            },
          },
        ],
      });

      expect(resApplied.status).toBe(200);
      expect(resApplied.body).toEqual({
        status: 'success',
        data: {
          results: [
            {
              opId: 'op_cp_001',
              status: 'applied',
              response: {
                id: 'cp_off_001',
                mechanicId: 'm1',
                amount: '500.00',
                paymentMethod: 'เงินสด',
                balanceAfter: '1000.00',
              },
            },
          ],
        },
      });
    });

    it('customer-create.applied and customer-update.applied', async () => {
      // 1. Create
      const resCreate = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_cust_001',
            idempotencyKey: 'k_cust_001',
            type: 'customer.create',
            payload: {
              id: 'c_off_001',
              name: 'สมชาย สายลม',
              phone: '0812345678',
              address: '123 ถ.สุขุมวิท',
            },
          },
        ],
      });

      expect(resCreate.status).toBe(200);
      expect(resCreate.body).toEqual({
        status: 'success',
        data: {
          results: [
            {
              opId: 'op_cust_001',
              status: 'applied',
              response: {
                id: 'c_off_001',
                name: 'สมชาย สายลม',
                phone: '0812345678',
                address: '123 ถ.สุขุมวิท',
                totalSpend: '0.00',
                points: 0,
              },
            },
          ],
        },
      });

      // 2. Update
      const resUpdate = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_cust_002',
            idempotencyKey: 'k_cust_002',
            type: 'customer.update',
            payload: {
              id: 'c_off_001',
              phone: '0899999999',
            },
          },
        ],
      });

      expect(resUpdate.status).toBe(200);
      expect(resUpdate.body).toEqual({
        status: 'success',
        data: {
          results: [
            {
              opId: 'op_cust_002',
              status: 'applied',
              response: {
                id: 'c_off_001',
                phone: '0899999999',
              },
            },
          ],
        },
      });
    });

    it('sale-void-offline.applied and rejected-online-bill', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedProduct(admin, TENANT, {
        id: 'p1',
        partNo: 'HN-15412-KVB',
        name: 'Oil Filter',
        price: 85,
        cost: 50,
        stock: 50,
      });

      // 1. Create offline sale s_off_001
      await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_sale_001',
            idempotencyKey: 'k_sale_001',
            type: 'sale.create',
            payload: {
              id: 's_off_001',
              receiptNo: 'RC01-2569-09-0042',
              date: '2026-09-15T02:00:00.000Z',
              subtotal: '170.00',
              discount: '0.00',
              total: '170.00',
              paymentMethod: 'เงินสด',
              items: [{ lineNo: 1, productId: 'p1', name: 'Oil Filter', qty: 2, price: '85.00' }],
            },
          },
        ],
      });

      // 2. Seed an online sale s_online_123 (sold_offline = false)
      await admin.query(
        `INSERT INTO sales (tenant_id, id, receipt_no, subtotal, total, payment_method, points_granted, sold_offline, user_id)
         VALUES ($1::uuid, 's_online_123', 'RC01-2569-09-0099', 100.00, 100.00, 'เงินสด', 10, FALSE, $2::uuid)`,
        [TENANT, fixture.userId],
      );

      // 3. Attempting to void online bill via sale.void_offline is rejected (sale-void-offline.rejected-online-bill.json)
      const resOnlineVoid = await push({
        outboxRemaining: 1,
        ops: [
          {
            opId: 'op_void_002',
            idempotencyKey: 'k_void_002',
            type: 'sale.void_offline',
            payload: {
              saleId: 's_online_123',
              reason: 'ขอยกเลิก',
            },
          },
        ],
      });

      expect(resOnlineVoid.status).toBe(200);
      expect(resOnlineVoid.body).toEqual({
        status: 'success',
        data: {
          results: [
            {
              opId: 'op_void_002',
              status: 'rejected',
              code: 'VOID_NEEDS_ONLINE',
              message: 'บิลออนไลน์สามารถยกเลิกได้เมื่อเชื่อมต่ออินเทอร์เน็ตเท่านั้น',
              details: {
                saleId: 's_online_123',
              },
            },
          ],
        },
      });

      // 3.5. Attempting to void offline bill with missing/empty reason is rejected
      const resEmptyReason = await push({
        outboxRemaining: 1,
        ops: [
          {
            opId: 'op_void_err',
            idempotencyKey: 'k_void_err',
            type: 'sale.void_offline',
            payload: {
              saleId: 's_off_001',
              reason: '   ',
            },
          },
        ],
      });
      expect(resEmptyReason.status).toBe(200);
      expect(resEmptyReason.body.data.results[0]).toMatchObject({
        opId: 'op_void_err',
        status: 'rejected',
        code: 'BAD_REQUEST',
        message: 'Void reason is required',
      });

      // 4. Voiding offline bill succeeds (sale-void-offline.applied.json)
      const resOfflineVoid = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_void_001',
            idempotencyKey: 'k_void_001',
            type: 'sale.void_offline',
            payload: {
              saleId: 's_off_001',
              reason: 'ลูกค้าขอยกเลิกและเปลี่ยนสินค้า',
            },
          },
        ],
      });

      expect(resOfflineVoid.status).toBe(200);
      expect(resOfflineVoid.body).toEqual({
        status: 'success',
        data: {
          results: [
            {
              opId: 'op_void_001',
              status: 'applied',
              response: {
                saleId: 's_off_001',
                status: 'voided',
                voidReason: 'ลูกค้าขอยกเลิกและเปลี่ยนสินค้า',
                stockRestored: [{ productId: 'p1', stock: 50 }],
              },
            },
          ],
        },
      });

      // Verify sales row in DB has void_reason and sold_offline
      const voidedSale = await admin.query(
        `SELECT voided, void_reason, sold_offline FROM sales WHERE tenant_id = $1::uuid AND id = 's_off_001'`,
        [TENANT],
      );
      expect(voidedSale[0].voided).toBe(true);
      expect(voidedSale[0].void_reason).toBe('ลูกค้าขอยกเลิกและเปลี่ยนสินค้า');
      expect(voidedSale[0].sold_offline).toBe(true);

      // Verify owner_review_items for void_offline
      const reviews = await admin.query(
        `SELECT kind, ref_id, details FROM owner_review_items WHERE tenant_id = $1::uuid AND kind = 'void_offline'`,
        [TENANT],
      );
      expect(reviews).toHaveLength(1);
      expect(reviews[0].ref_id).toBe('s_off_001');
    });

    it('push sale.create and sale.void_offline of that bill in the same batch -> voided + 1 review item', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedProduct(admin, TENANT, {
        id: 'p1',
        partNo: 'HN-15412-KVB',
        name: 'Oil Filter',
        price: 100,
        cost: 50,
        stock: 50,
      });

      const res = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_sale_batch',
            idempotencyKey: 'k_sale_batch',
            type: 'sale.create',
            payload: {
              id: 's_batch_001',
              receiptNo: 'RC01-2569-09-0010',
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เงินสด',
              items: [{ lineNo: 1, productId: 'p1', name: 'Oil Filter', qty: 1, price: '100.00' }],
            },
          },
          {
            opId: 'op_void_batch',
            idempotencyKey: 'k_void_batch',
            type: 'sale.void_offline',
            payload: {
              saleId: 's_batch_001',
              reason: 'ผิดบิลในกะเดียวกัน',
            },
          },
        ],
      });

      expect(res.status).toBe(200);
      expect(res.body.data.results).toHaveLength(2);
      expect(res.body.data.results[0].status).toBe('applied');
      expect(res.body.data.results[1]).toEqual({
        opId: 'op_void_batch',
        status: 'applied',
        response: {
          saleId: 's_batch_001',
          status: 'voided',
          voidReason: 'ผิดบิลในกะเดียวกัน',
          stockRestored: [{ productId: 'p1', stock: 50 }],
        },
      });

      // Verify DB row
      const rows = await admin.query(
        `SELECT voided, void_reason, sold_offline FROM sales WHERE tenant_id = $1::uuid AND id = 's_batch_001'`,
        [TENANT],
      );
      expect(rows[0].voided).toBe(true);
      expect(rows[0].void_reason).toBe('ผิดบิลในกะเดียวกัน');
      expect(rows[0].sold_offline).toBe(true);

      // Verify review item
      const reviews = await admin.query(
        `SELECT kind, ref_id, details FROM owner_review_items WHERE tenant_id = $1::uuid AND ref_id = 's_batch_001'`,
        [TENANT],
      );
      expect(reviews).toHaveLength(1);
      expect(reviews[0].kind).toBe('void_offline');
      expect(reviews[0].details.reason).toBe('ผิดบิลในกะเดียวกัน');
    });

    it('batch.stop-at-retry: when op N fails with retry, subsequent ops return retry without processing', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedProduct(admin, TENANT, {
        id: 'p1',
        partNo: 'HN-15412-KVB',
        name: 'Oil Filter',
        price: 100,
        cost: 50,
        stock: 10,
      });

      const makeSaleOp = (num: number) => ({
        opId: `op_${num}`,
        idempotencyKey: `k_${num}`,
        type: 'sale.create',
        payload: {
          id: `s_batch_${num}`,
          receiptNo: `RC01-2569-09-005${num - 1}`,
          date: `2026-09-15T05:0${num - 1}:00.000Z`,
          subtotal: '100.00',
          discount: '0.00',
          total: '100.00',
          paymentMethod: 'เงินสด',
          items: [{ lineNo: 1, productId: 'p1', name: 'Oil Filter', qty: 1, price: '100.00' }],
        },
      });

      // To make op_2 fail with a 500 (retry):
      // Seed an unparseable state or use a spy on processSingleOp
      const syncService = app.get(
        (await import('../src/sync/sync.service.js')).SyncService,
      );
      const originalProcessSingleOp = syncService.processSingleOp.bind(syncService);
      const spy = vi
        .spyOn(syncService, 'processSingleOp')
        .mockImplementation(async (actor, device, op) => {
          if (op.opId === 'op_2') {
            throw new Error('Simulated transient DB connection timeout');
          }
          return originalProcessSingleOp(actor, device, op);
        });

      const res = await push({
        outboxRemaining: 3,
        ops: [makeSaleOp(1), makeSaleOp(2), makeSaleOp(3), makeSaleOp(4)],
      });

      spy.mockRestore();

      expect(res.status).toBe(200);
      expect(res.body).toEqual({
        status: 'success',
        data: {
          results: [
            {
              opId: 'op_1',
              status: 'applied',
              response: {
                id: 's_batch_1',
                receiptNo: 'RC01-2569-09-0050',
                total: '100.00',
                pointsGranted: 10,
                products: [{ id: 'p1', stock: 9 }],
              },
            },
            {
              opId: 'op_2',
              status: 'retry',
            },
            {
              opId: 'op_3',
              status: 'retry',
            },
            {
              opId: 'op_4',
              status: 'retry',
            },
          ],
        },
      });

      // Ensure s_batch_3 and s_batch_4 were never processed / created in DB
      const sales = await admin.query(
        `SELECT id FROM sales WHERE tenant_id = $1::uuid AND id IN ('s_batch_2', 's_batch_3', 's_batch_4')`,
        [TENANT],
      );
      expect(sales).toHaveLength(0);
    });

    it('devices.unsynced_ops is updated from outboxRemaining (08 §8.2 C12)', async () => {
      await push({
        outboxRemaining: 15,
        ops: [
          {
            opId: 'op_c1',
            idempotencyKey: 'k_c1',
            type: 'customer.create',
            payload: { id: 'c_outbox', name: 'ลูกค้าทดสอบ' },
          },
        ],
      });

      const dev = await admin.query(
        `SELECT unsynced_ops, unsynced_reported_at FROM devices WHERE tenant_id = $1::uuid AND id = $2`,
        [TENANT, fixture.posDeviceId],
      );
      expect(dev[0].unsynced_ops).toBe(15);
      expect(dev[0].unsynced_reported_at).not.toBeNull();
    });

    it('records review items for date_flag and credit_override', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
        id: 'sh_review',
        startingCash: 500,
      });
      await seedProduct(admin, TENANT, {
        id: 'p1',
        partNo: 'HN-15412-KVB',
        name: 'Oil Filter',
        price: 100,
        cost: 50,
        stock: 50,
      });
      await seedMechanic(admin, TENANT, {
        id: 'm1',
        code: 'M01',
        name: 'ช่างทดสอบ',
        creditLimit: 50,
        creditBalance: 0,
      });

      // 1. Out-of-bounds date: 3 hours in the future
      const futureDate = new Date(Date.now() + 3 * 3600 * 1000).toISOString();
      await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_date_flag',
            idempotencyKey: 'k_df_1',
            type: 'sale.create',
            payload: {
              id: 's_date_flag',
              receiptNo: 'RC01-2569-09-0088',
              date: futureDate,
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เงินสด',
              items: [{ lineNo: 1, productId: 'p1', name: 'Oil Filter', qty: 1, price: '100.00' }],
            },
          },
        ],
      });

      const dateFlagReviews = await admin.query(
        `SELECT kind, ref_id FROM owner_review_items WHERE tenant_id = $1::uuid AND kind = 'date_flag'`,
        [TENANT],
      );
      expect(dateFlagReviews.length).toBeGreaterThanOrEqual(1);

      // 2. Credit override sale
      await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_credit_override',
            idempotencyKey: 'k_co_1',
            type: 'sale.create',
            payload: {
              id: 's_credit_override',
              receiptNo: 'RC01-2569-09-0089',
              subtotal: '200.00',
              discount: '0.00',
              total: '200.00',
              paymentMethod: 'เครดิตช่าง',
              mechanicId: 'm1',
              overrideCreditLimit: true,
              items: [{ lineNo: 1, productId: 'p1', name: 'Oil Filter', qty: 2, price: '100.00' }],
            },
          },
        ],
      });

      const creditReviews = await admin.query(
        `SELECT kind, ref_id FROM owner_review_items WHERE tenant_id = $1::uuid AND kind = 'credit_override'`,
        [TENANT],
      );
      expect(creditReviews).toHaveLength(1);
      expect(creditReviews[0].ref_id).toBe('s_credit_override');
    });

    it('Slice 14-s (#285): credit limit override via push creates credit_override review item and single audit_log row, B1 replay preserved', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
        id: 'sh_co_14',
        startingCash: 500,
      });
      await seedProduct(admin, TENANT, {
        id: 'p_co_14',
        partNo: 'HN-CO-14',
        name: 'Brake Pad CO14',
        price: 100,
        cost: 50,
        stock: 50,
      });
      await seedMechanic(admin, TENANT, {
        id: 'm14',
        code: 'M14',
        name: 'ช่างสมชาย 14',
        creditLimit: 50,
        creditBalance: 0,
      });

      // 1. Attempt pushing credit sale that exceeds credit limit without override flag -> rejected CREDIT_LIMIT_EXCEEDED
      const resWithoutFlag = await push({
        outboxRemaining: 1,
        ops: [
          {
            opId: 'op_co_refused',
            idempotencyKey: 'k_co_refused',
            type: 'sale.create',
            payload: {
              id: 's_co_refused',
              receiptNo: 'RC01-2569-09-0091',
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เครดิตช่าง',
              mechanicId: 'm14',
              items: [{ lineNo: 1, productId: 'p_co_14', name: 'Brake Pad CO14', qty: 1, price: '100.00' }],
            },
          },
        ],
      });

      expect(resWithoutFlag.status).toBe(200);
      expect(resWithoutFlag.body.data.results[0]).toMatchObject({
        opId: 'op_co_refused',
        status: 'rejected',
        code: 'CREDIT_LIMIT_EXCEEDED',
        details: {
          creditLimit: '50.00',
          creditBalance: '0.00',
          newBalance: '100.00',
        },
      });

      // Assert no audit log and no review item were written for the refused attempt
      const auditRefused = await admin.query(
        `SELECT count(*)::int AS n FROM audit_log WHERE tenant_id = $1::uuid AND entity_id = 'm14'`,
        [TENANT],
      );
      expect(auditRefused[0].n).toBe(0);
      const reviewsRefused = await admin.query(
        `SELECT count(*)::int AS n FROM owner_review_items WHERE tenant_id = $1::uuid AND ref_id = 's_co_refused'`,
        [TENANT],
      );
      expect(reviewsRefused[0].n).toBe(0);

      // 2. Pushing with overrideCreditLimit: true succeeds and creates 1 review item + 1 audit_log row
      const resWithFlag = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_co_success',
            idempotencyKey: 'k_co_success',
            type: 'sale.create',
            payload: {
              id: 's_co_14',
              receiptNo: 'RC01-2569-09-0092',
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เครดิตช่าง',
              mechanicId: 'm14',
              overrideCreditLimit: true,
              items: [{ lineNo: 1, productId: 'p_co_14', name: 'Brake Pad CO14', qty: 1, price: '100.00' }],
            },
          },
        ],
      });

      expect(resWithFlag.status).toBe(200);
      expect(resWithFlag.body.data.results[0].status).toBe('applied');

      // Verify owner_review_items: exactly 1 row
      const reviews = await admin.query(
        `SELECT kind, ref_id, details FROM owner_review_items WHERE tenant_id = $1::uuid AND ref_id = 's_co_14'`,
        [TENANT],
      );
      expect(reviews).toHaveLength(1);
      expect(reviews[0]).toMatchObject({
        kind: 'credit_override',
        ref_id: 's_co_14',
        details: {
          saleId: 's_co_14',
          mechanicId: 'm14',
          total: '100.00',
          creditLimit: '50.00',
          creditBalanceAfter: '100.00',
        },
      });

      // Verify audit_log: exactly 1 row, tied to shop user and push device
      const audits = await admin.query(
        `SELECT action, entity, entity_id, user_id, device_id, after FROM audit_log
          WHERE tenant_id = $1::uuid AND action = 'sale.credit_limit_override' AND entity_id = 'm14'`,
        [TENANT],
      );
      expect(audits).toHaveLength(1);
      expect(audits[0]).toMatchObject({
        action: 'sale.credit_limit_override',
        entity: 'mechanic',
        entity_id: 'm14',
        user_id: fixture.userId,
        device_id: fixture.posDeviceId,
        after: {
          saleId: 's_co_14',
          total: '100.00',
          creditLimit: '50.00',
          creditBalanceBefore: '0.00',
          creditBalanceAfter: '100.00',
        },
      });

      // 3. B1 Replay Invariant: retrying push with same key returns applied without duplicating audit_log or review item
      const resReplay = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_co_success',
            idempotencyKey: 'k_co_success',
            type: 'sale.create',
            payload: {
              id: 's_co_14',
              receiptNo: 'RC01-2569-09-0092',
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เครดิตช่าง',
              mechanicId: 'm14',
              overrideCreditLimit: true,
              items: [{ lineNo: 1, productId: 'p_co_14', name: 'Brake Pad CO14', qty: 1, price: '100.00' }],
            },
          },
        ],
      });

      expect(resReplay.status).toBe(200);
      expect(resReplay.body.data.results[0].status).toBe('applied');

      // Verify no duplication in owner_review_items (still exactly 1)
      const reviewsAfterReplay = await admin.query(
        `SELECT count(*)::int AS n FROM owner_review_items WHERE tenant_id = $1::uuid AND ref_id = 's_co_14'`,
        [TENANT],
      );
      expect(reviewsAfterReplay[0].n).toBe(1);

      // Verify no duplication in audit_log (still exactly 1)
      const auditsAfterReplay = await admin.query(
        `SELECT count(*)::int AS n FROM audit_log
          WHERE tenant_id = $1::uuid AND action = 'sale.credit_limit_override' AND entity_id = 'm14'`,
        [TENANT],
      );
      expect(auditsAfterReplay[0].n).toBe(1);

      // Verify mechanic balance not doubled
      const mechanicRow = await admin.query(
        `SELECT credit_balance FROM mechanics WHERE tenant_id = $1::uuid AND id = 'm14'`,
        [TENANT],
      );
      expect(mechanicRow[0].credit_balance).toBe('100.00');
    });

    describe('#409 / 08 §8.4 AC B1: a bill committed ONLINE whose reply was lost, then pushed', () => {
      // `ApiSalesRepository.saveSale` falls back to the outbox with the SAME bill id and
      // `Idempotency-Key` when `POST /api/v1/sales` gets no answer. The server may already
      // have committed that bill; the push must then replay it, never refuse it.
      const onlineBody = {
        id: 's_b1_online',
        subtotal: '100.00',
        discount: '0.00',
        total: '100.00',
        paymentMethod: 'เครดิตช่าง',
        customerId: null,
        customerName: null,
        mechanicId: 'm_b1',
        mechanicName: 'ช่าง B1',
        mechanicDelta: null,
        overrideCreditLimit: true,
        items: [
          { lineNo: 1, productId: 'p_b1', partNo: 'HN-B1', name: 'Brake Pad B1', nameTH: null, qty: 2, price: '50.00' },
        ],
      };
      // What `_saveOffline` puts in the outbox: the online body plus the offline
      // receipt number and the local date.
      const { id: onlineId, ...onlineRest } = onlineBody;
      const outboxPayload = {
        id: onlineId,
        receiptNo: 'RC01-2569-09-0777',
        date: '2026-09-25T02:00:00.000Z',
        ...onlineRest,
      };

      const postOnline = (key: string, body: object) =>
        request(app.getHttpServer())
          .post('/api/v1/sales')
          .set(
            'Authorization',
            `Bearer ${accessToken({
              tenantId: TENANT,
              userId: fixture.userId,
              deviceId: fixture.posDeviceId,
              deviceRole: 'pos',
            })}`,
          )
          .set('Idempotency-Key', key)
          .send(body);

      const stockOf = async (id: string) =>
        (
          (await admin.query(
            `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = $2`,
            [TENANT, id],
          )) as { stock: number }[]
        )[0].stock;

      beforeEach(async () => {
        await seedOpenShift(admin, TENANT, fixture.posDeviceId, { id: 'sh_b1', startingCash: 500 });
        await seedProduct(admin, TENANT, {
          id: 'p_b1',
          partNo: 'HN-B1',
          name: 'Brake Pad B1',
          price: 50,
          cost: 30,
          stock: 20,
        });
        await seedMechanic(admin, TENANT, {
          id: 'm_b1',
          code: 'MB1',
          name: 'ช่าง B1',
          creditLimit: 50,
          creditBalance: 0,
        });
      });

      it('push of the outbox op (receiptNo + date added) → applied with the server bill, stock and audit moved once', async () => {
        const online = await postOnline('k_b1', onlineBody);
        expect(online.status).toBe(201);
        const serverReceiptNo = online.body.data.receiptNo as string;
        expect(await stockOf('p_b1')).toBe(18);

        const res = await push({
          outboxRemaining: 0,
          ops: [{ opId: 'op_b1', idempotencyKey: 'k_b1', type: 'sale.create', payload: outboxPayload }],
        });

        expect(res.status).toBe(200);
        expect(res.body.data.results[0]).toMatchObject({
          opId: 'op_b1',
          status: 'applied',
          response: { id: 's_b1_online', receiptNo: serverReceiptNo, total: '100.00' },
        });
        // Replayed, not re-run: one bill, stock down once, the override audited once.
        expect(await stockOf('p_b1')).toBe(18);
        const sales = await admin.query(
          `SELECT receipt_no FROM sales WHERE tenant_id = $1::uuid AND id = 's_b1_online'`,
          [TENANT],
        );
        expect(sales).toEqual([{ receipt_no: serverReceiptNo }]);
        const audits = await admin.query(
          `SELECT user_id FROM audit_log
            WHERE tenant_id = $1::uuid AND action = 'sale.credit_limit_override' AND entity_id = 'm_b1'`,
          [TENANT],
        );
        expect(audits).toEqual([{ user_id: fixture.userId }]);
        const mech = await admin.query(
          `SELECT credit_balance FROM mechanics WHERE tenant_id = $1::uuid AND id = 'm_b1'`,
          [TENANT],
        );
        expect(mech[0].credit_balance).toBe('100.00');
      });

      it('an op whose body equals the online body replays the stored online response by key (step 1)', async () => {
        const online = await postOnline('k_b1_same', onlineBody);
        expect(online.status).toBe(201);

        const res = await push({
          outboxRemaining: 0,
          ops: [{ opId: 'op_b1_same', idempotencyKey: 'k_b1_same', type: 'sale.create', payload: onlineBody }],
        });

        // The full online response — only a key replay returns it; the client-id replay
        // answers with the push-shaped subset.
        expect(res.body.data.results[0]).toEqual({
          opId: 'op_b1_same',
          status: 'applied',
          response: online.body.data,
        });
        expect(await stockOf('p_b1')).toBe(18);
      });

      it('a key an older push recorded as `POST /sales` (before #409) still replays, and a key recorded on another route does not', async () => {
        const op = { opId: 'op_b1_legacy', idempotencyKey: 'k_b1_legacy', type: 'sale.create', payload: outboxPayload };
        expect((await push({ outboxRemaining: 0, ops: [op] })).body.data.results[0].status).toBe('applied');
        await admin.query(
          `UPDATE idempotency_keys SET endpoint = 'POST /sales' WHERE tenant_id = $1::uuid AND key = 'k_b1_legacy'`,
          [TENANT],
        );
        await clearTenantCache(cache, TENANT);
        const replay = await push({ outboxRemaining: 0, ops: [op] });
        expect(replay.body.data.results[0]).toMatchObject({ status: 'applied', response: { id: 's_b1_online' } });

        await admin.query(
          `UPDATE idempotency_keys SET endpoint = 'POST /api/v1/returns' WHERE tenant_id = $1::uuid AND key = 'k_b1_legacy'`,
          [TENANT],
        );
        await clearTenantCache(cache, TENANT);
        const wrongRoute = await push({ outboxRemaining: 0, ops: [op] });
        expect(wrongRoute.body.data.results[0]).toMatchObject({ status: 'rejected', code: 'IDEMPOTENCY_KEY_REUSED' });
        expect(await stockOf('p_b1')).toBe(18);
      });

      it('the same key on a DIFFERENT bill is still refused IDEMPOTENCY_KEY_REUSED', async () => {
        expect((await postOnline('k_b1_reuse', onlineBody)).status).toBe(201);
        // A second, genuinely different bill already on the server under its own key.
        const other = { ...onlineBody, id: 's_b1_other', overrideCreditLimit: false, paymentMethod: 'เงินสด', mechanicId: null, mechanicName: null };
        expect((await postOnline('k_b1_other', other)).status).toBe(201);
        expect(await stockOf('p_b1')).toBe(16);

        const res = await push({
          outboxRemaining: 0,
          ops: [
            // A bill the server has never seen, carrying k_b1_reuse.
            {
              opId: 'op_new_bill',
              idempotencyKey: 'k_b1_reuse',
              type: 'sale.create',
              payload: { ...outboxPayload, id: 's_b1_new', receiptNo: 'RC01-2569-09-0778' },
            },
          ],
        });
        expect(res.body.data.results[0]).toMatchObject({
          opId: 'op_new_bill',
          status: 'rejected',
          code: 'IDEMPOTENCY_KEY_REUSED',
        });

        const res2 = await push({
          outboxRemaining: 0,
          ops: [
            // An existing bill (s_b1_other), but under the key that belongs to s_b1_online.
            {
              opId: 'op_other_bill',
              idempotencyKey: 'k_b1_reuse',
              type: 'sale.create',
              payload: { ...other, receiptNo: 'RC01-2569-09-0779', date: outboxPayload.date },
            },
          ],
        });
        expect(res2.body.data.results[0]).toMatchObject({
          opId: 'op_other_bill',
          status: 'rejected',
          code: 'IDEMPOTENCY_KEY_REUSED',
        });

        const n = await admin.query(
          `SELECT count(*)::int AS n FROM sales WHERE tenant_id = $1::uuid`,
          [TENANT],
        );
        expect(n[0].n).toBe(2);
        expect(await stockOf('p_b1')).toBe(16);
      });

      it('owner 2026-09-25: a replay whose offline receiptNo differs from the stored one → ONE receipt_renumbered item, even when replayed again', async () => {
        const online = await postOnline('k_b1_renum', onlineBody);
        expect(online.status).toBe(201);
        const serverReceiptNo = online.body.data.receiptNo as string;
        expect(serverReceiptNo).not.toBe(outboxPayload.receiptNo);

        const op = { opId: 'op_b1_renum', idempotencyKey: 'k_b1_renum', type: 'sale.create', payload: outboxPayload };
        for (let i = 0; i < 2; i++) {
          const res = await push({ outboxRemaining: 0, ops: [op] });
          expect(res.body.data.results[0]).toMatchObject({
            status: 'applied',
            response: { id: 's_b1_online', receiptNo: serverReceiptNo },
          });
        }
        // Step 2 as well: key row gone → client-id replay, still no second item.
        await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid AND key = 'k_b1_renum'`, [TENANT]);
        await clearTenantCache(cache, TENANT);
        expect((await push({ outboxRemaining: 0, ops: [op] })).body.data.results[0].status).toBe('applied');

        const items = await admin.query(
          `SELECT ref_id, details FROM owner_review_items WHERE tenant_id = $1::uuid AND kind = 'receipt_renumbered'`,
          [TENANT],
        );
        expect(items).toEqual([
          {
            ref_id: 's_b1_online',
            details: {
              opId: 'op_b1_renum',
              type: 'sale.create',
              id: 's_b1_online',
              offlineNo: 'RC01-2569-09-0777',
              serverNo: serverReceiptNo,
            },
          },
        ]);
        expect(await stockOf('p_b1')).toBe(18);
      });

      it('a replay carrying the SAME number as the stored bill raises no receipt_renumbered item', async () => {
        const online = await postOnline('k_b1_samenum', onlineBody);
        const payload = { ...outboxPayload, receiptNo: online.body.data.receiptNo };
        const res = await push({
          outboxRemaining: 0,
          ops: [{ opId: 'op_b1_samenum', idempotencyKey: 'k_b1_samenum', type: 'sale.create', payload }],
        });
        expect(res.body.data.results[0].status).toBe('applied');
        const items = await admin.query(
          `SELECT 1 FROM owner_review_items WHERE tenant_id = $1::uuid AND kind = 'receipt_renumbered'`,
          [TENANT],
        );
        expect(items).toHaveLength(0);
      });
    });

    describe('08 §10 edge cases (owner 2026-09-25)', () => {
      const saleOp = (id: string, date: unknown) => ({
        opId: `op_${id}`,
        idempotencyKey: `k_${id}`,
        type: 'sale.create',
        payload: {
          id,
          date,
          subtotal: '85.00',
          discount: '0.00',
          total: '85.00',
          paymentMethod: 'เงินสด',
          items: [{ lineNo: 1, productId: 'p_d10', name: 'Filter', qty: 1, price: '85.00' }],
        },
      });
      const flags = async () =>
        (await admin.query(
          `SELECT ref_id, details FROM owner_review_items WHERE tenant_id = $1::uuid AND kind = 'date_flag' ORDER BY ref_id`,
          [TENANT],
        )) as { ref_id: string; details: Record<string, unknown> }[];

      beforeEach(async () => {
        await seedProduct(admin, TENANT, { id: 'p_d10', partNo: 'P-D10', name: 'Filter', price: 85, cost: 50, stock: 10 });
      });

      it('an unparseable date is rejected, not silently replaced with now()', async () => {
        await seedOpenShift(admin, TENANT, fixture.posDeviceId);
        const res = await push({ outboxRemaining: 0, ops: [saleOp('s_bad_date', 'not-a-date')] });
        expect(res.body.data.results[0]).toMatchObject({ status: 'rejected', code: 'BAD_REQUEST' });
        expect(await admin.query(`SELECT 1 FROM sales WHERE tenant_id = $1::uuid AND id = 's_bad_date'`, [TENANT])).toHaveLength(0);
      });

      it('no active shift: a date 10 min ahead → now() + date_flag; a past date is kept unflagged', async () => {
        // A sale needs an open drawer; a non-cash refund does not (#100), so the
        // no-shift path is reached by a transfer refund after the shift is archived.
        await seedOpenShift(admin, TENANT, fixture.posDeviceId, { id: 'sh_d10' });
        const sale = saleOp('s_d10', new Date().toISOString());
        sale.payload.items[0].qty = 2;
        Object.assign(sale.payload, { subtotal: '170.00', total: '170.00' });
        expect((await push({ outboxRemaining: 0, ops: [sale] })).body.data.results[0].status).toBe('applied');
        await admin.query(
          `UPDATE shifts SET is_active = false, closed_at = now() WHERE tenant_id = $1::uuid AND id = 'sh_d10'`,
          [TENANT],
        );

        const refund = (id: string, date: string) => ({
          opId: `op_${id}`,
          idempotencyKey: `k_${id}`,
          type: 'return.create',
          payload: {
            id,
            saleId: 's_d10',
            date,
            refundMethod: 'โอน',
            items: [{ productId: 'p_d10', name: 'Filter', qty: 1, price: '85.00' }],
          },
        });
        const future = new Date(Date.now() + 10 * 60 * 1000).toISOString();
        const past = new Date(Date.now() - 3 * 24 * 3600 * 1000).toISOString();
        const before = Date.now();
        const res = await push({ outboxRemaining: 0, ops: [refund('cn_nf', future), refund('cn_np', past)] });
        expect((res.body.data.results as { status: string }[]).map((r) => r.status)).toEqual(['applied', 'applied']);

        const rows = (await admin.query(
          `SELECT id, date FROM returns WHERE tenant_id = $1::uuid ORDER BY id`,
          [TENANT],
        )) as { id: string; date: Date }[];
        const byId = Object.fromEntries(rows.map((r) => [r.id, r.date.getTime()]));
        expect(byId.cn_np).toBe(new Date(past).getTime());
        expect(byId.cn_nf).toBeGreaterThanOrEqual(before - 1000);
        expect(byId.cn_nf).toBeLessThan(new Date(future).getTime() - 60 * 1000);

        const f = await flags();
        expect(f).toHaveLength(1);
        expect(f[0].ref_id).toBe('cn_nf');
        expect(f[0].details).toMatchObject({ opId: 'op_cn_nf', type: 'return.create', originalDate: future, openedAt: null });
      });

      it('shift.open 10 min ahead → opened_at = now() + date_flag; replay adds no second flag', async () => {
        const future = new Date(Date.now() + 10 * 60 * 1000).toISOString();
        const op = {
          opId: 'op_sh_future',
          idempotencyKey: 'k_sh_future',
          type: 'shift.open',
          payload: { id: 'sh_future', startingCash: '100.00', openedAt: future },
        };
        expect((await push({ outboxRemaining: 0, ops: [op] })).body.data.results[0].status).toBe('applied');
        expect((await push({ outboxRemaining: 0, ops: [op] })).body.data.results[0].status).toBe('applied');

        const sh = (await admin.query(
          `SELECT opened_at FROM shifts WHERE tenant_id = $1::uuid AND id = 'sh_future'`,
          [TENANT],
        )) as { opened_at: Date }[];
        expect(sh[0].opened_at.getTime()).toBeLessThan(new Date(future).getTime() - 60 * 1000);
        const f = await flags();
        expect(f).toHaveLength(1);
        expect(f[0]).toMatchObject({
          ref_id: 'sh_future',
          details: { type: 'shift.open', originalDate: future, openedAt: null },
        });
      });
    });

    it('Issue #190: rejects sale or return with RECEIPT_NO_CONFLICT when document number collides', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
        id: 'sh_190',
        startingCash: 500,
      });
      await seedProduct(admin, TENANT, {
        id: 'p190',
        partNo: 'HN-190',
        name: 'Spark Plug 190',
        price: 100,
        cost: 50,
        stock: 50,
      });

      const receiptNo = 'RC01-2569-09-0070';
      const salePayload1 = {
        id: 's_190_1',
        receiptNo,
        date: new Date().toISOString(),
        subtotal: '100.00',
        discount: '0.00',
        total: '100.00',
        paymentMethod: 'เงินสด',
        items: [{ lineNo: 1, productId: 'p190', name: 'Spark Plug 190', qty: 1, price: '100.00' }],
      };

      // 1. First sale applies successfully
      const res1 = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_190_1',
            idempotencyKey: 'k_190_1',
            type: 'sale.create',
            payload: salePayload1,
          },
        ],
      });
      expect(res1.status).toBe(200);
      expect(res1.body.data.results[0].status).toBe('applied');

      // 2. Replay with exact same sale returns applied (replay takes precedence over conflict check)
      const resReplay = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_190_1_replay',
            idempotencyKey: 'k_190_1_new_key',
            type: 'sale.create',
            payload: salePayload1,
          },
        ],
      });
      expect(resReplay.status).toBe(200);
      expect(resReplay.body.data.results[0].status).toBe('applied');

      // 3. Different sale attempting to use the same receiptNo -> rejected RECEIPT_NO_CONFLICT
      const salePayloadColliding = {
        id: 's_190_colliding',
        receiptNo,
        date: new Date().toISOString(),
        subtotal: '200.00',
        discount: '0.00',
        total: '200.00',
        paymentMethod: 'เงินสด',
        items: [{ lineNo: 1, productId: 'p190', name: 'Spark Plug 190', qty: 2, price: '100.00' }],
      };

      const resConflict = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_190_colliding',
            idempotencyKey: 'k_190_colliding',
            type: 'sale.create',
            payload: salePayloadColliding,
          },
        ],
      });

      expect(resConflict.status).toBe(200);
      expect(resConflict.body.data.results[0]).toEqual({
        opId: 'op_190_colliding',
        status: 'rejected',
        code: 'RECEIPT_NO_CONFLICT',
        message: 'เลขที่ใบเสร็จซ้ำ กรุณาทำรายการใหม่',
        details: {
          docNumber: receiptNo,
        },
      });

      // Invariant: stock was only deducted by sale 1 (50 - 1 = 49), not by the rejected sale
      const productRow = await admin.query(
        `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = 'p190'`,
        [TENANT],
      );
      expect(productRow[0].stock).toBe(49);

      // Invariant: no row exists for s_190_colliding
      const saleRows = await admin.query(
        `SELECT id FROM sales WHERE tenant_id = $1::uuid AND id = 's_190_colliding'`,
        [TENANT],
      );
      expect(saleRows).toHaveLength(0);

      // 4. Batch continuation: a batch containing valid, colliding, valid ops
      const resBatch = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_batch_valid_1',
            idempotencyKey: 'k_b_1',
            type: 'sale.create',
            payload: {
              id: 's_batch_1',
              receiptNo: 'RC01-2569-09-0071',
              date: new Date().toISOString(),
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เงินสด',
              items: [{ lineNo: 1, productId: 'p190', name: 'Spark Plug 190', qty: 1, price: '100.00' }],
            },
          },
          {
            opId: 'op_batch_conflict',
            idempotencyKey: 'k_b_2',
            type: 'sale.create',
            payload: {
              id: 's_batch_2',
              receiptNo, // colliding with s_190_1
              date: new Date().toISOString(),
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เงินสด',
              items: [{ lineNo: 1, productId: 'p190', name: 'Spark Plug 190', qty: 1, price: '100.00' }],
            },
          },
          {
            opId: 'op_batch_valid_2',
            idempotencyKey: 'k_b_3',
            type: 'sale.create',
            payload: {
              id: 's_batch_3',
              receiptNo: 'RC01-2569-09-0072',
              date: new Date().toISOString(),
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เงินสด',
              items: [{ lineNo: 1, productId: 'p190', name: 'Spark Plug 190', qty: 1, price: '100.00' }],
            },
          },
        ],
      });

      expect(resBatch.status).toBe(200);
      expect(resBatch.body.data.results[0].status).toBe('applied');
      expect(resBatch.body.data.results[1].status).toBe('rejected');
      expect(resBatch.body.data.results[1].code).toBe('RECEIPT_NO_CONFLICT');
      expect(resBatch.body.data.results[2].status).toBe('applied');

      // 5. Credit note cnNo collision in return.create
      const cnNo = 'CN01-2569-09-0020';
      const returnPayload1 = {
        id: 'r_190_1',
        cnNo,
        saleId: 's_190_1',
        refundMethod: 'เงินสด',
        reason: 'เปลี่ยนใจ',
        items: [{ lineNo: 1, productId: 'p190', name: 'Spark Plug 190', qty: 1, price: '100.00' }],
      };

      const resReturn1 = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_ret_1',
            idempotencyKey: 'k_ret_1',
            type: 'return.create',
            payload: returnPayload1,
          },
        ],
      });
      expect(resReturn1.status).toBe(200);
      expect(resReturn1.body.data.results[0].status).toBe('applied');

      // Different return attempting to reuse the same cnNo
      const returnPayloadColliding = {
        id: 'r_190_colliding',
        cnNo,
        saleId: 's_batch_1',
        refundMethod: 'เงินสด',
        reason: 'ขอคืน',
        items: [{ lineNo: 1, productId: 'p190', name: 'Spark Plug 190', qty: 1, price: '100.00' }],
      };

      const resReturnConflict = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_ret_colliding',
            idempotencyKey: 'k_ret_colliding',
            type: 'return.create',
            payload: returnPayloadColliding,
          },
        ],
      });

      expect(resReturnConflict.status).toBe(200);
      expect(resReturnConflict.body.data.results[0]).toEqual({
        opId: 'op_ret_colliding',
        status: 'rejected',
        code: 'RECEIPT_NO_CONFLICT',
        message: 'เลขที่ใบเสร็จซ้ำ กรุณาทำรายการใหม่',
        details: {
          docNumber: cnNo,
        },
      });
    });
  });

  describe('POST /sync/discards', () => {
    const discard = (
      body: unknown,
      token: string | null = POS_DEVICE_TOKEN,
      idempotencyKey = 'k_discard_1',
    ) => {
      const req = request(app.getHttpServer())
        .post('/api/v1/sync/discards')
        .set('Idempotency-Key', idempotencyKey);
      if (token) req.set('X-Device-Token', token);
      return req.send(body as object);
    };

    it('rejects request without authentication (401)', async () => {
      const res = await discard(
        {
          opId: 'op_disc_1',
          type: 'customer.create',
          note: 'Customer duplicate',
        },
        null,
      );
      expect(res.status).toBe(401);
    });

    it('rejects request with empty or missing note (400)', async () => {
      const res = await discard({
        opId: 'op_disc_1',
        type: 'customer.create',
        note: '   ',
      });
      expect(res.status).toBe(400);
      expect(res.body.error.message).toContain('note');
    });

    it('returns serverHasRow: false when target row does not exist and writes audit log', async () => {
      const opId = 'op_disc_non_existent';
      const clientId = 'c_never_synced';
      const res = await discard({
        opId,
        type: 'customer.create',
        clientId,
        lastCode: 'INSUFFICIENT_STOCK',
        note: 'Discarded by cashier',
      });

      expect(res.status).toBe(200);
      expect(res.body.data).toEqual({ serverHasRow: false });

      // Verify audit log
      const auditRows = await admin.query(
        `SELECT action, entity, entity_id, after FROM audit_log WHERE tenant_id = $1::uuid AND action = 'sync.op.discarded' AND entity_id = $2`,
        [TENANT, opId],
      );
      expect(auditRows.length).toBe(1);
      expect(auditRows[0].action).toBe('sync.op.discarded');
      expect(auditRows[0].entity_id).toBe(opId);
      expect(auditRows[0].after.serverHasRow).toBe(false);
      expect(auditRows[0].after.note).toBe('Discarded by cashier');
    });

    it('returns serverHasRow: true when target row exists on server', async () => {
      // First push a customer so row exists on server
      const clientId = 'c_exists_1';
      await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_c_exists',
            idempotencyKey: 'k_c_exists',
            type: 'customer.create',
            payload: { id: clientId, name: 'Existing Customer' },
          },
        ],
      });

      const opId = 'op_disc_existing';
      const res = await discard({
        opId,
        type: 'customer.create',
        clientId,
        note: 'Already on server',
      });

      expect(res.status).toBe(200);
      expect(res.body.data).toEqual({ serverHasRow: true });
    });

    it('works with Bearer JWT token (owner login)', async () => {
      const userToken = accessToken({
        tenantId: TENANT,
        userId: fixture.userId,
        role: 'owner',
      });

      const res = await request(app.getHttpServer())
        .post('/api/v1/sync/discards')
        .set('Authorization', `Bearer ${userToken}`)
        .set('Idempotency-Key', 'k_discard_jwt')
        .send({
          opId: 'op_jwt_disc',
          type: 'sale.create',
          clientId: 's_missing',
          note: 'Owner discarded from backoffice',
        });

      expect(res.status).toBe(200);
      expect(res.body.data).toEqual({ serverHasRow: false });
    });
  });
});

