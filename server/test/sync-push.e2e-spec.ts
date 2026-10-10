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
import { testId } from './support/test-ids.js';
import { IdempotencyService } from '../src/idempotency/idempotency.service.js';

const TENANT = '28328328-8328-4283-8283-283283283283';
const POS_DEVICE_TOKEN = 'pos-device-token-01';
const BO_DEVICE_TOKEN = 'bo-device-token-01';

/**
 * Today's Buddhist `YYYY-MM` in the test tenant's timezone — the period an RC/CN number
 * must carry or the push raises a `date_flag` (08 §10). Hardcoding a month breaks the
 * tests the day that month ends.
 */
const currentPeriod = (now = new Date()) => {
  const bkk = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Bangkok', year: 'numeric', month: '2-digit' })
    .formatToParts(now);
  return `${Number(bkk.find((p) => p.type === 'year')!.value) + 543}-${bkk.find((p) => p.type === 'month')!.value}`;
};

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
              opId: testId('op_1'),
              idempotencyKey: 'k_1',
              type: 'customer.create',
              payload: { id: testId('c1'), name: 'Test' },
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
            opId: testId('op_1'),
            idempotencyKey: 'k_1',
            type: 'customer.create',
            payload: { id: testId('c1'), name: 'Test' },
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
            opId: testId('op_1'),
            idempotencyKey: 'k_1',
            type: 'sale.create',
            payload: {
              id: testId('s_1'),
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
            opId: testId('op_shift_001'),
            idempotencyKey: 'k_sh_001',
            type: 'shift.open',
            payload: {
              id: testId('sh_off_001'),
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
              opId: testId('op_shift_001'),
              status: 'applied',
              response: {
                id: testId('sh_off_001'),
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
        `SELECT id, starting_cash, is_active FROM shifts WHERE tenant_id = $1::uuid AND id = '${testId('sh_off_001')}'`,
        [TENANT],
      );
      expect(shifts).toHaveLength(1);
      expect(shifts[0].is_active).toBe(true);
    });

    it('shift-open.archived-previous: open shift auto-archives previously unclosed shift', async () => {
      // Prior shift sh_off_001 active
      await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
        id: testId('sh_off_001'),
        startingCash: 1000,
      });

      const res = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: testId('op_shift_002'),
            idempotencyKey: 'k_sh_002',
            type: 'shift.open',
            payload: {
              id: testId('sh_off_002'),
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
              opId: testId('op_shift_002'),
              status: 'applied',
              response: {
                id: testId('sh_off_002'),
                startingCash: '1000.00',
                openedAt: '2026-09-16T01:00:00.000Z',
                autoArchived: true,
                archivedShiftId: testId('sh_off_001'),
              },
            },
          ],
        },
      });

      const prior = await admin.query(
        `SELECT is_active, auto_archived FROM shifts WHERE tenant_id = $1::uuid AND id = '${testId('sh_off_001')}'`,
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
        opId: testId(`op_${id}`),
        idempotencyKey: `k_${id}`,
        type: 'shift.open',
        payload: { id: testId(id), startingCash: '1000.00', openedAt },
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
        `SELECT id, date_str, opened_at FROM shifts WHERE tenant_id = $1::uuid ORDER BY opened_at`,
        [TENANT],
      )) as { id: string; date_str: string; opened_at: Date }[];
      expect(rows.map((r) => [r.id, r.date_str, r.opened_at.toISOString()])).toEqual([
        [testId('sh_A'), '2026-09-15', '2026-09-15T08:00:00.000Z'],
        [testId('sh_B'), '2026-09-16', '2026-09-16T08:00:00.000Z'],
        [testId('sh_late_utc'), '2026-09-17', '2026-09-16T23:30:00.000Z'],
      ]);
    });

    it('shift.open refuses an unparseable openedAt instead of failing the batch', async () => {
      const res = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: testId('op_bad_open'),
            idempotencyKey: 'k_bad_open',
            type: 'shift.open',
            payload: { id: testId('sh_bad'), startingCash: '100.00', openedAt: 'not-a-date' },
          },
        ],
      });
      expect(res.status).toBe(200);
      expect(res.body.data.results[0]).toMatchObject({
        opId: testId('op_bad_open'),
        status: 'rejected',
        code: 'BAD_REQUEST',
      });
      const rows = await admin.query(
        `SELECT id FROM shifts WHERE tenant_id = $1::uuid AND id = '${testId('sh_bad')}'`,
        [TENANT],
      );
      expect(rows).toHaveLength(0);
    });

    it('sale.create and return.create keep the device date and mark the bill sold_offline', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedProduct(admin, TENANT, {
        id: testId('p411'),
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
            opId: testId('op_s411'),
            idempotencyKey: 'k_s411',
            type: 'sale.create',
            payload: {
              id: testId('s_411'),
              date: deviceDate,
              subtotal: '85.00',
              discount: '0.00',
              total: '85.00',
              paymentMethod: 'เงินสด',
              items: [{ lineNo: 1, productId: testId('p411'), name: 'Filter', qty: 1, price: '85.00' }],
            },
          },
          {
            opId: testId('op_r411'),
            idempotencyKey: 'k_r411',
            type: 'return.create',
            payload: {
              id: testId('cn_411'),
              saleId: testId('s_411'),
              date: deviceDate,
              refundMethod: 'เงินสด',
              items: [{ productId: testId('p411'), name: 'Filter', qty: 1, price: '85.00' }],
            },
          },
        ],
      });
      expect(res.status).toBe(200);
      expect(
        (res.body.data.results as { status: string }[]).map((r) => r.status),
      ).toEqual(['applied', 'applied']);

      const sale = (await admin.query(
        `SELECT date, sold_offline FROM sales WHERE tenant_id = $1::uuid AND id = '${testId('s_411')}'`,
        [TENANT],
      )) as { date: Date; sold_offline: boolean }[];
      expect(sale[0].date.toISOString()).toBe(deviceDate);
      expect(sale[0].sold_offline).toBe(true);
      const ret = (await admin.query(
        `SELECT date FROM returns WHERE tenant_id = $1::uuid AND sale_id = '${testId('s_411')}'`,
        [TENANT],
      )) as { date: Date }[];
      expect(ret[0].date.toISOString()).toBe(deviceDate);
    });

    it('drawer-entry.applied: cash drawer entry pushed to server successfully', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
        id: testId('sh_off_001'),
        startingCash: 1000,
      });

      const res = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: testId('op_drawer_001'),
            idempotencyKey: 'k_de_001',
            type: 'drawer.entry',
            payload: {
              id: testId('de_off_001'),
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
              opId: testId('op_drawer_001'),
              status: 'applied',
              response: {
                id: testId('de_off_001'),
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

    it('drawer-entry B1 step 2: key row gone + body the parser refuses → the stored entry replays', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId, { id: testId('sh_off_s2'), startingCash: 1000 });
      const payload = { id: testId('de_off_s2'), type: 'in', amount: '500.00', note: 'n', createdAt: '2026-09-15T01:30:00.000Z' };
      const op = { opId: testId('op_drawer_s2'), idempotencyKey: 'k_de_s2', type: 'drawer.entry', payload };
      const first = await push({ outboxRemaining: 0, ops: [op] });
      expect(first.body.data.results[0].status).toBe('applied');

      await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid AND key = 'k_de_s2'`, [TENANT]);
      await clearTenantCache(cache, TENANT);
      // `createdAt` the parser refuses; id, type and amount as stored.
      const replay = await push({ outboxRemaining: 0, ops: [{ ...op, payload: { ...payload, createdAt: 'not-a-date' } }] });
      expect(replay.body.data.results[0]).toEqual(first.body.data.results[0]);

      // Unknown id + the same bad body: the parser's refusal, as before.
      const fresh = await push({
        outboxRemaining: 0,
        ops: [{ ...op, opId: testId('op_drawer_s2b'), idempotencyKey: 'k_de_s2b', payload: { ...payload, id: testId('de_off_s2b'), createdAt: 'not-a-date' } }],
      });
      expect(fresh.body.data.results[0]).toMatchObject({ status: 'rejected', code: 'BAD_REQUEST' });

      const n = await admin.query(`SELECT count(*)::int AS n FROM drawer_entries WHERE tenant_id = $1::uuid`, [TENANT]);
      expect(n[0].n).toBe(1);
    });

    it('return.create + credit_payment.create B1 step 2: key row gone + body the parser refuses → the stored row replays', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedProduct(admin, TENANT, { id: testId('p1'), partNo: 'HN-S2', name: 'Oil Filter', price: 85, cost: 50, stock: 45 });
      await seedMechanic(admin, TENANT, { id: testId('m1'), code: 'M01', name: 'ช่างหนึ่ง', creditLimit: 10000, creditBalance: 1500 });

      const sale = {
        opId: testId('op_s2_sale'),
        idempotencyKey: 'k_s2_sale',
        type: 'sale.create',
        payload: {
          id: testId('s_s2'), receiptNo: `RC01-${currentPeriod()}-0301`, subtotal: '170.00', discount: '0.00', total: '170.00', paymentMethod: 'เงินสด',
          items: [{ lineNo: 1, productId: testId('p1'), partNo: 'HN-S2', name: 'Oil Filter', qty: 2, price: '85.00' }],
        },
      };
      const retPayload = {
        id: testId('ret_s2'), saleId: testId('s_s2'), cnNo: `CN01-${currentPeriod()}-0301`, refundMethod: 'เงินสด', reason: 'ชำรุด',
        items: [{ productId: testId('p1'), qty: 1, price: '85.00' }],
      };
      const ret = { opId: testId('op_s2_ret'), idempotencyKey: 'k_s2_ret', type: 'return.create', payload: retPayload };
      const cpPayload = { id: testId('cp_s2'), mechanicId: testId('m1'), amount: '500.00', paymentMethod: 'เงินสด' };
      const cp = { opId: testId('op_s2_cp'), idempotencyKey: 'k_s2_cp', type: 'credit_payment.create', payload: cpPayload };

      const first = await push({ outboxRemaining: 0, ops: [sale, ret, cp] });
      expect(first.body.data.results.map((r: { status: string }) => r.status)).toEqual(['applied', 'applied', 'applied']);
      const [, firstRet, firstCp] = first.body.data.results;

      await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid AND key IN ('k_s2_ret', 'k_s2_cp')`, [TENANT]);
      await clearTenantCache(cache, TENANT);
      // Bodies today's parser refuses; the compared fields as stored.
      const badRet = { ...retPayload, date: 'not-a-date' };
      const badCp = { ...cpPayload, allowOverpayment: 'yes' };
      const replay = await push({ outboxRemaining: 0, ops: [{ ...ret, payload: badRet }, { ...cp, payload: badCp }] });
      expect(replay.body.data.results[0]).toMatchObject({
        status: 'applied',
        response: { id: testId('ret_s2'), cnNo: firstRet.response.cnNo, total: firstRet.response.total },
      });
      expect(replay.body.data.results[1]).toMatchObject({
        status: 'applied',
        response: { id: testId('cp_s2'), amount: '500.00', balanceAfter: firstCp.response.balanceAfter },
      });

      // Unknown ids + the same bad bodies: the parser's refusal, as before.
      const fresh = await push({
        outboxRemaining: 0,
        ops: [
          { ...ret, opId: testId('op_s2_ret_b'), idempotencyKey: 'k_s2_ret_b', payload: { ...badRet, id: testId('ret_s2_b') } },
          { ...cp, opId: testId('op_s2_cp_b'), idempotencyKey: 'k_s2_cp_b', payload: { ...badCp, id: testId('cp_s2_b') } },
        ],
      });
      expect(fresh.body.data.results.map((r: { status: string; code?: string }) => [r.status, r.code])).toEqual([
        ['rejected', 'BAD_REQUEST'],
        ['rejected', 'BAD_REQUEST'],
      ]);

      const counts = await admin.query(
        `SELECT (SELECT count(*)::int FROM returns WHERE tenant_id = $1::uuid) AS r,
                (SELECT count(*)::int FROM credit_payments WHERE tenant_id = $1::uuid) AS c`,
        [TENANT],
      );
      expect(counts[0]).toEqual({ r: 1, c: 1 });
      const stock = await admin.query(`SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = $2`, [TENANT, testId('p1')]);
      expect(stock[0].stock).toBe(44);
    });

    it('shift.open B1 step 2: key row gone + body the parser refuses → the stored shift replays', async () => {
      const payload = { id: testId('sh_s2'), startingCash: '1000.00', openedAt: '2026-09-15T01:00:00.000Z' };
      const op = { opId: testId('op_sh_s2'), idempotencyKey: 'k_sh_s2', type: 'shift.open', payload };
      const first = await push({ outboxRemaining: 0, ops: [op] });
      expect(first.body.data.results[0].status).toBe('applied');

      await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid AND key = 'k_sh_s2'`, [TENANT]);
      await clearTenantCache(cache, TENANT);
      // `openedAt` the parser refuses; id and startingCash as stored.
      const bad = { ...payload, openedAt: 'not-a-date' };
      const replay = await push({ outboxRemaining: 0, ops: [{ ...op, payload: bad }] });
      expect(replay.body.data.results[0]).toEqual(first.body.data.results[0]);

      // Unknown id + the same bad body: the parser's refusal, as before.
      const fresh = await push({
        outboxRemaining: 0,
        ops: [{ ...op, opId: testId('op_sh_s2b'), idempotencyKey: 'k_sh_s2b', payload: { ...bad, id: testId('sh_s2b') } }],
      });
      expect(fresh.body.data.results[0]).toMatchObject({ status: 'rejected', code: 'BAD_REQUEST' });

      // Same id, different startingCash (the compared field): a different shift.
      const other = await push({
        outboxRemaining: 0,
        ops: [{ ...op, opId: testId('op_sh_s2c'), idempotencyKey: 'k_sh_s2c', payload: { ...bad, startingCash: '999.00' } }],
      });
      expect(other.body.data.results[0]).toMatchObject({
        status: 'rejected',
        code: 'CLIENT_ID_REUSED',
        details: { type: 'shift.open', id: testId('sh_s2') },
      });

      const n = await admin.query(`SELECT count(*)::int AS n FROM shifts WHERE tenant_id = $1::uuid`, [TENANT]);
      expect(n[0].n).toBe(1);
    });

    it('customer.create B1 step 2: key row gone + body the parser refuses → the stored customer replays', async () => {
      const payload = { id: testId('c_s2'), name: 'สมชาย สายลม', phone: '0812345678', address: null };
      const op = { opId: testId('op_c_s2'), idempotencyKey: 'k_c_s2', type: 'customer.create', payload };
      const first = await push({ outboxRemaining: 0, ops: [op] });
      expect(first.body.data.results[0].status).toBe('applied');

      await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid AND key = 'k_c_s2'`, [TENANT]);
      await clearTenantCache(cache, TENANT);
      // A `phone` the parser refuses. 08 §6.1 C7: customer.create compares the id only,
      // so there is no field whose mismatch could give CLIENT_ID_REUSED.
      const bad = { ...payload, phone: 812345678 };
      const replay = await push({ outboxRemaining: 0, ops: [{ ...op, payload: bad }] });
      expect(replay.body.data.results[0]).toEqual(first.body.data.results[0]);

      // Unknown id + the same bad body: the parser's refusal, as before.
      const fresh = await push({
        outboxRemaining: 0,
        ops: [{ ...op, opId: testId('op_c_s2b'), idempotencyKey: 'k_c_s2b', payload: { ...bad, id: testId('c_s2b') } }],
      });
      expect(fresh.body.data.results[0]).toMatchObject({ status: 'rejected', code: 'BAD_REQUEST' });

      const rows = await admin.query(`SELECT id, phone FROM customers WHERE tenant_id = $1::uuid`, [TENANT]);
      expect(rows).toEqual([{ id: testId('c_s2'), phone: '0812345678' }]);
    });

    it('sale.void_offline B1 step 2: key row gone + body the parser refuses → the stored void replays', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedProduct(admin, TENANT, { id: testId('p1'), partNo: 'HN-V2', name: 'Oil Filter', price: 85, cost: 50, stock: 50 });
      const sale = (id: string, n: string) => ({
        opId: testId(`op_${id}`),
        idempotencyKey: `k_${id}`,
        type: 'sale.create',
        payload: {
          id: testId(id), receiptNo: `RC01-${currentPeriod()}-${n}`, subtotal: '170.00', discount: '0.00', total: '170.00', paymentMethod: 'เงินสด',
          items: [{ lineNo: 1, productId: testId('p1'), name: 'Oil Filter', qty: 2, price: '85.00' }],
        },
      });
      const stock = async () =>
        (await admin.query(`SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = $2`, [TENANT, testId('p1')]))[0].stock;
      const payload = { saleId: testId('s_v2'), reason: 'ลูกค้าขอยกเลิก' };
      const op = { opId: testId('op_v2'), idempotencyKey: 'k_v2', type: 'sale.void_offline', payload };
      // s_v2 is voided; s_v2b stays an un-voided bill the server holds.
      const first = await push({ outboxRemaining: 0, ops: [sale('s_v2', '0401'), sale('s_v2b', '0402'), op] });
      expect(first.body.data.results.map((r: { status: string }) => r.status)).toEqual(['applied', 'applied', 'applied']);
      const firstVoid = first.body.data.results[2];
      expect(await stock()).toBe(48);

      await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid AND key = 'k_v2'`, [TENANT]);
      await clearTenantCache(cache, TENANT);
      // An empty reason the parser refuses. 08 §6.1: a void replays on "bill already
      // voided" alone — no compared field, so no CLIENT_ID_REUSED case.
      const bad = { ...payload, reason: '   ' };
      const replay = await push({ outboxRemaining: 0, ops: [{ ...op, payload: bad }] });
      expect(replay.body.data.results[0]).toEqual(firstVoid);

      // A bill not yet voided + the same bad body: nothing to replay, the parser's refusal.
      const fresh = await push({
        outboxRemaining: 0,
        ops: [{ ...op, opId: testId('op_v2b'), idempotencyKey: 'k_v2b', payload: { ...bad, saleId: testId('s_v2b') } }],
      });
      expect(fresh.body.data.results[0]).toMatchObject({ status: 'rejected', code: 'BAD_REQUEST' });

      const sales = await admin.query(`SELECT id, voided FROM sales WHERE tenant_id = $1::uuid ORDER BY receipt_no`, [TENANT]);
      expect(sales).toEqual([
        { id: testId('s_v2'), voided: true },
        { id: testId('s_v2b'), voided: false },
      ]);
      const reviews = await admin.query(
        `SELECT ref_id FROM owner_review_items WHERE tenant_id = $1::uuid AND kind = 'void_offline'`,
        [TENANT],
      );
      expect(reviews).toEqual([{ ref_id: testId('s_v2') }]);
      expect(await stock()).toBe(48);
    });

    it('drawer-entry replay: an offline cash-out over the expected cash is still accepted (the cash already left)', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
        id: testId('sh_off_002'),
        startingCash: 1000,
      });

      const res = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: testId('op_drawer_over'),
            idempotencyKey: 'k_de_over',
            type: 'drawer.entry',
            payload: {
              id: testId('de_off_over'),
              type: 'out',
              amount: '1500.00',
              note: null,
              createdAt: new Date().toISOString(),
            },
          },
        ],
      });

      expect(res.status).toBe(200);
      expect(res.body.data.results[0].status).toBe('applied');
      expect(res.body.data.results[0].response.balanceAfter).toBe('-500.00');

      // PR #580 follow-up (owner 2026-10-03): the owner gets one review item for it.
      const reviewItems = async () =>
        (await admin.query(
          `SELECT ref_id, details FROM owner_review_items
            WHERE tenant_id = $1::uuid AND kind = 'drawer_overdrawn_offline'`,
          [TENANT],
        )) as { ref_id: string; details: Record<string, unknown> }[];
      expect(await reviewItems()).toEqual([
        {
          ref_id: testId('de_off_over'),
          details: {
            opId: testId('op_drawer_over'),
            entryId: testId('de_off_over'),
            shiftId: testId('sh_off_002'),
            amount: '1500.00',
            expectedCashBefore: '1000.00',
            expectedCashAfter: '-500.00',
          },
        },
      ]);

      // A re-push of the same op replays by key: still exactly one item.
      const again = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: testId('op_drawer_over'),
            idempotencyKey: 'k_de_over',
            type: 'drawer.entry',
            payload: {
              id: testId('de_off_over'),
              type: 'out',
              amount: '1500.00',
              note: null,
              createdAt: new Date().toISOString(),
            },
          },
        ],
      });
      expect(again.status).toBe(200);
      expect(await reviewItems()).toHaveLength(1);
    });

    it('drawer-entry replay within the expected cash raises no owner review item', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
        id: testId('sh_off_003'),
        startingCash: 1000,
      });

      const res = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: testId('op_drawer_exact'),
            idempotencyKey: 'k_de_exact',
            type: 'drawer.entry',
            payload: {
              id: testId('de_off_exact'),
              type: 'out',
              amount: '1000.00',
              note: null,
              createdAt: new Date().toISOString(),
            },
          },
        ],
      });

      expect(res.body.data.results[0].status).toBe('applied');
      const rows = (await admin.query(
        `SELECT count(*)::int AS n FROM owner_review_items
          WHERE tenant_id = $1::uuid AND kind = 'drawer_overdrawn_offline'`,
        [TENANT],
      )) as { n: number }[];
      expect(rows[0].n).toBe(0);
    });

    it('sale-create.applied, replay-by-key, replay-by-id, client-id-reused', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
        id: testId('sh_off_001'),
        startingCash: 1000,
      });
      await seedProduct(admin, TENANT, {
        id: testId('p1'),
        partNo: 'HN-15412-KVB',
        name: 'Oil Filter',
        price: 85,
        cost: 50,
        stock: 48,
      });

      const salePayload = {
        id: testId('s_off_001'),
        receiptNo: 'RC01-2569-09-0042',
        date: '2026-09-15T02:00:00.000Z',
        subtotal: '255.00',
        discount: '0.00',
        total: '255.00',
        paymentMethod: 'เงินสด',
        items: [
          {
            lineNo: 1,
            productId: testId('p1'),
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
            opId: testId('op_sale_001'),
            idempotencyKey: 'k_sale_001',
            type: 'sale.create',
            payload: salePayload,
          },
        ],
      });

      expect(res1.status).toBe(200);
      // #455 / 08 §8.2: the full `POST /sales` reply, not a push-shaped subset.
      expect(res1.body).toEqual({
        status: 'success',
        data: {
          results: [
            {
              opId: testId('op_sale_001'),
              status: 'applied',
              response: {
                id: testId('s_off_001'),
                receiptNo: 'RC01-2569-09-0042',
                total: '255.00',
                pointsGranted: 25,
                date: expect.any(String),
                shiftId: testId('sh_off_001'),
                paymentAccountId: null,
                products: [{ id: testId('p1'), stock: 45 }],
                items: [{ lineNo: 1, productId: testId('p1'), costAtSale: '50.00' }],
                movements: [
                  {
                    id: expect.any(String),
                    productId: testId('p1'),
                    partNo: 'HN-15412-KVB',
                    name: 'Oil Filter',
                    delta: -3,
                    type: 'sale',
                    note: null,
                    stockAfter: 45,
                    date: expect.any(String),
                  },
                ],
                mechanicCreditBalanceAfter: null,
                mechanicAfter: null,
                customerAfter: null,
              },
            },
          ],
        },
      });
      const applied = res1.body.data.results[0].response;

      // Verify sold_offline column in DB
      const saleRow = await admin.query(
        `SELECT sold_offline, shift_id FROM sales WHERE tenant_id = $1::uuid AND id = '${testId('s_off_001')}'`,
        [TENANT],
      );
      expect(saleRow[0].sold_offline).toBe(true);

      // 2. sale-create.replay-by-key
      const res2 = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: testId('op_sale_001_retry'),
            idempotencyKey: 'k_sale_001',
            type: 'sale.create',
            payload: salePayload,
          },
        ],
      });
      expect(res2.status).toBe(200);
      expect(res2.body.data.results[0]).toEqual({
        opId: testId('op_sale_001_retry'),
        status: 'applied',
        response: applied,
      });

      // 3. sale-create.replay-by-id (idempotency key expired/deleted)
      await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid`, [TENANT]);
      const res3 = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: testId('op_sale_001_reid'),
            idempotencyKey: 'k_sale_fresh_key',
            type: 'sale.create',
            payload: salePayload,
          },
        ],
      });
      expect(res3.status).toBe(200);
      expect(res3.body.data.results[0]).toEqual({
        opId: testId('op_sale_001_reid'),
        status: 'applied',
        response: applied,
      });

      // 4. sale-create.client-id-reused (mismatched total)
      const res4 = await push({
        outboxRemaining: 1,
        ops: [
          {
            opId: testId('op_sale_mismatch'),
            idempotencyKey: 'k_sale_diff',
            type: 'sale.create',
            payload: {
              ...salePayload,
              subtotal: '999.00',
              total: '999.00',
              items: [
                {
                  lineNo: 1,
                  productId: testId('p1'),
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
              opId: testId('op_sale_mismatch'),
              status: 'rejected',
              code: 'CLIENT_ID_REUSED',
              message: 'รหัสรายการซ้ำกับรายการอื่น กรุณาตรวจสอบ',
              details: {
                type: 'sale.create',
                id: testId('s_off_001'),
              },
            },
          ],
        },
      });
    });

    it('sale-create.rejected-stock: rejected when stock insufficient at sync time', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedProduct(admin, TENANT, {
        id: testId('p1'),
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
            opId: testId('op_sale_002'),
            idempotencyKey: 'k_sale_002',
            type: 'sale.create',
            payload: {
              id: testId('s_off_002'),
              receiptNo: 'RC01-2569-09-0043',
              date: '2026-09-15T02:10:00.000Z',
              subtotal: '4250.00',
              discount: '0.00',
              total: '4250.00',
              paymentMethod: 'เงินสด',
              items: [
                {
                  lineNo: 1,
                  productId: testId('p1'),
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
              opId: testId('op_sale_002'),
              status: 'rejected',
              code: 'INSUFFICIENT_STOCK',
              message: 'สต็อกไม่พอ',
              details: {
                productId: testId('p1'),
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
        id: testId('p1'),
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
            opId: testId('op_sale_001'),
            idempotencyKey: 'k_sale_001',
            type: 'sale.create',
            payload: {
              id: testId('s_off_001'),
              receiptNo: 'RC01-2569-09-0042',
              date: '2026-09-15T02:00:00.000Z',
              subtotal: '255.00',
              discount: '0.00',
              total: '255.00',
              paymentMethod: 'เงินสด',
              items: [
                {
                  lineNo: 1,
                  productId: testId('p1'),
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
            opId: testId('op_ret_002'),
            idempotencyKey: 'k_ret_002',
            type: 'return.create',
            payload: {
              id: testId('ret_off_002'),
              saleId: testId('s_off_001'),
              cnNo: 'CN01-2569-09-0006',
              date: '2026-09-15T03:15:00.000Z',
              refundMethod: 'เงินสด',
              reason: 'สินค้าชำรุด',
              subtotal: '120.00',
              total: '120.00',
              items: [{ productId: testId('p1'), qty: 1, price: '120.00' }],
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
              opId: testId('op_ret_002'),
              status: 'rejected',
              code: 'RETURN_PRICE_MISMATCH',
              message: 'ราคาคืนไม่ตรงกับราคาที่ขายจริง กรุณาค้นหาบิลแล้วทำรายการคืนใหม่อีกครั้ง',
              details: {
                productId: testId('p1'),
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
            opId: testId('op_ret_001'),
            idempotencyKey: 'k_ret_001',
            type: 'return.create',
            payload: {
              id: testId('ret_off_001'),
              saleId: testId('s_off_001'),
              cnNo: 'CN01-2569-09-0005',
              date: '2026-09-15T03:00:00.000Z',
              refundMethod: 'เงินสด',
              reason: 'สินค้าชำรุด',
              subtotal: '85.00',
              total: '85.00',
              items: [{ productId: testId('p1'), qty: 1, price: '85.00' }],
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
              opId: testId('op_ret_001'),
              status: 'applied',
              response: {
                id: testId('ret_off_001'),
                cnNo: 'CN01-2569-09-0005',
                saleId: testId('s_off_001'),
                total: '85.00',
                refundMethod: 'เงินสด',
                stockRestored: [{ id: testId('p1'), stock: 43 }],
              },
            },
          ],
        },
      });
    });

    it('credit-payment.applied and rejected-overpayment', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedMechanic(admin, TENANT, {
        id: testId('m1'),
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
            opId: testId('op_cp_002'),
            idempotencyKey: 'k_cp_002',
            type: 'credit_payment.create',
            payload: {
              id: testId('cp_off_002'),
              mechanicId: testId('m1'),
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
              opId: testId('op_cp_002'),
              status: 'rejected',
              code: 'OVERPAYMENT',
              message: 'จำนวนเงินเกินยอดค้างของช่าง กรุณาตรวจจำนวนเงินแล้วลองใหม่',
              details: {
                mechanicId: testId('m1'),
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
            opId: testId('op_cp_001'),
            idempotencyKey: 'k_cp_001',
            type: 'credit_payment.create',
            payload: {
              id: testId('cp_off_001'),
              mechanicId: testId('m1'),
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
              opId: testId('op_cp_001'),
              status: 'applied',
              response: {
                id: testId('cp_off_001'),
                mechanicId: testId('m1'),
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
            opId: testId('op_cust_001'),
            idempotencyKey: 'k_cust_001',
            type: 'customer.create',
            payload: {
              id: testId('c_off_001'),
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
              opId: testId('op_cust_001'),
              status: 'applied',
              response: {
                id: testId('c_off_001'),
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
            opId: testId('op_cust_002'),
            idempotencyKey: 'k_cust_002',
            type: 'customer.update',
            payload: {
              id: testId('c_off_001'),
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
              opId: testId('op_cust_002'),
              status: 'applied',
              response: {
                id: testId('c_off_001'),
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
        id: testId('p1'),
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
            opId: testId('op_sale_001'),
            idempotencyKey: 'k_sale_001',
            type: 'sale.create',
            payload: {
              id: testId('s_off_001'),
              receiptNo: 'RC01-2569-09-0042',
              date: '2026-09-15T02:00:00.000Z',
              subtotal: '170.00',
              discount: '0.00',
              total: '170.00',
              paymentMethod: 'เงินสด',
              items: [{ lineNo: 1, productId: testId('p1'), name: 'Oil Filter', qty: 2, price: '85.00' }],
            },
          },
        ],
      });

      // 2. Seed an online sale s_online_123 (sold_offline = false)
      await admin.query(
        `INSERT INTO sales (tenant_id, id, receipt_no, subtotal, total, payment_method, points_granted, sold_offline, user_id)
         VALUES ($1::uuid, '${testId('s_online_123')}', 'RC01-2569-09-0099', 100.00, 100.00, 'เงินสด', 10, FALSE, $2::uuid)`,
        [TENANT, fixture.userId],
      );

      // 3. Attempting to void online bill via sale.void_offline is rejected (sale-void-offline.rejected-online-bill.json)
      const resOnlineVoid = await push({
        outboxRemaining: 1,
        ops: [
          {
            opId: testId('op_void_002'),
            idempotencyKey: 'k_void_002',
            type: 'sale.void_offline',
            payload: {
              saleId: testId('s_online_123'),
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
              opId: testId('op_void_002'),
              status: 'rejected',
              code: 'VOID_NEEDS_ONLINE',
              message: 'บิลออนไลน์สามารถยกเลิกได้เมื่อเชื่อมต่ออินเทอร์เน็ตเท่านั้น',
              details: {
                saleId: testId('s_online_123'),
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
            opId: testId('op_void_err'),
            idempotencyKey: 'k_void_err',
            type: 'sale.void_offline',
            payload: {
              saleId: testId('s_off_001'),
              reason: '   ',
            },
          },
        ],
      });
      expect(resEmptyReason.status).toBe(200);
      expect(resEmptyReason.body.data.results[0]).toMatchObject({
        opId: testId('op_void_err'),
        status: 'rejected',
        code: 'BAD_REQUEST',
        message: 'Void reason is required',
      });

      // 4. Voiding offline bill succeeds (sale-void-offline.applied.json)
      const resOfflineVoid = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: testId('op_void_001'),
            idempotencyKey: 'k_void_001',
            type: 'sale.void_offline',
            payload: {
              saleId: testId('s_off_001'),
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
              opId: testId('op_void_001'),
              status: 'applied',
              response: {
                saleId: testId('s_off_001'),
                status: 'voided',
                voidReason: 'ลูกค้าขอยกเลิกและเปลี่ยนสินค้า',
                stockRestored: [{ productId: testId('p1'), stock: 50 }],
              },
            },
          ],
        },
      });

      // Verify sales row in DB has void_reason and sold_offline
      const voidedSale = await admin.query(
        `SELECT voided, void_reason, sold_offline FROM sales WHERE tenant_id = $1::uuid AND id = '${testId('s_off_001')}'`,
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
      expect(reviews[0].ref_id).toBe(testId('s_off_001'));
    });

    it('push sale.create and sale.void_offline of that bill in the same batch -> voided + 1 review item', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedProduct(admin, TENANT, {
        id: testId('p1'),
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
            opId: testId('op_sale_batch'),
            idempotencyKey: 'k_sale_batch',
            type: 'sale.create',
            payload: {
              id: testId('s_batch_001'),
              receiptNo: `RC01-${currentPeriod()}-0010`,
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เงินสด',
              items: [{ lineNo: 1, productId: testId('p1'), name: 'Oil Filter', qty: 1, price: '100.00' }],
            },
          },
          {
            opId: testId('op_void_batch'),
            idempotencyKey: 'k_void_batch',
            type: 'sale.void_offline',
            payload: {
              saleId: testId('s_batch_001'),
              reason: 'ผิดบิลในกะเดียวกัน',
            },
          },
        ],
      });

      expect(res.status).toBe(200);
      expect(res.body.data.results).toHaveLength(2);
      expect(res.body.data.results[0].status).toBe('applied');
      expect(res.body.data.results[1]).toEqual({
        opId: testId('op_void_batch'),
        status: 'applied',
        response: {
          saleId: testId('s_batch_001'),
          status: 'voided',
          voidReason: 'ผิดบิลในกะเดียวกัน',
          stockRestored: [{ productId: testId('p1'), stock: 50 }],
        },
      });

      // Verify DB row
      const rows = await admin.query(
        `SELECT voided, void_reason, sold_offline FROM sales WHERE tenant_id = $1::uuid AND id = '${testId('s_batch_001')}'`,
        [TENANT],
      );
      expect(rows[0].voided).toBe(true);
      expect(rows[0].void_reason).toBe('ผิดบิลในกะเดียวกัน');
      expect(rows[0].sold_offline).toBe(true);

      // Verify review item
      const reviews = await admin.query(
        `SELECT kind, ref_id, details FROM owner_review_items WHERE tenant_id = $1::uuid AND ref_id = '${testId('s_batch_001')}'`,
        [TENANT],
      );
      expect(reviews).toHaveLength(1);
      expect(reviews[0].kind).toBe('void_offline');
      expect(reviews[0].details.reason).toBe('ผิดบิลในกะเดียวกัน');
    });

    it('batch.stop-at-retry: when op N fails with retry, subsequent ops return retry without processing', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedProduct(admin, TENANT, {
        id: testId('p1'),
        partNo: 'HN-15412-KVB',
        name: 'Oil Filter',
        price: 100,
        cost: 50,
        stock: 10,
      });

      const makeSaleOp = (num: number) => ({
        opId: testId(`op_${num}`),
        idempotencyKey: `k_${num}`,
        type: 'sale.create',
        payload: {
          id: testId(`s_batch_${num}`),
          receiptNo: `RC01-2569-09-005${num - 1}`,
          date: `2026-09-15T05:0${num - 1}:00.000Z`,
          subtotal: '100.00',
          discount: '0.00',
          total: '100.00',
          paymentMethod: 'เงินสด',
          items: [{ lineNo: 1, productId: testId('p1'), name: 'Oil Filter', qty: 1, price: '100.00' }],
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
          if (op.opId === testId('op_2')) {
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
              opId: testId('op_1'),
              status: 'applied',
              response: expect.objectContaining({
                id: testId('s_batch_1'),
                receiptNo: 'RC01-2569-09-0050',
                total: '100.00',
                pointsGranted: 10,
                products: [{ id: testId('p1'), stock: 9 }],
                items: [{ lineNo: 1, productId: testId('p1'), costAtSale: '50.00' }],
              }),
            },
            {
              opId: testId('op_2'),
              status: 'retry',
            },
            {
              opId: testId('op_3'),
              status: 'retry',
            },
            {
              opId: testId('op_4'),
              status: 'retry',
            },
          ],
        },
      });

      // Ensure s_batch_3 and s_batch_4 were never processed / created in DB
      const sales = await admin.query(
        `SELECT id FROM sales WHERE tenant_id = $1::uuid AND id IN ('${testId('s_batch_2')}', '${testId('s_batch_3')}', '${testId('s_batch_4')}')`,
        [TENANT],
      );
      expect(sales).toHaveLength(0);
    });

    it('devices.unsynced_ops is updated from outboxRemaining (08 §8.2 C12)', async () => {
      await push({
        outboxRemaining: 15,
        ops: [
          {
            opId: testId('op_c1'),
            idempotencyKey: 'k_c1',
            type: 'customer.create',
            payload: { id: testId('c_outbox'), name: 'ลูกค้าทดสอบ' },
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
        id: testId('sh_review'),
        startingCash: 500,
      });
      await seedProduct(admin, TENANT, {
        id: testId('p1'),
        partNo: 'HN-15412-KVB',
        name: 'Oil Filter',
        price: 100,
        cost: 50,
        stock: 50,
      });
      await seedMechanic(admin, TENANT, {
        id: testId('m1'),
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
            opId: testId('op_date_flag'),
            idempotencyKey: 'k_df_1',
            type: 'sale.create',
            payload: {
              id: testId('s_date_flag'),
              receiptNo: 'RC01-2569-09-0088',
              date: futureDate,
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เงินสด',
              items: [{ lineNo: 1, productId: testId('p1'), name: 'Oil Filter', qty: 1, price: '100.00' }],
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
            opId: testId('op_credit_override'),
            idempotencyKey: 'k_co_1',
            type: 'sale.create',
            payload: {
              id: testId('s_credit_override'),
              receiptNo: 'RC01-2569-09-0089',
              subtotal: '200.00',
              discount: '0.00',
              total: '200.00',
              paymentMethod: 'เครดิตช่าง',
              mechanicId: testId('m1'),
              overrideCreditLimit: true,
              items: [{ lineNo: 1, productId: testId('p1'), name: 'Oil Filter', qty: 2, price: '100.00' }],
            },
          },
        ],
      });

      const creditReviews = await admin.query(
        `SELECT kind, ref_id FROM owner_review_items WHERE tenant_id = $1::uuid AND kind = 'credit_override'`,
        [TENANT],
      );
      expect(creditReviews).toHaveLength(1);
      expect(creditReviews[0].ref_id).toBe(testId('s_credit_override'));
    });

    it('Slice 14-s (#285): credit limit override via push creates credit_override review item and single audit_log row, B1 replay preserved', async () => {
      const receiptNo = `RC01-${currentPeriod()}-0092`;
      await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
        id: testId('sh_co_14'),
        startingCash: 500,
      });
      await seedProduct(admin, TENANT, {
        id: testId('p_co_14'),
        partNo: 'HN-CO-14',
        name: 'Brake Pad CO14',
        price: 100,
        cost: 50,
        stock: 50,
      });
      await seedMechanic(admin, TENANT, {
        id: testId('m14'),
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
            opId: testId('op_co_refused'),
            idempotencyKey: 'k_co_refused',
            type: 'sale.create',
            payload: {
              id: testId('s_co_refused'),
              receiptNo: 'RC01-2569-09-0091',
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เครดิตช่าง',
              mechanicId: testId('m14'),
              items: [{ lineNo: 1, productId: testId('p_co_14'), name: 'Brake Pad CO14', qty: 1, price: '100.00' }],
            },
          },
        ],
      });

      expect(resWithoutFlag.status).toBe(200);
      expect(resWithoutFlag.body.data.results[0]).toMatchObject({
        opId: testId('op_co_refused'),
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
        `SELECT count(*)::int AS n FROM audit_log WHERE tenant_id = $1::uuid AND entity_id = '${testId('m14')}'`,
        [TENANT],
      );
      expect(auditRefused[0].n).toBe(0);
      const reviewsRefused = await admin.query(
        `SELECT count(*)::int AS n FROM owner_review_items WHERE tenant_id = $1::uuid AND ref_id = '${testId('s_co_refused')}'`,
        [TENANT],
      );
      expect(reviewsRefused[0].n).toBe(0);

      // 2. Pushing with overrideCreditLimit: true succeeds and creates 1 review item + 1 audit_log row
      const resWithFlag = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: testId('op_co_success'),
            idempotencyKey: 'k_co_success',
            type: 'sale.create',
            payload: {
              id: testId('s_co_14'),
              receiptNo,
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เครดิตช่าง',
              mechanicId: testId('m14'),
              overrideCreditLimit: true,
              items: [{ lineNo: 1, productId: testId('p_co_14'), name: 'Brake Pad CO14', qty: 1, price: '100.00' }],
            },
          },
        ],
      });

      expect(resWithFlag.status).toBe(200);
      expect(resWithFlag.body.data.results[0].status).toBe('applied');

      // Verify owner_review_items: exactly 1 row
      const reviews = await admin.query(
        `SELECT kind, ref_id, details FROM owner_review_items WHERE tenant_id = $1::uuid AND ref_id = '${testId('s_co_14')}'`,
        [TENANT],
      );
      expect(reviews).toHaveLength(1);
      expect(reviews[0]).toMatchObject({
        kind: 'credit_override',
        ref_id: testId('s_co_14'),
        details: {
          saleId: testId('s_co_14'),
          mechanicId: testId('m14'),
          total: '100.00',
          creditLimit: '50.00',
          creditBalanceAfter: '100.00',
        },
      });

      // Verify audit_log: exactly 1 row, tied to shop user and push device
      const audits = await admin.query(
        `SELECT action, entity, entity_id, user_id, device_id, after FROM audit_log
          WHERE tenant_id = $1::uuid AND action = 'sale.credit_limit_override' AND entity_id = '${testId('m14')}'`,
        [TENANT],
      );
      expect(audits).toHaveLength(1);
      expect(audits[0]).toMatchObject({
        action: 'sale.credit_limit_override',
        entity: 'mechanic',
        entity_id: testId('m14'),
        user_id: fixture.userId,
        device_id: fixture.posDeviceId,
        after: {
          saleId: testId('s_co_14'),
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
            opId: testId('op_co_success'),
            idempotencyKey: 'k_co_success',
            type: 'sale.create',
            payload: {
              id: testId('s_co_14'),
              receiptNo,
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เครดิตช่าง',
              mechanicId: testId('m14'),
              overrideCreditLimit: true,
              items: [{ lineNo: 1, productId: testId('p_co_14'), name: 'Brake Pad CO14', qty: 1, price: '100.00' }],
            },
          },
        ],
      });

      expect(resReplay.status).toBe(200);
      expect(resReplay.body.data.results[0].status).toBe('applied');

      // Verify no duplication in owner_review_items (still exactly 1)
      const reviewsAfterReplay = await admin.query(
        `SELECT count(*)::int AS n FROM owner_review_items WHERE tenant_id = $1::uuid AND ref_id = '${testId('s_co_14')}'`,
        [TENANT],
      );
      expect(reviewsAfterReplay[0].n).toBe(1);

      // Verify no duplication in audit_log (still exactly 1)
      const auditsAfterReplay = await admin.query(
        `SELECT count(*)::int AS n FROM audit_log
          WHERE tenant_id = $1::uuid AND action = 'sale.credit_limit_override' AND entity_id = '${testId('m14')}'`,
        [TENANT],
      );
      expect(auditsAfterReplay[0].n).toBe(1);

      // Verify mechanic balance not doubled
      const mechanicRow = await admin.query(
        `SELECT credit_balance FROM mechanics WHERE tenant_id = $1::uuid AND id = '${testId('m14')}'`,
        [TENANT],
      );
      expect(mechanicRow[0].credit_balance).toBe('100.00');
    });

    describe('#409 / 08 §8.4 AC B1: a bill committed ONLINE whose reply was lost, then pushed', () => {
      // `ApiSalesRepository.saveSale` falls back to the outbox with the SAME bill id and
      // `Idempotency-Key` when `POST /api/v1/sales` gets no answer. The server may already
      // have committed that bill; the push must then replay it, never refuse it.
      const onlineBody = {
        id: testId('s_b1_online'),
        subtotal: '100.00',
        discount: '0.00',
        total: '100.00',
        paymentMethod: 'เครดิตช่าง',
        customerId: null,
        customerName: null,
        mechanicId: testId('m_b1'),
        mechanicName: 'ช่าง B1',
        mechanicDelta: null,
        overrideCreditLimit: true,
        items: [
          { lineNo: 1, productId: testId('p_b1'), partNo: 'HN-B1', name: 'Brake Pad B1', nameTH: null, qty: 2, price: '50.00' },
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
        await seedOpenShift(admin, TENANT, fixture.posDeviceId, { id: testId('sh_b1'), startingCash: 500 });
        await seedProduct(admin, TENANT, {
          id: testId('p_b1'),
          partNo: 'HN-B1',
          name: 'Brake Pad B1',
          price: 50,
          cost: 30,
          stock: 20,
        });
        await seedMechanic(admin, TENANT, {
          id: testId('m_b1'),
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
        expect(await stockOf(testId('p_b1'))).toBe(18);

        const res = await push({
          outboxRemaining: 0,
          ops: [{ opId: testId('op_b1'), idempotencyKey: 'k_b1', type: 'sale.create', payload: outboxPayload }],
        });

        expect(res.status).toBe(200);
        // #455 / 08 §8.2: the client-id replay answers with exactly what `POST /sales`
        // answered — `items[].costAtSale`, `movements`, `shiftId`, `date`, ledgers.
        expect(res.body.data.results[0]).toEqual({
          opId: testId('op_b1'),
          status: 'applied',
          response: online.body.data,
        });
        expect(online.body.data).toMatchObject({
          id: testId('s_b1_online'),
          receiptNo: serverReceiptNo,
          total: '100.00',
          shiftId: testId('sh_b1'),
          items: [{ lineNo: 1, productId: testId('p_b1'), costAtSale: '30.00' }],
          mechanicAfter: { id: testId('m_b1'), creditBalance: '100.00' },
        });
        // Replayed, not re-run: one bill, stock down once, the override audited once.
        expect(await stockOf(testId('p_b1'))).toBe(18);
        const sales = await admin.query(
          `SELECT receipt_no FROM sales WHERE tenant_id = $1::uuid AND id = '${testId('s_b1_online')}'`,
          [TENANT],
        );
        expect(sales).toEqual([{ receipt_no: serverReceiptNo }]);
        const audits = await admin.query(
          `SELECT user_id FROM audit_log
            WHERE tenant_id = $1::uuid AND action = 'sale.credit_limit_override' AND entity_id = '${testId('m_b1')}'`,
          [TENANT],
        );
        expect(audits).toEqual([{ user_id: fixture.userId }]);
        const mech = await admin.query(
          `SELECT credit_balance FROM mechanics WHERE tenant_id = $1::uuid AND id = '${testId('m_b1')}'`,
          [TENANT],
        );
        expect(mech[0].credit_balance).toBe('100.00');
      });

      it('an op whose body equals the online body replays the stored online response by key (step 1)', async () => {
        const online = await postOnline('k_b1_same', onlineBody);
        expect(online.status).toBe(201);

        const res = await push({
          outboxRemaining: 0,
          ops: [{ opId: testId('op_b1_same'), idempotencyKey: 'k_b1_same', type: 'sale.create', payload: onlineBody }],
        });

        // The full online response, replayed from the key row (the client-id replay
        // answers with the same body since #455 — see the test above).
        expect(res.body.data.results[0]).toEqual({
          opId: testId('op_b1_same'),
          status: 'applied',
          response: online.body.data,
        });
        expect(await stockOf(testId('p_b1'))).toBe(18);
      });

      it('a key an older push recorded as `POST /sales` (before #409) still replays, and a key recorded on another route does not', async () => {
        const op = { opId: testId('op_b1_legacy'), idempotencyKey: 'k_b1_legacy', type: 'sale.create', payload: outboxPayload };
        expect((await push({ outboxRemaining: 0, ops: [op] })).body.data.results[0].status).toBe('applied');
        await admin.query(
          `UPDATE idempotency_keys SET endpoint = 'POST /sales' WHERE tenant_id = $1::uuid AND key = 'k_b1_legacy'`,
          [TENANT],
        );
        await clearTenantCache(cache, TENANT);
        const replay = await push({ outboxRemaining: 0, ops: [op] });
        expect(replay.body.data.results[0]).toMatchObject({ status: 'applied', response: { id: testId('s_b1_online') } });

        await admin.query(
          `UPDATE idempotency_keys SET endpoint = 'POST /api/v1/returns' WHERE tenant_id = $1::uuid AND key = 'k_b1_legacy'`,
          [TENANT],
        );
        await clearTenantCache(cache, TENANT);
        const wrongRoute = await push({ outboxRemaining: 0, ops: [op] });
        expect(wrongRoute.body.data.results[0]).toMatchObject({ status: 'rejected', code: 'IDEMPOTENCY_KEY_REUSED' });
        expect(await stockOf(testId('p_b1'))).toBe(18);
      });

      it('B1: replay by key runs before the payload parser — an applied op a later parser would refuse still replays its stored reply', async () => {
        // Simulate a parser tightened after the op was applied: the key row's fingerprint
        // is rewritten to a body today's parser refuses (`customerId` not a UUID), as if
        // that body had been valid when it was committed and its reply was lost.
        const op = { opId: testId('op_b1_tight'), idempotencyKey: 'k_b1_tight', type: 'sale.create', payload: outboxPayload };
        const first = await push({ outboxRemaining: 0, ops: [op] });
        expect(first.body.data.results[0].status).toBe('applied');
        const stored = first.body.data.results[0].response;

        const refused = { ...outboxPayload, customerId: 'C-legacy-1' };
        await admin.query(
          `UPDATE idempotency_keys SET request_hash = $2 WHERE tenant_id = $1::uuid AND key = 'k_b1_tight'`,
          [TENANT, IdempotencyService.requestHash(refused)],
        );
        await clearTenantCache(cache, TENANT);

        const replay = await push({ outboxRemaining: 0, ops: [{ ...op, payload: refused }] });
        expect(replay.body.data.results[0]).toEqual({ opId: testId('op_b1_tight'), status: 'applied', response: stored });
        expect(await stockOf(testId('p_b1'))).toBe(18);
      });

      it('#619: a fresh op the parser refuses is rejected INVALID_ID per op (never `retry`), a bad route id included', async () => {
        const refused = { ...outboxPayload, customerId: 'C-legacy-1' };
        const fresh = await push({
          outboxRemaining: 0,
          ops: [{ opId: testId('op_b1_fresh'), idempotencyKey: 'k_b1_fresh', type: 'sale.create', payload: { ...refused, id: testId('s_b1_fresh') } }],
        });
        expect(fresh.body.data.results[0]).toMatchObject({
          opId: testId('op_b1_fresh'),
          status: 'rejected',
          code: 'INVALID_ID',
          details: { field: 'payload.customerId' },
        });
        // A malformed id that is part of the online route (`/mechanics/:id/…`) is still
        // rejected per op, not a 22P02 → `retry`.
        const badRoute = await push({
          outboxRemaining: 0,
          ops: [{
            opId: testId('op_b1_badmech'),
            idempotencyKey: 'k_b1_badmech',
            type: 'credit_payment.create',
            payload: { id: testId('cp_b1_bad'), mechanicId: 'M-legacy', amount: '10.00', paymentMethod: 'เงินสด' },
          }],
        });
        expect(badRoute.body.data.results[0]).toMatchObject({
          status: 'rejected',
          code: 'INVALID_ID',
          details: { field: 'payload.mechanicId' },
        });
        expect(await stockOf(testId('p_b1'))).toBe(20);
      });

      it('B1 step 2: key row gone + bill already stored → the client-id replay runs before the parser too', async () => {
        const op = { opId: testId('op_b1_step2'), idempotencyKey: 'k_b1_step2', type: 'sale.create', payload: outboxPayload };
        const first = await push({ outboxRemaining: 0, ops: [op] });
        expect(first.body.data.results[0].status).toBe('applied');
        const stored = first.body.data.results[0].response;
        expect(await stockOf(testId('p_b1'))).toBe(18);

        // The key row expired (24 h) or was deleted (B2); the body is one today's parser refuses.
        await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid AND key = 'k_b1_step2'`, [TENANT]);
        await clearTenantCache(cache, TENANT);
        const refused = { ...outboxPayload, customerId: 'C-legacy-1' };

        const replay = await push({ outboxRemaining: 0, ops: [{ ...op, payload: refused }] });
        expect(replay.body.data.results[0]).toEqual({ opId: testId('op_b1_step2'), status: 'applied', response: stored });
        expect(replay.body.data.results[0].response.receiptNo).toBe(stored.receiptNo);
        expect(await stockOf(testId('p_b1'))).toBe(18);

        // Same id, different total, still a body the parser refuses: a different bill, as before.
        const other = await push({
          outboxRemaining: 0,
          ops: [{ opId: testId('op_b1_step2_other'), idempotencyKey: 'k_b1_step2_other', type: 'sale.create', payload: { ...refused, total: '99.00' } }],
        });
        expect(other.body.data.results[0]).toMatchObject({
          status: 'rejected',
          code: 'CLIENT_ID_REUSED',
          details: { type: 'sale.create', id: testId('s_b1_online') },
        });

        // A malformed client id never reaches the replay: the parser's INVALID_ID, as before.
        const badId = await push({
          outboxRemaining: 0,
          ops: [{ opId: testId('op_b1_step2_badid'), idempotencyKey: 'k_b1_step2_badid', type: 'sale.create', payload: { ...outboxPayload, id: 'S-legacy-1' } }],
        });
        expect(badId.body.data.results[0]).toMatchObject({
          status: 'rejected',
          code: 'INVALID_ID',
          details: { field: 'payload.id' },
        });

        // An unknown (well-formed) id with the refused body: nothing to replay, the parser's refusal.
        const unknown = await push({
          outboxRemaining: 0,
          ops: [{ opId: testId('op_b1_step2_unknown'), idempotencyKey: 'k_b1_step2_unknown', type: 'sale.create', payload: { ...refused, id: testId('s_b1_step2_unknown') } }],
        });
        expect(unknown.body.data.results[0]).toMatchObject({
          status: 'rejected',
          code: 'INVALID_ID',
          details: { field: 'payload.customerId' },
        });

        const n = await admin.query(`SELECT count(*)::int AS n FROM sales WHERE tenant_id = $1::uuid`, [TENANT]);
        expect(n[0].n).toBe(1);
        expect(await stockOf(testId('p_b1'))).toBe(18);
      });

      it('the same key on a DIFFERENT bill is still refused IDEMPOTENCY_KEY_REUSED', async () => {
        expect((await postOnline('k_b1_reuse', onlineBody)).status).toBe(201);
        // A second, genuinely different bill already on the server under its own key.
        const other = { ...onlineBody, id: testId('s_b1_other'), overrideCreditLimit: false, paymentMethod: 'เงินสด', mechanicId: null, mechanicName: null };
        expect((await postOnline('k_b1_other', other)).status).toBe(201);
        expect(await stockOf(testId('p_b1'))).toBe(16);

        const res = await push({
          outboxRemaining: 0,
          ops: [
            // A bill the server has never seen, carrying k_b1_reuse.
            {
              opId: testId('op_new_bill'),
              idempotencyKey: 'k_b1_reuse',
              type: 'sale.create',
              payload: { ...outboxPayload, id: testId('s_b1_new'), receiptNo: 'RC01-2569-09-0778' },
            },
          ],
        });
        expect(res.body.data.results[0]).toMatchObject({
          opId: testId('op_new_bill'),
          status: 'rejected',
          code: 'IDEMPOTENCY_KEY_REUSED',
        });

        const res2 = await push({
          outboxRemaining: 0,
          ops: [
            // An existing bill (s_b1_other), but under the key that belongs to s_b1_online.
            {
              opId: testId('op_other_bill'),
              idempotencyKey: 'k_b1_reuse',
              type: 'sale.create',
              payload: { ...other, receiptNo: 'RC01-2569-09-0779', date: outboxPayload.date },
            },
          ],
        });
        expect(res2.body.data.results[0]).toMatchObject({
          opId: testId('op_other_bill'),
          status: 'rejected',
          code: 'IDEMPOTENCY_KEY_REUSED',
        });

        const n = await admin.query(
          `SELECT count(*)::int AS n FROM sales WHERE tenant_id = $1::uuid`,
          [TENANT],
        );
        expect(n[0].n).toBe(2);
        expect(await stockOf(testId('p_b1'))).toBe(16);
      });

      it('owner 2026-09-25: a replay whose offline receiptNo differs from the stored one → ONE receipt_renumbered item, even when replayed again', async () => {
        const online = await postOnline('k_b1_renum', onlineBody);
        expect(online.status).toBe(201);
        const serverReceiptNo = online.body.data.receiptNo as string;
        expect(serverReceiptNo).not.toBe(outboxPayload.receiptNo);

        const op = { opId: testId('op_b1_renum'), idempotencyKey: 'k_b1_renum', type: 'sale.create', payload: outboxPayload };
        for (let i = 0; i < 2; i++) {
          const res = await push({ outboxRemaining: 0, ops: [op] });
          expect(res.body.data.results[0]).toMatchObject({
            status: 'applied',
            response: { id: testId('s_b1_online'), receiptNo: serverReceiptNo },
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
            ref_id: testId('s_b1_online'),
            details: {
              opId: testId('op_b1_renum'),
              type: 'sale.create',
              id: testId('s_b1_online'),
              offlineNo: 'RC01-2569-09-0777',
              serverNo: serverReceiptNo,
            },
          },
        ]);
        expect(await stockOf(testId('p_b1'))).toBe(18);
      });

      it('the credit-note side: a replayed return whose offline cnNo differs → one receipt_renumbered item; a junk cnNo raises none', async () => {
        const cashSale = { ...onlineBody, id: testId('s_cn_ren'), paymentMethod: 'เงินสด', mechanicId: null, mechanicName: null, overrideCreditLimit: false };
        expect((await postOnline('k_cn_ren_sale', cashSale)).status).toBe(201);
        const retBody = {
          id: testId('cn_ren'),
          saleId: testId('s_cn_ren'),
          refundMethod: 'เงินสด',
          items: [{ productId: testId('p_b1'), name: 'Brake Pad B1', qty: 1, price: '50.00' }],
        };
        const online = await request(app.getHttpServer())
          .post('/api/v1/returns')
          .set(
            'Authorization',
            `Bearer ${accessToken({ tenantId: TENANT, userId: fixture.userId, deviceId: fixture.posDeviceId, deviceRole: 'pos' })}`,
          )
          .set('Idempotency-Key', 'k_cn_ren')
          .send(retBody);
        expect(online.status).toBe(201);
        const serverCnNo = online.body.data.cnNo as string;

        const op = (cnNo: string) => ({
          opId: testId('op_cn_ren'),
          idempotencyKey: 'k_cn_ren',
          type: 'return.create',
          payload: { ...retBody, cnNo, date: outboxPayload.date },
        });
        // Junk number first: not an RC/CN number → no item, still applied.
        expect((await push({ outboxRemaining: 0, ops: [op('garbage')] })).body.data.results[0].status).toBe('applied');
        for (let i = 0; i < 2; i++) {
          const res = await push({ outboxRemaining: 0, ops: [op('CN01-2569-09-0555')] });
          expect(res.body.data.results[0]).toMatchObject({ status: 'applied', response: { id: testId('cn_ren'), cnNo: serverCnNo } });
        }
        const items = await admin.query(
          `SELECT ref_id, details FROM owner_review_items WHERE tenant_id = $1::uuid AND kind = 'receipt_renumbered'`,
          [TENANT],
        );
        expect(items).toEqual([
          {
            ref_id: testId('cn_ren'),
            details: { opId: testId('op_cn_ren'), type: 'return.create', id: testId('cn_ren'), offlineNo: 'CN01-2569-09-0555', serverNo: serverCnNo },
          },
        ]);
      });

      it('a replay carrying the SAME number as the stored bill raises no receipt_renumbered item', async () => {
        const online = await postOnline('k_b1_samenum', onlineBody);
        const payload = { ...outboxPayload, receiptNo: online.body.data.receiptNo };
        const res = await push({
          outboxRemaining: 0,
          ops: [{ opId: testId('op_b1_samenum'), idempotencyKey: 'k_b1_samenum', type: 'sale.create', payload }],
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
        opId: testId(`op_${id}`),
        idempotencyKey: `k_${id}`,
        type: 'sale.create',
        payload: {
          id: testId(id),
          date,
          subtotal: '85.00',
          discount: '0.00',
          total: '85.00',
          paymentMethod: 'เงินสด',
          items: [{ lineNo: 1, productId: testId('p_d10'), name: 'Filter', qty: 1, price: '85.00' }],
        },
      });
      const flags = async () =>
        (await admin.query(
          `SELECT ref_id, details FROM owner_review_items WHERE tenant_id = $1::uuid AND kind = 'date_flag' ORDER BY ref_id`,
          [TENANT],
        )) as { ref_id: string; details: Record<string, unknown> }[];

      beforeEach(async () => {
        await seedProduct(admin, TENANT, { id: testId('p_d10'), partNo: 'P-D10', name: 'Filter', price: 85, cost: 50, stock: 10 });
      });

      it('an unparseable date is rejected, not silently replaced with now()', async () => {
        await seedOpenShift(admin, TENANT, fixture.posDeviceId);
        const res = await push({ outboxRemaining: 0, ops: [saleOp('s_bad_date', 'not-a-date')] });
        expect(res.body.data.results[0]).toMatchObject({ status: 'rejected', code: 'BAD_REQUEST' });
        expect(await admin.query(`SELECT 1 FROM sales WHERE tenant_id = $1::uuid AND id = '${testId('s_bad_date')}'`, [TENANT])).toHaveLength(0);
      });

      it('an empty-string date is rejected (never falls through to createdAt or now()); an absent date → now(), unflagged', async () => {
        await seedOpenShift(admin, TENANT, fixture.posDeviceId);
        const noDate = saleOp('s_no_date', undefined);
        const before = Date.now();
        const res = await push({
          outboxRemaining: 0,
          ops: [
            { ...saleOp('s_empty_date', ''), payload: { ...saleOp('s_empty_date', '').payload, createdAt: new Date().toISOString() } },
            noDate,
          ],
        });
        expect(res.body.data.results[0]).toMatchObject({ status: 'rejected', code: 'BAD_REQUEST' });
        expect(res.body.data.results[1].status).toBe('applied');
        const rows = (await admin.query(
          `SELECT id, date FROM sales WHERE tenant_id = $1::uuid ORDER BY id`,
          [TENANT],
        )) as { id: string; date: Date }[];
        expect(rows.map((r) => r.id)).toEqual([testId('s_no_date')]);
        expect(rows[0].date.getTime()).toBeGreaterThanOrEqual(before - 1000);
        expect(await flags()).toHaveLength(0);
      });

      it('a clamped op with a wrong period gets ONE flag carrying both; a rejected op leaves no flag', async () => {
        await seedOpenShift(admin, TENANT, fixture.posDeviceId);
        const future = new Date(Date.now() + 10 * 60 * 1000).toISOString();
        const both = saleOp('s_both', future);
        const tooMany = saleOp('s_nostock', future);
        tooMany.payload.items[0].qty = 999;
        Object.assign(tooMany.payload, { subtotal: '84915.00', total: '84915.00' });
        const res = await push({
          outboxRemaining: 0,
          ops: [{ ...both, payload: { ...both.payload, receiptNo: 'RC01-2500-01-0201' } }, tooMany],
        });
        expect(res.body.data.results[0].status).toBe('applied');
        expect(res.body.data.results[1]).toMatchObject({ status: 'rejected', code: 'INSUFFICIENT_STOCK' });

        const f = await flags();
        expect(f).toHaveLength(1);
        expect(f[0]).toMatchObject({
          ref_id: testId('s_both'),
          details: { originalDate: future, docNo: 'RC01-2500-01-0201', docPeriod: '2500-01' },
        });
        expect(f[0].details.clampedDate).not.toBe(future);
      });

      it('no active shift: a date 10 min ahead → now() + date_flag; a past date is kept unflagged', async () => {
        // A sale needs an open drawer; a non-cash refund does not (#100), so the
        // no-shift path is reached by a transfer refund after the shift is archived.
        await seedOpenShift(admin, TENANT, fixture.posDeviceId, { id: testId('sh_d10') });
        const sale = saleOp('s_d10', new Date().toISOString());
        sale.payload.items[0].qty = 2;
        Object.assign(sale.payload, { subtotal: '170.00', total: '170.00' });
        expect((await push({ outboxRemaining: 0, ops: [sale] })).body.data.results[0].status).toBe('applied');
        await admin.query(
          `UPDATE shifts SET is_active = false, closed_at = now() WHERE tenant_id = $1::uuid AND id = '${testId('sh_d10')}'`,
          [TENANT],
        );

        const refund = (id: string, date: string) => ({
          opId: testId(`op_${id}`),
          idempotencyKey: `k_${id}`,
          type: 'return.create',
          payload: {
            id: testId(id),
            saleId: testId('s_d10'),
            date,
            refundMethod: 'โอน',
            items: [{ productId: testId('p_d10'), name: 'Filter', qty: 1, price: '85.00' }],
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
        expect(byId[testId('cn_np')]).toBe(new Date(past).getTime());
        expect(byId[testId('cn_nf')]).toBeGreaterThanOrEqual(before - 1000);
        expect(byId[testId('cn_nf')]).toBeLessThan(new Date(future).getTime() - 60 * 1000);

        const f = await flags();
        expect(f).toHaveLength(1);
        expect(f[0].ref_id).toBe(testId('cn_nf'));
        expect(f[0].details).toMatchObject({ opId: testId('op_cn_nf'), type: 'return.create', originalDate: future, openedAt: null });
      });

      it('a closed (not yet archived) shift is no window: a refund dated before it is kept, unflagged', async () => {
        await seedOpenShift(admin, TENANT, fixture.posDeviceId, { id: testId('sh_closed') });
        const sale = saleOp('s_closed', new Date().toISOString());
        expect((await push({ outboxRemaining: 0, ops: [sale] })).body.data.results[0].status).toBe('applied');
        // Closed by the counter: `is_active` stays true until the next open archives it.
        await admin.query(
          `UPDATE shifts SET opened_at = now() - interval '3 hours', closed_at = now()
            WHERE tenant_id = $1::uuid AND id = '${testId('sh_closed')}'`,
          [TENANT],
        );
        const past = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
        const res = await push({
          outboxRemaining: 0,
          ops: [
            {
              opId: testId('op_cn_closed'),
              idempotencyKey: 'k_cn_closed',
              type: 'return.create',
              payload: {
                id: testId('cn_closed'),
                saleId: testId('s_closed'),
                date: past,
                refundMethod: 'โอน',
                items: [{ productId: testId('p_d10'), name: 'Filter', qty: 1, price: '85.00' }],
              },
            },
          ],
        });
        expect(res.body.data.results[0].status).toBe('applied');
        const ret = (await admin.query(
          `SELECT date, shift_id FROM returns WHERE tenant_id = $1::uuid AND id = '${testId('cn_closed')}'`,
          [TENANT],
        )) as { date: Date; shift_id: string | null }[];
        // Before: measured against the closed shift → pulled up to its opened_at + flagged.
        expect(ret[0].date.toISOString()).toBe(past);
        expect(ret[0].shift_id).toBeNull();
        expect(await flags()).toHaveLength(0);
      });

      it('RC period ≠ the stored date\'s month (tenant tz) → one date_flag; a matching period → none', async () => {
        await seedOpenShift(admin, TENANT, fixture.posDeviceId);
        const now = new Date();
        const period = currentPeriod(now);
        const withNo = (id: string, receiptNo: string) => {
          const op = saleOp(id, now.toISOString());
          return { ...op, payload: { ...op.payload, receiptNo } };
        };
        const res = await push({
          outboxRemaining: 0,
          ops: [withNo('s_per_ok', `RC01-${period}-0101`), withNo('s_per_bad', 'RC01-2500-01-0102')],
        });
        expect((res.body.data.results as { status: string }[]).map((r) => r.status)).toEqual(['applied', 'applied']);

        const f = await flags();
        expect(f).toHaveLength(1);
        expect(f[0]).toMatchObject({
          ref_id: testId('s_per_bad'),
          details: {
            docNo: 'RC01-2500-01-0102',
            docPeriod: '2500-01',
            datePeriod: period,
            originalDate: now.toISOString(),
            clampedDate: now.toISOString(),
          },
        });
      });

      it('shift.open 10 min ahead → opened_at = now() + date_flag; replay adds no second flag', async () => {
        const future = new Date(Date.now() + 10 * 60 * 1000).toISOString();
        const op = {
          opId: testId('op_sh_future'),
          idempotencyKey: 'k_sh_future',
          type: 'shift.open',
          payload: { id: testId('sh_future'), startingCash: '100.00', openedAt: future },
        };
        expect((await push({ outboxRemaining: 0, ops: [op] })).body.data.results[0].status).toBe('applied');
        expect((await push({ outboxRemaining: 0, ops: [op] })).body.data.results[0].status).toBe('applied');

        const sh = (await admin.query(
          `SELECT opened_at FROM shifts WHERE tenant_id = $1::uuid AND id = '${testId('sh_future')}'`,
          [TENANT],
        )) as { opened_at: Date }[];
        expect(sh[0].opened_at.getTime()).toBeLessThan(new Date(future).getTime() - 60 * 1000);
        const f = await flags();
        expect(f).toHaveLength(1);
        expect(f[0]).toMatchObject({
          ref_id: testId('sh_future'),
          details: { type: 'shift.open', originalDate: future, openedAt: null },
        });
      });
    });

    it('Issue #190: rejects sale or return with RECEIPT_NO_CONFLICT when document number collides', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
        id: testId('sh_190'),
        startingCash: 500,
      });
      await seedProduct(admin, TENANT, {
        id: testId('p190'),
        partNo: 'HN-190',
        name: 'Spark Plug 190',
        price: 100,
        cost: 50,
        stock: 50,
      });

      const receiptNo = 'RC01-2569-09-0070';
      const salePayload1 = {
        id: testId('s_190_1'),
        receiptNo,
        date: new Date().toISOString(),
        subtotal: '100.00',
        discount: '0.00',
        total: '100.00',
        paymentMethod: 'เงินสด',
        items: [{ lineNo: 1, productId: testId('p190'), name: 'Spark Plug 190', qty: 1, price: '100.00' }],
      };

      // 1. First sale applies successfully
      const res1 = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: testId('op_190_1'),
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
            opId: testId('op_190_1_replay'),
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
        id: testId('s_190_colliding'),
        receiptNo,
        date: new Date().toISOString(),
        subtotal: '200.00',
        discount: '0.00',
        total: '200.00',
        paymentMethod: 'เงินสด',
        items: [{ lineNo: 1, productId: testId('p190'), name: 'Spark Plug 190', qty: 2, price: '100.00' }],
      };

      const resConflict = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: testId('op_190_colliding'),
            idempotencyKey: 'k_190_colliding',
            type: 'sale.create',
            payload: salePayloadColliding,
          },
        ],
      });

      expect(resConflict.status).toBe(200);
      expect(resConflict.body.data.results[0]).toEqual({
        opId: testId('op_190_colliding'),
        status: 'rejected',
        code: 'RECEIPT_NO_CONFLICT',
        message: 'เลขที่ใบเสร็จซ้ำ กรุณาทำรายการใหม่',
        details: {
          docNumber: receiptNo,
        },
      });

      // Invariant: stock was only deducted by sale 1 (50 - 1 = 49), not by the rejected sale
      const productRow = await admin.query(
        `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = '${testId('p190')}'`,
        [TENANT],
      );
      expect(productRow[0].stock).toBe(49);

      // Invariant: no row exists for s_190_colliding
      const saleRows = await admin.query(
        `SELECT id FROM sales WHERE tenant_id = $1::uuid AND id = '${testId('s_190_colliding')}'`,
        [TENANT],
      );
      expect(saleRows).toHaveLength(0);

      // 4. Batch continuation: a batch containing valid, colliding, valid ops
      const resBatch = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: testId('op_batch_valid_1'),
            idempotencyKey: 'k_b_1',
            type: 'sale.create',
            payload: {
              id: testId('s_batch_1'),
              receiptNo: 'RC01-2569-09-0071',
              date: new Date().toISOString(),
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เงินสด',
              items: [{ lineNo: 1, productId: testId('p190'), name: 'Spark Plug 190', qty: 1, price: '100.00' }],
            },
          },
          {
            opId: testId('op_batch_conflict'),
            idempotencyKey: 'k_b_2',
            type: 'sale.create',
            payload: {
              id: testId('s_batch_2'),
              receiptNo, // colliding with s_190_1
              date: new Date().toISOString(),
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เงินสด',
              items: [{ lineNo: 1, productId: testId('p190'), name: 'Spark Plug 190', qty: 1, price: '100.00' }],
            },
          },
          {
            opId: testId('op_batch_valid_2'),
            idempotencyKey: 'k_b_3',
            type: 'sale.create',
            payload: {
              id: testId('s_batch_3'),
              receiptNo: 'RC01-2569-09-0072',
              date: new Date().toISOString(),
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เงินสด',
              items: [{ lineNo: 1, productId: testId('p190'), name: 'Spark Plug 190', qty: 1, price: '100.00' }],
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
        id: testId('r_190_1'),
        cnNo,
        saleId: testId('s_190_1'),
        refundMethod: 'เงินสด',
        reason: 'เปลี่ยนใจ',
        items: [{ lineNo: 1, productId: testId('p190'), name: 'Spark Plug 190', qty: 1, price: '100.00' }],
      };

      const resReturn1 = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: testId('op_ret_1'),
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
        id: testId('r_190_colliding'),
        cnNo,
        saleId: testId('s_batch_1'),
        refundMethod: 'เงินสด',
        reason: 'ขอคืน',
        items: [{ lineNo: 1, productId: testId('p190'), name: 'Spark Plug 190', qty: 1, price: '100.00' }],
      };

      const resReturnConflict = await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: testId('op_ret_colliding'),
            idempotencyKey: 'k_ret_colliding',
            type: 'return.create',
            payload: returnPayloadColliding,
          },
        ],
      });

      expect(resReturnConflict.status).toBe(200);
      expect(resReturnConflict.body.data.results[0]).toEqual({
        opId: testId('op_ret_colliding'),
        status: 'rejected',
        code: 'RECEIPT_NO_CONFLICT',
        message: 'เลขที่ใบเสร็จซ้ำ กรุณาทำรายการใหม่',
        details: {
          docNumber: cnNo,
        },
      });
    });
  });

  describe('#27 follow-up (owner 2026-10-03, 08 §6.1): an offline bill sold from a quote cart', () => {
    const quoteSaleOp = (id: string, quoteId: string, date = new Date().toISOString()) => ({
      opId: testId(`op_${id}`),
      idempotencyKey: `k_${id}`,
      type: 'sale.create',
      payload: {
        id: testId(id),
        date,
        subtotal: '85.00',
        discount: '0.00',
        total: '85.00',
        paymentMethod: 'เงินสด',
        quoteId,
        items: [{ lineNo: 1, productId: testId('p_q27'), name: 'Filter', qty: 1, price: '85.00' }],
      },
    });
    const seedQuote = (
      id: string,
      over: { status?: string; convertedSaleId?: string; expired?: boolean; validFor?: string } = {},
    ) =>
      admin.query(
        `INSERT INTO quotes (tenant_id, id, quote_no, status, valid_until, converted_at, converted_sale_id, subtotal, discount, total)
         VALUES ($1::uuid, $2, $3, $4, now() + ($5::text)::interval, $6, $7, 85, 0, 85)`,
        [
          TENANT,
          id,
          `QT-${id}`,
          over.status ?? 'open',
          over.validFor ?? (over.expired ? '-1 day' : '30 days'),
          over.status === 'converted' ? new Date('2026-10-01T03:00:00Z') : null,
          over.convertedSaleId ?? null,
        ],
      );
    const quoteRow = async (id: string) =>
      (
        (await admin.query(
          `SELECT status, converted_at, converted_sale_id FROM quotes WHERE tenant_id = $1::uuid AND id = $2`,
          [TENANT, id],
        )) as { status: string; converted_at: Date | null; converted_sale_id: string | null }[]
      )[0];
    const conflicts = async () =>
      (await admin.query(
        `SELECT ref_id, details FROM owner_review_items WHERE tenant_id = $1::uuid AND kind = 'quote_conflict' ORDER BY ref_id`,
        [TENANT],
      )) as { ref_id: string; details: Record<string, unknown> }[];
    const saleExists = async (id: string) =>
      ((await admin.query(`SELECT 1 FROM sales WHERE tenant_id = $1::uuid AND id = $2`, [TENANT, id])) as unknown[])
        .length === 1;

    beforeEach(async () => {
      await seedProduct(admin, TENANT, { id: testId('p_q27'), partNo: 'P-Q27', name: 'Filter', price: 85, cost: 50, stock: 10 });
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
    });

    it('a quote still open at sync is converted into the bill in the same transaction, with no review item', async () => {
      await seedQuote(testId('q_open'));
      const res = await push({ outboxRemaining: 0, ops: [quoteSaleOp('s_q_open', testId('q_open'))] });
      expect(res.body.data.results[0].status).toBe('applied');
      const q = await quoteRow(testId('q_open'));
      expect(q.status).toBe('converted');
      expect(q.converted_sale_id).toBe(testId('s_q_open'));
      expect(q.converted_at).not.toBeNull();
      expect(await conflicts()).toEqual([]);

      // A re-push replays the bill and changes nothing more.
      expect((await push({ outboxRemaining: 0, ops: [quoteSaleOp('s_q_open', testId('q_open'))] })).body.data.results[0].status)
        .toBe('applied');
      expect(await conflicts()).toEqual([]);
    });

    it('a quote already converted into another bill: the bill is accepted, the quote untouched, one review item', async () => {
      await seedQuote(testId('q_conv'), { status: 'converted', convertedSaleId: testId('s_other') });
      const before = await quoteRow(testId('q_conv'));
      const res = await push({ outboxRemaining: 0, ops: [quoteSaleOp('s_q_conv', testId('q_conv'))] });
      expect(res.body.data.results[0].status).toBe('applied');
      expect(await saleExists(testId('s_q_conv'))).toBe(true);
      expect(await quoteRow(testId('q_conv'))).toEqual(before);
      const items = await conflicts();
      expect(items).toHaveLength(1);
      expect(items[0].ref_id).toBe(testId('s_q_conv'));
      expect(items[0].details).toMatchObject({
        opId: testId('op_s_q_conv'),
        saleId: testId('s_q_conv'),
        quoteId: testId('q_conv'),
        reason: 'already_converted',
        convertedSaleId: testId('s_other'),
      });
      expect(items[0].details.receiptNo).toEqual(res.body.data.results[0].response.receiptNo);

      // A re-push (client-id replay after the key is gone) raises no second item.
      await admin.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid AND key = 'k_s_q_conv'`, [TENANT]);
      await clearTenantCache(cache, TENANT);
      expect((await push({ outboxRemaining: 0, ops: [quoteSaleOp('s_q_conv', testId('q_conv'))] })).body.data.results[0].status)
        .toBe('applied');
      expect(await conflicts()).toHaveLength(1);
    });

    it('an expired quote: the bill is accepted, the quote untouched, one review item', async () => {
      await seedQuote(testId('q_exp'), { expired: true });
      const before = await quoteRow(testId('q_exp'));
      const res = await push({ outboxRemaining: 0, ops: [quoteSaleOp('s_q_exp', testId('q_exp'))] });
      expect(res.body.data.results[0].status).toBe('applied');
      expect(await saleExists(testId('s_q_exp'))).toBe(true);
      expect(await quoteRow(testId('q_exp'))).toEqual(before);
      expect(before.status).toBe('open');
      const items = await conflicts();
      expect(items).toHaveLength(1);
      expect(items[0].details).toMatchObject({ saleId: testId('s_q_exp'), quoteId: testId('q_exp'), reason: 'expired' });
      expect(typeof items[0].details.validUntil).toBe('string');
    });

    // Owner 2026-10-03 (#575): expiry is judged at the bill's own stored date, not at
    // the sync. The drawer opened 3 h ago, so a bill dated 2 h ago is stored unclamped.
    const twoHoursAgo = () => new Date(Date.now() - 2 * 3600 * 1000).toISOString();
    const openDrawerThreeHoursAgo = () =>
      admin.query(
        `UPDATE shifts SET opened_at = now() - interval '3 hours' WHERE tenant_id = $1::uuid AND device_id = $2 AND is_active`,
        [TENANT, fixture.posDeviceId],
      );

    it('valid when the bill was sold, expired by the sync: converted normally, no review item', async () => {
      await openDrawerThreeHoursAgo();
      await seedQuote(testId('q_lapsed'), { validFor: '-1 hour' });
      const soldAt = twoHoursAgo();
      const res = await push({ outboxRemaining: 0, ops: [quoteSaleOp('s_q_lapsed', testId('q_lapsed'), soldAt)] });
      expect(res.body.data.results[0].status).toBe('applied');
      const stored = (await admin.query(
        `SELECT date FROM sales WHERE tenant_id = $1::uuid AND id = '${testId('s_q_lapsed')}'`,
        [TENANT],
      )) as { date: Date }[];
      expect(stored[0].date.toISOString()).toBe(soldAt);
      const q = await quoteRow(testId('q_lapsed'));
      expect(q.status).toBe('converted');
      expect(q.converted_sale_id).toBe(testId('s_q_lapsed'));
      expect(await conflicts()).toEqual([]);
    });

    it('expired before the bill was sold: the bill is accepted, the quote untouched, one review item', async () => {
      await openDrawerThreeHoursAgo();
      await seedQuote(testId('q_late'), { validFor: '-150 minutes' });
      const before = await quoteRow(testId('q_late'));
      const soldAt = twoHoursAgo();
      const res = await push({ outboxRemaining: 0, ops: [quoteSaleOp('s_q_late', testId('q_late'), soldAt)] });
      expect(res.body.data.results[0].status).toBe('applied');
      const stored = (await admin.query(
        `SELECT date FROM sales WHERE tenant_id = $1::uuid AND id = '${testId('s_q_late')}'`,
        [TENANT],
      )) as { date: Date }[];
      expect(stored[0].date.toISOString()).toBe(soldAt);
      expect(await quoteRow(testId('q_late'))).toEqual(before);
      expect((await conflicts()).map((i) => [i.ref_id, i.details.reason])).toEqual([[testId('s_q_late'), 'expired']]);
    });

    it('a quote that no longer exists: the bill is accepted with one review item (not_found)', async () => {
      const res = await push({ outboxRemaining: 0, ops: [quoteSaleOp('s_q_gone', testId('q_gone'))] });
      expect(res.body.data.results[0].status).toBe('applied');
      expect(await saleExists(testId('s_q_gone'))).toBe(true);
      expect((await conflicts()).map((i) => i.details.reason)).toEqual(['not_found']);
    });

    it('a refused bill (no stock) rolls back: the open quote stays open, no review item', async () => {
      await seedQuote(testId('q_short'));
      await admin.query(`UPDATE products SET stock = 0 WHERE tenant_id = $1::uuid AND id = '${testId('p_q27')}'`, [TENANT]);
      const res = await push({ outboxRemaining: 0, ops: [quoteSaleOp('s_q_short', testId('q_short'))] });
      expect(res.body.data.results[0].status).not.toBe('applied');
      expect((await quoteRow(testId('q_short'))).status).toBe('open');
      expect(await conflicts()).toEqual([]);
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
          opId: testId('op_disc_1'),
          type: 'customer.create',
          note: 'Customer duplicate',
        },
        null,
      );
      expect(res.status).toBe(401);
    });

    it('rejects request with empty or missing note (400)', async () => {
      const res = await discard({
        opId: testId('op_disc_1'),
        type: 'customer.create',
        note: '   ',
      });
      expect(res.status).toBe(400);
      expect(res.body.error.message).toContain('note');
    });

    it('returns serverHasRow: false when target row does not exist and writes audit log', async () => {
      const opId = testId('op_disc_non_existent');
      const clientId = testId('c_never_synced');
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
      const clientId = testId('c_exists_1');
      await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: testId('op_c_exists'),
            idempotencyKey: 'k_c_exists',
            type: 'customer.create',
            payload: { id: clientId, name: 'Existing Customer' },
          },
        ],
      });

      const opId = testId('op_disc_existing');
      const res = await discard({
        opId,
        type: 'customer.create',
        clientId,
        note: 'Already on server',
      });

      expect(res.status).toBe(200);
      expect(res.body.data).toEqual({ serverHasRow: true });
    });

    it('sale.void_offline: serverHasRow follows the bill being voided (payload.saleId) (#488)', async () => {
      await seedOpenShift(admin, TENANT, fixture.posDeviceId);
      await seedProduct(admin, TENANT, {
        id: testId('p_disc_v'),
        partNo: 'DV-1',
        name: 'Pad',
        price: 100,
        cost: 50,
        stock: 10,
      });
      await push({
        outboxRemaining: 0,
        ops: [
          {
            opId: testId('op_sale_disc_v'),
            idempotencyKey: 'k_sale_disc_v',
            type: 'sale.create',
            payload: {
              id: testId('s_disc_v'),
              receiptNo: 'RC01-2569-09-0077',
              subtotal: '100.00',
              discount: '0.00',
              total: '100.00',
              paymentMethod: 'เงินสด',
              items: [{ lineNo: 1, productId: testId('p_disc_v'), name: 'Pad', qty: 1, price: '100.00' }],
            },
          },
        ],
      });
      const voidOp = {
        opId: testId('op_void_disc_v'),
        type: 'sale.void_offline',
        payload: { saleId: testId('s_disc_v'), reason: 'ลูกค้ายกเลิก' },
        note: 'void never sent',
      };

      // Bill on the server, not voided: the void did not land.
      const before = await discard(voidOp, POS_DEVICE_TOKEN, 'k_disc_v_1');
      expect(before.status).toBe(200);
      expect(before.body.data).toEqual({ serverHasRow: false });

      await push({
        outboxRemaining: 0,
        ops: [{ ...voidOp, idempotencyKey: 'k_void_disc_v', note: undefined }],
      });

      // The void landed: the discard must not un-void the till's copy.
      const after = await discard(voidOp, POS_DEVICE_TOKEN, 'k_disc_v_2');
      expect(after.status).toBe(200);
      expect(after.body.data).toEqual({ serverHasRow: true });
      const audit = await admin.query(
        `SELECT after FROM audit_log WHERE tenant_id = $1::uuid AND action = 'sync.op.discarded' AND entity_id = '${testId('op_void_disc_v')}' ORDER BY id`,
        [TENANT],
      );
      expect(audit.map((r: { after: { clientId: string } }) => r.after.clientId)).toEqual([
        testId('s_disc_v'),
        testId('s_disc_v'),
      ]);
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
          opId: testId('op_jwt_disc'),
          type: 'sale.create',
          clientId: testId('s_missing'),
          note: 'Owner discarded from backoffice',
        });

      expect(res.status).toBe(200);
      expect(res.body.data).toEqual({ serverHasRow: false });
    });
  });
});

