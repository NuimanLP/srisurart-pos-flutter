import type { INestApplication } from '@nestjs/common';
import { createHash } from 'node:crypto';
import request from 'supertest';
import type { DataSource } from 'typeorm';
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

      // Verify owner_review_items for void_offline
      const reviews = await admin.query(
        `SELECT kind, ref_id, details FROM owner_review_items WHERE tenant_id = $1::uuid AND kind = 'void_offline'`,
        [TENANT],
      );
      expect(reviews).toHaveLength(1);
      expect(reviews[0].ref_id).toBe('s_off_001');
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
});
