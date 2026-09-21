import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
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

const TENANT = 'eeeeeeee-6666-4666-8666-eeeeeeeeeeee';

describe('metrics (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let fixture: TenantFixture;
  let posToken: string;

  beforeAll(async () => {
    ({ app, admin } = await createTestApp());
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
    await request(app.getHttpServer()).get('/health/live').expect(200);

    const metricsRes = await request(app.getHttpServer())
      .get('/metrics')
      .expect(200);

    expect(metricsRes.text).toMatch(
      /http_requests_total\{method="GET",route="\/health\/live",status_code="200"\}\s+[1-9]\d*/,
    );
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
});
