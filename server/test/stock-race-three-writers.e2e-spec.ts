import type { INestApplication } from '@nestjs/common';
import type { Redis } from 'ioredis';
import request, { type Response } from 'supertest';
import type { DataSource } from 'typeorm';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedOpenShift,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';

// Issue #295: dod.4 test.stock-race-three-writers
// Verifies stock consistency under high concurrent write contention across 3 distinct writer paths:
// 1. POS sales (POST /sales) decrementing stock and writing sale movements
// 2. Purchasing receipts (POST /purchase-orders/:id/receive) incrementing stock and writing purchase movements
// 3. Stock adjustments (POST /products/:id/adjust-stock) applying mixed positive/negative deltas
const TENANT = '29529529-2950-4295-8295-295295295295';

const hotProduct = {
  id: 'hot-part-295',
  partNo: 'HOT-PART-295',
  name: 'Hot Racing Part',
  price: 100,
  cost: 50,
  stock: 100_000,
};

describe('dod.4 test.stock-race-three-writers (Issue #295)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: Redis;
  let fixture: TenantFixture;
  let posToken: string;
  let backofficeToken: string;
  const poIds: string[] = [];

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());

    fixture = await resetTenant(admin, TENANT, { cache });

    // Promote fixture user to role 'owner'
    await admin.query(
      `UPDATE users SET role = 'owner' WHERE tenant_id = $1::uuid AND id = $2::uuid`,
      [TENANT, fixture.userId],
    );

    // Set plan to 'loadtest' per ADR-0006 for unlimited quota during high-write concurrency
    await admin.query(
      `UPDATE tenants SET plan = 'loadtest' WHERE id = $1::uuid`,
      [TENANT],
    );

    // Seed hot product with large starting stock (100,000)
    await seedProduct(admin, TENANT, hotProduct);

    // Mint tokens
    posToken = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'owner',
      deviceId: fixture.posDeviceId,
      deviceRole: 'pos',
    });

    await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
      userId: fixture.userId,
    });

    backofficeToken = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'owner',
      deviceId: fixture.backofficeDeviceId,
      deviceRole: 'backoffice',
    });

    // Pre-race setup: create 200 distinct open POs for the hot product
    const BATCH_SIZE = 10;
    for (let i = 0; i < 200; i += BATCH_SIZE) {
      const batch = Array.from(
        { length: Math.min(BATCH_SIZE, 200 - i) },
        (_, offset) => {
          const idx = i + offset;
          return request(app.getHttpServer())
            .post('/api/v1/purchase-orders')
            .set('Authorization', `Bearer ${backofficeToken}`)
            .set('Idempotency-Key', `po-race-pre-295-${idx}-${Date.now()}`)
            .send({
              supplier: 'Race Supplier 295',
              items: [
                {
                  partNo: hotProduct.partNo,
                  name: hotProduct.name,
                  qty: 2,
                  cost: '50.00',
                },
              ],
            });
        },
      );

      const responses = await Promise.all(batch);
      for (const res of responses) {
        expect(res.status).toBe(201);
        poIds.push(res.body.data.id as string);
      }
    }
    expect(poIds).toHaveLength(200);
  }, 180_000);

  afterAll(async () => {
    if (admin) {
      await resetTenant(admin, TENANT, { cache });
      await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    }
    if (app) {
      await app.close();
    }
  });

  it('handles 600 concurrent writes across three writer paths with zero errors and preserved ledger invariants', async () => {
    const createSale = (i: number) =>
      request(app.getHttpServer())
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${posToken}`)
        .set('Idempotency-Key', `idem-sale-295-${i}-${Date.now()}`)
        .send({
          id: `s-race-295-${i}-${Date.now()}`,
          subtotal: '100.00',
          discount: '0.00',
          total: '100.00',
          paymentMethod: 'เงินสด',
          items: [
            {
              lineNo: 1,
              productId: hotProduct.id,
              partNo: hotProduct.partNo,
              name: hotProduct.name,
              qty: 1,
              price: '100.00',
            },
          ],
        });

    const receivePo = (poId: string, i: number) =>
      request(app.getHttpServer())
        .post(`/api/v1/purchase-orders/${poId}/receive`)
        .set('Authorization', `Bearer ${backofficeToken}`)
        .set('Idempotency-Key', `idem-po-rcv-295-${i}-${Date.now()}`)
        .send();

    const adjustStock = (i: number) => {
      const isAdjustmentIn = i < 100;
      const delta = isAdjustmentIn ? 3 : -2;
      const type = isAdjustmentIn ? 'adjustment-in' : 'adjustment-out';
      return request(app.getHttpServer())
        .post(`/api/v1/products/${hotProduct.id}/adjust-stock`)
        .set('Authorization', `Bearer ${backofficeToken}`)
        .set('Idempotency-Key', `idem-adj-295-${i}-${Date.now()}`)
        .send({
          delta,
          type,
          note: `race adjustment ${i}`,
        });
    };

    // Interleave all 600 requests to maximize concurrency across the three paths
    const all600Requests: Promise<Response>[] = [];
    for (let i = 0; i < 200; i++) {
      all600Requests.push(createSale(i));
      all600Requests.push(receivePo(poIds[i], i));
      all600Requests.push(adjustStock(i));
    }

    const settled = await Promise.allSettled(all600Requests);

    // 1. All 600 promises fulfilled
    expect(settled).toHaveLength(600);
    const rejected = settled.filter(
      (r): r is PromiseRejectedResult => r.status === 'rejected',
    );
    expect(rejected).toHaveLength(0);

    // 2. Every response is 2xx (zero 4xx, zero 5xx, zero 429)
    const responses = settled.map(
      (r) => (r as PromiseFulfilledResult<Response>).value,
    );
    const non2xx = responses.filter(
      (res) => res.status < 200 || res.status >= 300,
    );
    expect(
      non2xx.map((res) => ({ status: res.status, body: res.body })),
    ).toEqual([]);

    // 3. Final stock calculation:
    // expectedStock = initialStock + (200 * 2) + (100 * 3 + 100 * -2) - (200 * 1);
    const initialStock = 100_000;
    const expectedStock =
      initialStock + 200 * 2 + (100 * 3 + 100 * -2) - 200 * 1;

    const productRows = await admin.query(
      `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, hotProduct.id],
    );
    expect(productRows).toHaveLength(1);
    const finalStock = Number(productRows[0].stock);
    expect(finalStock).toBe(expectedStock);

    // 4. Ledger cross-check:
    // SELECT COALESCE(SUM(delta), 0)::int AS total_delta FROM movements WHERE tenant_id = $1::uuid AND product_id = $2;
    // Assert (finalStock - initialStock) === totalDelta
    const movementRows = await admin.query(
      `SELECT COALESCE(SUM(delta), 0)::int AS total_delta FROM movements WHERE tenant_id = $1::uuid AND product_id = $2`,
      [TENANT, hotProduct.id],
    );
    const totalDelta = Number(movementRows[0].total_delta);
    expect(finalStock - initialStock).toBe(totalDelta);
  }, 180_000);
});
