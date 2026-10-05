import type { INestApplication } from '@nestjs/common';
import { createHash, randomUUID } from 'node:crypto';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import { signJwt } from '../src/common/jwt.js';
import { APP_CONFIG, type AppConfig } from '../src/config/config.js';
import { platformAdminCacheKey } from '../src/platform/platform-auth.guard.js';
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

  // One route per group the cases above do not reach (#616 AC: "one e2e test per
  // route group"). Each sends a valid token and Idempotency-Key, so only the id is wrong.
  describe('one route per group', () => {
    const send = (
      method: 'get' | 'post' | 'patch' | 'delete',
      path: string,
      body?: object,
    ) => {
      const req = api()
        [method](`/api/v1${path}`)
        .set('Authorization', `Bearer ${token}`)
        .set('Idempotency-Key', `k-${randomUUID()}`);
      return body === undefined ? req : req.send(body);
    };

    it.each([
      ['mechanics', 'get', '/mechanics/m1', undefined, 'id'],
      [
        'credit-payments (body id)',
        'post',
        `/mechanics/${testId('m-616')}/credit-payments`,
        { id: 'cp_1', amount: '10.00', paymentMethod: 'เงินสด' },
        'id',
      ],
      ['shifts open (body id)', 'post', '/shifts/open', { id: 'sh_1', startingCash: '0.00' }, 'id'],
      [
        'shifts drawer entry (body id)',
        'post',
        '/shifts/current/entries',
        { id: 'de_1', type: 'in', amount: '10.00' },
        'id',
      ],
      ['devices', 'post', '/devices/pos1/retire', {}, 'id'],
      ['parked-sales', 'delete', '/parked-sales/pk_1', undefined, 'id'],
      ['review-items', 'post', '/review-items/r1/reviewed', {}, 'id'],
      ['purchase-orders', 'get', '/purchase-orders/po_1', undefined, 'id'],
      ['catalogue suppliers', 'patch', '/suppliers/sup_1', { name: 'x' }, 'id'],
      ['movements ?productId=', 'get', '/movements?productId=p1', undefined, 'productId'],
      [
        '/sync/discards (opId)',
        'post',
        '/sync/discards',
        { opId: 'op_1', type: 'customer.create', note: 'ลบทิ้ง' },
        'opId',
      ],
    ] as const)('%s', async (_, method, path, body, field) => {
      expectInvalidId(await send(method, path, body), field);
    });

    describe('platform device routes', () => {
      let adminId: string;
      let platformToken: string;

      beforeEach(async () => {
        adminId = randomUUID();
        await admin.query(
          `INSERT INTO platform_admins (id, username, password_hash, display_name, is_active)
           VALUES ($1, $2, 'x', 'Admin 616', true)`,
          [adminId, `admin-${adminId.slice(0, 8)}`],
        );
        platformToken = signJwt(
          {
            iss: 'srisurart-pos',
            aud: 'platform',
            sub: adminId,
            username: `admin-${adminId.slice(0, 8)}`,
          },
          app.get<AppConfig>(APP_CONFIG).jwtPlatformSecret,
        );
      });

      afterEach(async () => {
        await cache.del(platformAdminCacheKey(adminId));
        await admin.query(`DELETE FROM audit_log WHERE platform_admin_id = $1`, [adminId]);
        await admin.query(`DELETE FROM platform_admins WHERE id = $1`, [adminId]);
      });

      it.each([['enrol-code'], ['replace']])('POST …/devices/pos1/%s', async (action) => {
        const res = await api()
          .post(`/api/v1/platform/tenants/${TENANT}/devices/pos1/${action}`)
          .set('Authorization', `Bearer ${platformToken}`)
          .send({});
        expectInvalidId(res, 'deviceId');
      });
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
