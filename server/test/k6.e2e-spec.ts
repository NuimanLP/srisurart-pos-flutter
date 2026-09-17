import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import type { Redis } from 'ioredis';
import {
  accessToken,
  clearTenantCache,
  createTestApp,
  resetTenant,
} from './support/fixture.js';
import { setupLoadTest } from './k6/setup.js';
import { verifyIntegrity } from './k6/verify-integrity.js';

const TENANT_ID = '00000000-0000-4000-8000-000000000001';

describe('k6 Load Test Harness & Products Read Path (p11.1 e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: Redis;
  let envData: Awaited<ReturnType<typeof setupLoadTest>>;

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());

    const posToken = accessToken({
      tenantId: TENANT_ID,
      userId: '00000000-0000-4000-8000-000000000010',
      role: 'owner',
      deviceId: 'pos-loadtest',
      deviceRole: 'pos',
    });
    const boToken = accessToken({
      tenantId: TENANT_ID,
      userId: '00000000-0000-4000-8000-000000000020',
      role: 'owner',
      deviceId: 'bo-loadtest',
      deviceRole: 'backoffice',
    });

    envData = await setupLoadTest({
      p12Stock: 50,
      tokens: { posToken, boToken },
    });
  });

  afterAll(async () => {
    await clearTenantCache(cache, TENANT_ID);
    await resetTenant(admin, TENANT_ID, { cache });
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT_ID]);
    await app.close();
  });

  describe('Scenario 1 Read Path & Redis Caching', () => {
    it('returns 200 with X-Cache: MISS on cold read, then X-Cache: HIT on subsequent read', async () => {
      // 1. First read (Cold cache)
      const res1 = await request(app.getHttpServer())
        .get('/api/v1/products?page=1&limit=20')
        .set('Authorization', `Bearer ${envData.boToken}`);

      expect(res1.status).toBe(200);
      expect(res1.headers['x-cache']).toBe('MISS');
      expect(res1.body.status).toBe('success');
      expect(Array.isArray(res1.body.data)).toBe(true);
      expect(res1.body.data.length).toBeGreaterThan(0);
      expect(res1.body.meta).toBeDefined();
      expect(res1.body.meta.total).toBe(51);

      // 2. Second read (Cached in Redis)
      const res2 = await request(app.getHttpServer())
        .get('/api/v1/products?page=1&limit=20')
        .set('Authorization', `Bearer ${envData.boToken}`);

      expect(res2.status).toBe(200);
      expect(res2.headers['x-cache']).toBe('HIT');
      expect(res2.body.data).toEqual(res1.body.data);
      expect(res2.body.meta).toEqual(res1.body.meta);
    });

    it('filters products by search and category correctly', async () => {
      const res = await request(app.getHttpServer())
        .get('/api/v1/products?search=Special&category=เบรก')
        .set('Authorization', `Bearer ${envData.boToken}`);

      expect(res.status).toBe(200);
      expect(res.body.data.length).toBe(1);
      expect(res.body.data[0].id).toBe('p12');
      expect(res.body.data[0].name).toBe('Brake Pad Special P12');
    });

    it('returns 401 when unauthenticated', async () => {
      const res = await request(app.getHttpServer()).get('/api/v1/products');
      expect(res.status).toBe(401);
    });
  });

  describe('Scenario 2 & 3 Write Contention & Idempotency Harness Verification', () => {
    it('successfully processes sale on p12 with valid posToken and idempotency key', async () => {
      const saleId = 'sale-k6-e2e-1';
      const idemKey = 'idem-k6-e2e-1';

      const res = await request(app.getHttpServer())
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${envData.posToken}`)
        .set('Idempotency-Key', idemKey)
        .send({
          id: saleId,
          subtotal: 100.0,
          discount: 0.0,
          total: 100.0,
          paymentMethod: 'เงินสด',
          items: [
            {
              productId: 'p12',
              name: 'Brake Pad Special P12',
              qty: 1,
              price: 100.0,
            },
          ],
        });

      expect(res.status).toBe(201);
      expect(res.body.status).toBe('success');
      expect(res.body.data.receiptNo).toBeDefined();
      const receiptNo = res.body.data.receiptNo;

      // Replay with identical key -> returns same receipt number (Scenario 3 invariant)
      const replayRes = await request(app.getHttpServer())
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${envData.posToken}`)
        .set('Idempotency-Key', idemKey)
        .send({
          id: saleId,
          subtotal: 100.0,
          discount: 0.0,
          total: 100.0,
          paymentMethod: 'เงินสด',
          items: [
            {
              productId: 'p12',
              name: 'Brake Pad Special P12',
              qty: 1,
              price: 100.0,
            },
          ],
        });

      expect([200, 201]).toContain(replayRes.status);
      expect(replayRes.body.data.receiptNo).toBe(receiptNo);
    });

    it('verifies SQL data integrity assertions pass with 1 sold unit', async () => {
      const verification = await verifyIntegrity();
      expect(verification.allPassed).toBe(true);
      expect(verification.soldQty).toBe(1);
      expect(verification.currentStock).toBe(49);
      expect(verification.initialStock).toBe(50);
    });
  });
});
