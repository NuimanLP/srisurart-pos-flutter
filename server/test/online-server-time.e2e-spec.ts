import type { INestApplication } from '@nestjs/common';
import { createHash } from 'node:crypto';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedOpenShift,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';

// #411 — 08 §10: an ONLINE route stamps `sales.date` / `returns.date` /
// `shifts.opened_at` / `drawer_entries.created_at` with the server's `now()` and never
// reads a date from the body; 08 §12: only a `/sync/push` replay marks a bill
// `sold_offline`, so an online bill can never be voided through `sale.void_offline`.
const TENANT = '41141141-1411-4411-8411-411411411411';
const POS_DEVICE_TOKEN = 'pos-device-token-411';
const PAST = '2020-01-01T03:00:00.000Z';

describe('online routes use server time, not the body (#411, e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;
  let posToken: string;

  const post = (path: string, body: unknown) =>
    request(app.getHttpServer())
      .post(`/api/v1${path}`)
      .set('Authorization', `Bearer ${posToken}`)
      .set('Idempotency-Key', `k-${Math.random()}`)
      .send(body as object);

  /** Seconds between a stored timestamp and the database's own `now()`. */
  const skewSeconds = async (sql: string, id: string): Promise<number> => {
    const rows = (await admin.query(
      `SELECT abs(extract(epoch FROM (${sql} - now())))::float AS skew
         FROM ${sql.split('.')[0]} WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, id],
    )) as { skew: number }[];
    expect(rows).toHaveLength(1);
    return rows[0].skew;
  };

  const sale = (id: string, extra: Record<string, unknown> = {}) => ({
    id,
    subtotal: '85.00',
    discount: '0.00',
    total: '85.00',
    paymentMethod: 'เงินสด',
    items: [{ lineNo: 1, productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' }],
    ...extra,
  });

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { posDeviceNo: 7, cache });
    await admin.query(
      `UPDATE devices SET token_hash = $1 WHERE tenant_id = $2::uuid AND id = $3`,
      [createHash('sha256').update(POS_DEVICE_TOKEN).digest('hex'), TENANT, fixture.posDeviceId],
    );
    await seedProduct(admin, TENANT, {
      id: 'p1',
      partNo: 'OF-411',
      name: 'Oil Filter',
      price: 85,
      cost: 50,
      stock: 20,
    });
    posToken = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'owner',
      deviceId: fixture.posDeviceId,
      deviceRole: 'pos',
    });
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it('POST /sales ignores a past `date` and a `soldOffline: true` in the body', async () => {
    await seedOpenShift(admin, TENANT, fixture.posDeviceId);
    const res = await post('/sales', sale('s-411-1', { date: PAST, soldOffline: true }));
    expect(res.status).toBe(201);
    expect(new Date(res.body.data.date as string).getUTCFullYear()).not.toBe(2020);

    expect(await skewSeconds('sales.date', 's-411-1')).toBeLessThan(120);
    const rows = (await admin.query(
      `SELECT sold_offline FROM sales WHERE tenant_id = $1::uuid AND id = 's-411-1'`,
      [TENANT],
    )) as { sold_offline: boolean }[];
    expect(rows[0].sold_offline).toBe(false);

    // …so the device cannot void it through the offline path (08 §12).
    const push = await request(app.getHttpServer())
      .post('/api/v1/sync/push')
      .set('X-Device-Token', POS_DEVICE_TOKEN)
      .send({
        outboxRemaining: 0,
        ops: [
          {
            opId: 'op_void_411',
            idempotencyKey: 'k_void_411',
            type: 'sale.void_offline',
            payload: { saleId: 's-411-1', reason: 'ขอยกเลิก' },
          },
        ],
      });
    expect(push.status).toBe(200);
    expect(push.body.data.results[0]).toMatchObject({
      opId: 'op_void_411',
      status: 'rejected',
      code: 'VOID_NEEDS_ONLINE',
    });
    const after = (await admin.query(
      `SELECT voided FROM sales WHERE tenant_id = $1::uuid AND id = 's-411-1'`,
      [TENANT],
    )) as { voided: boolean }[];
    expect(after[0].voided).toBe(false);
  });

  it('POST /returns ignores a past `date` in the body', async () => {
    await seedOpenShift(admin, TENANT, fixture.posDeviceId);
    expect((await post('/sales', sale('s-411-2'))).status).toBe(201);

    const res = await post('/returns', {
      saleId: 's-411-2',
      refundMethod: 'เงินสด',
      date: PAST,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' }],
    });
    expect(res.status).toBe(201);
    expect(await skewSeconds('returns.date', res.body.data.id as string)).toBeLessThan(120);
  });

  it('POST /shifts/open ignores a past `openedAt` in the body', async () => {
    const res = await post('/shifts/open', {
      id: 'sh-411',
      startingCash: '1000.00',
      openedAt: PAST,
    });
    expect(res.status).toBe(200);
    expect(await skewSeconds('shifts.opened_at', 'sh-411')).toBeLessThan(120);
    const today = (await admin.query(
      `SELECT to_char(now() AT TIME ZONE 'Asia/Bangkok', 'YYYY-MM-DD') AS d`,
    )) as { d: string }[];
    expect(res.body.data.dateStr).toBe(today[0].d);
  });

  it('POST /shifts/current/entries ignores a past `createdAt` in the body', async () => {
    await seedOpenShift(admin, TENANT, fixture.posDeviceId);
    const res = await post('/shifts/current/entries', {
      id: 'de-411',
      type: 'in',
      amount: '50.00',
      note: 'ทอน',
      createdAt: PAST,
    });
    expect(res.status).toBe(201);
    expect(await skewSeconds('drawer_entries.created_at', 'de-411')).toBeLessThan(120);
  });
});
