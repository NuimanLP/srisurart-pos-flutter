import type { INestApplication } from '@nestjs/common';
import type { Response } from 'express';
import request from 'supertest';
import type { Redis } from 'ioredis';
import type { DataSource } from 'typeorm';
import { describe, expect, it, beforeAll, afterAll } from 'vitest';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedOpenShift,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';
import { IdempotencyService } from '../src/idempotency/idempotency.service.js';
import { MetricsService } from '../src/metrics/metrics.service.js';
import { TenantService } from '../src/common/database/tenant.service.js';
import {
  runInTenantScope,
  setRequestTenant,
} from '../src/common/request-context.js';

const TENANT = 'eeeeeeee-6666-4666-8666-eeeeeeeeeeee';

function parseReplayCount(metricsText: string): number {
  const match = metricsText.match(
    /pos_idempotency_replay_total(?:\{[^}]*\})?\s+(\d+)/,
  );
  return match ? Number(match[1]) : 0;
}

describe('metrics (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: Redis;
  let fixture: TenantFixture;
  let posToken: string;

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
    fixture = await resetTenant(admin, TENANT);
    posToken = accessToken({
      tenantId: TENANT,
      role: 'cashier',
      deviceId: fixture.posDeviceId,
      deviceRole: 'pos',
    });
    await seedOpenShift(admin, TENANT, fixture.posDeviceId);
  });

  afterAll(async () => {
    await app.close();
  });

  // The replay counter is only as trustworthy as its wiring. A lost edge — an `@Optional()`
  // re-added on the constructor parameter, `MetricsModule` dropped from the graph — does show
  // up in the delta assertions further down, but as "expected 1, got 0", which reads like a
  // counting bug at the commit hook rather than a missing dependency. This asserts the edge
  // itself in the real production module graph `createTestApp()` boots, so the failure names
  // its own cause.
  it('injects the app-wide MetricsService into IdempotencyService (real module graph)', () => {
    const idempotency = app.get(IdempotencyService);
    const injected = (idempotency as unknown as { metrics?: MetricsService }).metrics;

    expect(injected).toBeInstanceOf(MetricsService);
    // The same singleton the scrape endpoint renders — not a second registry whose counters
    // would never appear in `GET /metrics`.
    expect(injected).toBe(app.get(MetricsService));
  });

  it('GET /metrics → 200 with raw text format, NOT wrapped in JSON envelope', async () => {
    const res = await request(app.getHttpServer()).get('/metrics').expect(200);

    // Must be Prometheus text format, not application/json
    expect(res.headers['content-type']).toMatch(/text\/plain/);
    expect(res.text).not.toContain('{"status":"success"');
    expect(res.body).toEqual({});

    // Process default metrics must be present
    expect(res.text).toMatch(/process_cpu_user_seconds_total/);

    // Pinned metric names must be declared
    expect(res.text).toMatch(/# TYPE http_requests_total counter/);
    expect(res.text).toMatch(/# TYPE http_request_duration_seconds histogram/);
  });

  it('records route pattern and status_code for successful requests', async () => {
    await request(app.getHttpServer())
      .get('/api/v1/products')
      .set('Authorization', `Bearer ${posToken}`)
      .expect(200);

    const metricsRes = await request(app.getHttpServer())
      .get('/metrics')
      .expect(200);

    expect(metricsRes.text).toMatch(
      /http_requests_total\{method="GET",route="\/api\/v1\/products",status_code="200"\}\s+[1-9]\d*/,
    );
  });

  // Synthetic traffic must stay out of the SLI. Compose health-checks each api instance every
  // 15s and Prometheus scrapes all three every 15s, so on a quiet shop day these three paths
  // would be most of `http_requests_total` — and the *API success rate* / *API p95 latency*
  // panels average over every series in it, so a day where every real sale 500s would still
  // read as healthy. `UNMEASURED_PATHS` in metrics.middleware.ts is what keeps them out.
  it('does not measure its own scrape or the health probes', async () => {
    await request(app.getHttpServer()).get('/health/live').expect(200);
    await request(app.getHttpServer()).get('/health/ready');
    await request(app.getHttpServer()).get('/metrics').expect(200);

    const metricsRes = await request(app.getHttpServer())
      .get('/metrics')
      .expect(200);

    const series = metricsRes.text
      .split('\n')
      .filter((line) => line.startsWith('http_requests_total{'));

    expect(series.length).toBeGreaterThan(0); // the filter is looking at something
    expect(series.filter((line) => line.includes('/metrics'))).toEqual([]);
    expect(series.filter((line) => line.includes('/health/'))).toEqual([]);
  });

  it('records guard-rejected requests (401) using route pattern rather than concrete path', async () => {
    // Calling /api/v1/sales/:id without auth token will be rejected by Auth/Tenant guard with 401.
    // The metric must still count this request, and use `/api/v1/sales/:id`, NOT the UUID!
    const testId = 's-nonexistent-uuid-9999';
    await request(app.getHttpServer())
      .get(`/api/v1/sales/${testId}`)
      .expect(401);

    const metricsRes = await request(app.getHttpServer())
      .get('/metrics')
      .expect(200);

    // Must use route pattern `/api/v1/sales/:id`
    expect(metricsRes.text).toMatch(
      /http_requests_total\{method="GET",route="\/api\/v1\/sales\/:id",status_code="401"\}\s+[1-9]\d*/,
    );

    // Must NOT contain the concrete path
    expect(metricsRes.text).not.toContain(testId);
  });

  it('records guard-rejected requests (403) using route pattern rather than concrete path', async () => {
    // Calling /api/v1/devices without an enrolled device token throws 403 DEVICE_ROLE_FORBIDDEN
    const tokenWithoutDevice = accessToken({
      tenantId: TENANT,
      role: 'cashier',
    });
    await request(app.getHttpServer())
      .get('/api/v1/devices')
      .set('Authorization', `Bearer ${tokenWithoutDevice}`)
      .expect(403);

    const metricsRes = await request(app.getHttpServer())
      .get('/metrics')
      .expect(200);

    expect(metricsRes.text).toMatch(
      /http_requests_total\{method="GET",route="\/api\/v1\/devices",status_code="403"\}\s+[1-9]\d*/,
    );
  });

  // #339's third acceptance criterion names 429 alongside 401 and 403, and 429 is the one that
  // proves the hook choice: `TenantRateLimitGuard` refuses before any interceptor runs, so an
  // interceptor-based hook would have counted nothing here. Preloading the window counter in
  // Redis is how test/rate-limit.e2e-spec.ts trips the guard without firing 300 requests.
  it('records guard-rejected requests (429) using the route pattern', async () => {
    const windowSlice = Math.floor(Date.now() / 1000 / 60);
    const key = `t:${TENANT}:rl:GET__api_v1_auth_me:${windowSlice}`;
    await cache.set(key, '350', 'EX', 50);

    await request(app.getHttpServer())
      .get('/api/v1/auth/me')
      .set('Authorization', `Bearer ${posToken}`)
      .expect(429);

    const metricsRes = await request(app.getHttpServer())
      .get('/metrics')
      .expect(200);

    expect(metricsRes.text).toMatch(
      /http_requests_total\{method="GET",route="\/api\/v1\/auth\/me",status_code="429"\}\s+[1-9]\d*/,
    );
  });

  it('labels unmatched routes (404) as "unmatched" to prevent cardinality explosion', async () => {
    const randomUrl = `/api/v1/scan-probe-${Date.now()}`;
    await request(app.getHttpServer()).get(randomUrl).expect(404);

    const metricsRes = await request(app.getHttpServer())
      .get('/metrics')
      .expect(200);

    expect(metricsRes.text).toMatch(
      /http_requests_total\{method="GET",route="unmatched",status_code="404"\}\s+[1-9]\d*/,
    );
    expect(metricsRes.text).not.toContain(randomUrl);
  });

  it('increments route counter after a sale is created (verifying exact delta +1)', async () => {
    const productId = 'prod-metric-1';
    await seedProduct(admin, TENANT, {
      id: productId,
      partNo: 'BP-123',
      name: 'Brake Pad',
      price: 500,
      cost: 300,
      stock: 10,
    });

    const beforeRes = await request(app.getHttpServer()).get('/metrics');
    const matchBefore = beforeRes.text.match(
      /http_requests_total\{method="POST",route="\/api\/v1\/sales",status_code="201"\}\s+(\d+)/,
    );
    const countBefore = matchBefore ? Number(matchBefore[1]) : 0;

    const billId = `s-metric-${Date.now()}`;
    const saleBody = {
      id: billId,
      subtotal: '500.00',
      discount: '0.00',
      total: '500.00',
      paymentMethod: 'เงินสด',
      items: [
        {
          lineNo: 1,
          productId,
          name: 'Brake Pad',
          qty: 1,
          price: '500.00',
        },
      ],
    };

    await request(app.getHttpServer())
      .post('/api/v1/sales')
      .set('Authorization', `Bearer ${posToken}`)
      .set('Idempotency-Key', `k-${billId}`)
      .send(saleBody)
      .expect(201);

    const afterRes = await request(app.getHttpServer()).get('/metrics');
    const matchAfter = afterRes.text.match(
      /http_requests_total\{method="POST",route="\/api\/v1\/sales",status_code="201"\}\s+(\d+)/,
    );
    const countAfter = matchAfter ? Number(matchAfter[1]) : 0;

    expect(countAfter - countBefore).toBe(1);
  });

  it('increments pos_idempotency_replay_total on replayed request (without tenant_id label)', async () => {
    const productId = 'prod-metric-replay';
    await seedProduct(admin, TENANT, {
      id: productId,
      partNo: 'RP-999',
      name: 'Replay Test Part',
      price: 100,
      cost: 50,
      stock: 50,
    });

    const key = `k-replay-${Date.now()}`;
    const billId = `s-replay-${Date.now()}`;
    const saleBody = {
      id: billId,
      subtotal: '100.00',
      discount: '0.00',
      total: '100.00',
      paymentMethod: 'เงินสด',
      items: [
        {
          lineNo: 1,
          productId,
          name: 'Replay Test Part',
          qty: 1,
          price: '100.00',
        },
      ],
    };

    // First call: succeeds with 201
    await request(app.getHttpServer())
      .post('/api/v1/sales')
      .set('Authorization', `Bearer ${posToken}`)
      .set('Idempotency-Key', key)
      .send(saleBody)
      .expect(201);

    const beforeMetrics = await request(app.getHttpServer()).get('/metrics');
    const countBefore = parseReplayCount(beforeMetrics.text);

    // Second call with same key: replayed with 201
    const replayRes = await request(app.getHttpServer())
      .post('/api/v1/sales')
      .set('Authorization', `Bearer ${posToken}`)
      .set('Idempotency-Key', key)
      .send(saleBody)
      .expect(201);

    expect(replayRes.body.data.id).toBe(billId);

    const afterMetrics = await request(app.getHttpServer()).get('/metrics');
    const countAfter = parseReplayCount(afterMetrics.text);

    // Replay counter must increment by exactly 1
    expect(countAfter - countBefore).toBe(1);

    // Must NOT contain tenant_id label (D5 #335)
    expect(afterMetrics.text).not.toMatch(/pos_idempotency_replay_total\{[^}]*tenant_id/);

    // Verify only ONE sale row was created in Postgres
    const rows = await admin.query(
      `SELECT count(*) FROM sales WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, billId],
    );
    expect(Number(rows[0].count)).toBe(1);
  });

  it('does NOT increment pos_idempotency_replay_total when transaction rolls back', async () => {
    const beforeMetrics = await request(app.getHttpServer()).get('/metrics');
    const countBefore = parseReplayCount(beforeMetrics.text);

    // 1. Initial attempt fails due to insufficient stock (409) and rolls back
    const failKey = `k-fail-${Date.now()}`;
    const failBillId = `s-fail-${Date.now()}`;
    await request(app.getHttpServer())
      .post('/api/v1/sales')
      .set('Authorization', `Bearer ${posToken}`)
      .set('Idempotency-Key', failKey)
      .send({
        id: failBillId,
        subtotal: '50000.00',
        discount: '0.00',
        total: '50000.00',
        paymentMethod: 'เงินสด',
        items: [
          {
            lineNo: 1,
            productId: 'prod-metric-replay',
            name: 'Replay Test Part',
            qty: 999999, // Insufficient stock throws 409 INSUFFICIENT_STOCK
            price: '50000.00',
          },
        ],
      })
      .expect(409);

    const midMetrics = await request(app.getHttpServer()).get('/metrics');
    expect(parseReplayCount(midMetrics.text)).toBe(countBefore);

    // 2. Retrying the same key with valid stock succeeds as a fresh claim, NOT a replay
    await request(app.getHttpServer())
      .post('/api/v1/sales')
      .set('Authorization', `Bearer ${posToken}`)
      .set('Idempotency-Key', failKey)
      .send({
        id: failBillId,
        subtotal: '100.00',
        discount: '0.00',
        total: '100.00',
        paymentMethod: 'เงินสด',
        items: [
          {
            lineNo: 1,
            productId: 'prod-metric-replay',
            name: 'Replay Test Part',
            qty: 1,
            price: '100.00',
          },
        ],
      })
      .expect(201);

    const postClaimMetrics = await request(app.getHttpServer()).get('/metrics');
    // Fresh claim does not increment replay counter
    expect(parseReplayCount(postClaimMetrics.text)).toBe(countBefore);

    // 3. A replay that occurs inside a transaction that subsequently rolls back
    //    must discard onTransactionCommit and NOT increment pos_idempotency_replay_total
    const idempotencyService = app.get(IdempotencyService);
    const tenantService = app.get(TenantService);
    const mockRes = { status: () => mockRes } as unknown as Response;

    await runInTenantScope(async () => {
      setRequestTenant(TENANT);
      await expect(
        tenantService.runTx(async () => {
          await idempotencyService.runIdempotent(
            {
              key: failKey,
              endpoint: 'POST /api/v1/sales',
              requestHash: IdempotencyService.requestHash({
                id: failBillId,
                subtotal: '100.00',
                discount: '0.00',
                total: '100.00',
                paymentMethod: 'เงินสด',
                items: [
                  {
                    lineNo: 1,
                    productId: 'prod-metric-replay',
                    name: 'Replay Test Part',
                    qty: 1,
                    price: '100.00',
                  },
                ],
              }),
              successCode: 201,
            },
            mockRes,
            () => {
              throw new Error('should not execute on replay');
            },
          );
          // Transaction aborts after the replay claim was made
          throw new Error('Simulated transaction rollback during replay');
        }),
      ).rejects.toThrow('Simulated transaction rollback during replay');
    });

    const finalMetrics = await request(app.getHttpServer()).get('/metrics');
    expect(parseReplayCount(finalMetrics.text)).toBe(countBefore);
  });
});
