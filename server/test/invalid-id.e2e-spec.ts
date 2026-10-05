import type { INestApplication } from '@nestjs/common';
import { createHash } from 'node:crypto';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import {
  accessToken,
  createTestApp,
  resetTenant,
  type TenantFixture,
} from './support/fixture.js';
import { testId } from './support/test-ids.js';

// #616: every entity id is a lowercase UUID. A malformed or uppercase one is refused as
// `400 INVALID_ID` before any SQL — never a 22P02 → 500 — on a path param, a body field
// and a query param; and on `/sync/push` it rejects just that op instead of reading as
// `retry` (which would bring it back forever).
const TENANT = '61661661-6166-4166-8166-616616616616';
const POS_DEVICE_TOKEN = 'pos-device-token-616';

describe('malformed ids are 400 INVALID_ID (#616, e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;
  let token: string;

  const api = () => request(app.getHttpServer());
  const expectInvalidId = (
    res: request.Response,
    field: string,
  ): void => {
    expect(res.status).toBe(400);
    expect(res.body.error).toMatchObject({ code: 'INVALID_ID', details: { field } });
  };

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { posDeviceNo: 6, cache });
    await admin.query(
      `UPDATE devices SET token_hash = $1 WHERE tenant_id = $2::uuid AND id = $3`,
      [createHash('sha256').update(POS_DEVICE_TOKEN).digest('hex'), TENANT, fixture.posDeviceId],
    );
    token = accessToken({
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

  describe('path param', () => {
    it.each([
      ['/sales/s_off_001'],
      [`/sales/${testId('s1').toUpperCase()}`],
      ['/customers/c1'],
      ['/quotes/not-a-uuid'],
    ])('GET %s', async (path) => {
      const res = await api()
        .get(`/api/v1${path}`)
        .set('Authorization', `Bearer ${token}`);
      expectInvalidId(res, 'id');
    });
  });

  describe('body field', () => {
    it('POST /sales with a non-UUID line productId', async () => {
      const res = await api()
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${token}`)
        .set('Idempotency-Key', `k-${testId('body-1')}`)
        .send({
          id: testId('s-body-1'),
          subtotal: '85.00',
          discount: '0.00',
          total: '85.00',
          paymentMethod: 'เงินสด',
          items: [{ lineNo: 1, productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' }],
        });
      expectInvalidId(res, 'items[0].productId');
    });

    it('POST /returns with a non-UUID saleId', async () => {
      const res = await api()
        .post('/api/v1/returns')
        .set('Authorization', `Bearer ${token}`)
        .set('Idempotency-Key', `k-${testId('body-2')}`)
        .send({
          saleId: 's_off_001',
          refundMethod: 'เงินสด',
          items: [{ productId: testId('p1'), name: 'Oil Filter', qty: 1, price: '85.00' }],
        });
      expectInvalidId(res, 'saleId');
    });
  });

  describe('query param', () => {
    it('GET /products?afterId=', async () => {
      const res = await api()
        .get('/api/v1/products')
        .query({ updatedSince: '2026-01-01T00:00:00.000Z', afterId: 'p1' })
        .set('Authorization', `Bearer ${token}`);
      expectInvalidId(res, 'afterId');
    });

    it('GET /reports/closing?shiftId=', async () => {
      const res = await api()
        .get('/api/v1/reports/closing')
        .query({ shiftId: 'sh_1' })
        .set('Authorization', `Bearer ${token}`);
      expectInvalidId(res, 'shiftId');
    });
  });

  describe('/sync/push', () => {
    const push = (ops: unknown[]) =>
      api()
        .post('/api/v1/sync/push')
        .set('X-Device-Token', POS_DEVICE_TOKEN)
        .send({ outboxRemaining: 0, ops });

    it('rejects just the op with a bad payload id — not retry — and goes on to the next', async () => {
      const res = await push([
        {
          opId: testId('op-bad-1'),
          idempotencyKey: `k-${testId('op-bad-1')}`,
          type: 'sale.void_offline',
          payload: { saleId: 's_off_001', reason: 'ขอยกเลิก' },
        },
        {
          opId: testId('op-good-1'),
          idempotencyKey: `k-${testId('op-good-1')}`,
          type: 'customer.create',
          payload: { id: testId('c-616'), name: 'ลูกค้า 616' },
        },
      ]);
      expect(res.status).toBe(200);
      expect(res.body.data.results[0]).toMatchObject({
        opId: testId('op-bad-1'),
        status: 'rejected',
        code: 'INVALID_ID',
        details: { field: 'payload.saleId' },
      });
      expect(res.body.data.results[1]).toMatchObject({
        opId: testId('op-good-1'),
        status: 'applied',
      });
    });

    it('refuses the whole envelope when an opId itself is malformed', async () => {
      const res = await push([
        {
          opId: 'op_1',
          idempotencyKey: 'k_1',
          type: 'customer.create',
          payload: { id: testId('c-616-2'), name: 'x' },
        },
      ]);
      expectInvalidId(res, 'ops[0].opId');
    });
  });
});
