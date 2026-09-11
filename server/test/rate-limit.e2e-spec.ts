import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import type { Redis } from 'ioredis';
import {
  accessToken,
  clearTenantCache,
  createTestApp,
  resetTenant,
  type TenantFixture,
} from './support/fixture.js';

const TENANT_A = '44444444-1111-4111-8111-444444444444';
const TENANT_B = '55555555-2222-4222-8222-555555555555';
const TENANT_LOADTEST = '66666666-3333-4333-8333-666666666666';

describe('Per-tenant rate limiting (ADR-0006 e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: Redis;
  let fixtureA: TenantFixture;
  let fixtureB: TenantFixture;

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixtureA = await resetTenant(admin, TENANT_A, { cache });
    fixtureB = await resetTenant(admin, TENANT_B, { cache });

    await clearTenantCache(cache, TENANT_A);
    await clearTenantCache(cache, TENANT_B);
    await clearTenantCache(cache, TENANT_LOADTEST);
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT_A, { cache });
    await resetTenant(admin, TENANT_B, { cache });
    await resetTenant(admin, TENANT_LOADTEST, { cache });
    await admin.query(`DELETE FROM tenants WHERE id IN ($1::uuid, $2::uuid, $3::uuid)`, [
      TENANT_A,
      TENANT_B,
      TENANT_LOADTEST,
    ]);
    await app.close();
  });

  it('exempts /health/live and /health/ready unconditionally', async () => {
    const liveRes = await request(app.getHttpServer()).get('/health/live');
    expect(liveRes.status).toBe(200);

    const readyRes = await request(app.getHttpServer()).get('/health/ready');
    expect(readyRes.status).toBe(200);
  });

  it('allows under-quota traffic for authenticated tenant', async () => {
    const token = accessToken({
      tenantId: TENANT_A,
      userId: fixtureA.userId,
      role: 'cashier',
    });

    const res = await request(app.getHttpServer())
      .get('/api/v1/auth/me')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
  });

  it('returns 429 RATE_LIMITED with Retry-After header when quota is exhausted', async () => {
    const token = accessToken({
      tenantId: TENANT_A,
      userId: fixtureA.userId,
      role: 'cashier',
    });

    // Preset counter in Redis to hit limit (default 300)
    const windowSec = 60;
    const nowSec = Math.floor(Date.now() / 1000);
    const windowSlice = Math.floor(nowSec / windowSec);
    // GET /api/v1/auth/me route key
    const key = `t:${TENANT_A}:rl:GET__api_v1_auth_me:${windowSlice}`;
    await cache.set(key, '350', 'EX', 50);

    const res = await request(app.getHttpServer())
      .get('/api/v1/auth/me')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(429);
    expect(res.headers['retry-after']).toBeDefined();
    expect(Number(res.headers['retry-after'])).toBeGreaterThan(0);
    expect(res.body).toEqual({
      status: 'error',
      error: {
        code: 'RATE_LIMITED',
        message: 'ระบบกำลังทำงานหนัก กรุณารอสักครู่',
      },
    });
  });

  it('isolates tenants: Tenant A exhausted quota does not block Tenant B', async () => {
    const tokenA = accessToken({
      tenantId: TENANT_A,
      userId: fixtureA.userId,
      role: 'cashier',
    });
    const tokenB = accessToken({
      tenantId: TENANT_B,
      userId: fixtureB.userId,
      role: 'cashier',
    });

    // Exhaust Tenant A
    const windowSec = 60;
    const nowSec = Math.floor(Date.now() / 1000);
    const windowSlice = Math.floor(nowSec / windowSec);
    const keyA = `t:${TENANT_A}:rl:GET__api_v1_auth_me:${windowSlice}`;
    await cache.set(keyA, '350', 'EX', 50);

    // Tenant A is 429
    const resA = await request(app.getHttpServer())
      .get('/api/v1/auth/me')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(resA.status).toBe(429);

    // Tenant B is still 200 OK
    const resB = await request(app.getHttpServer())
      .get('/api/v1/auth/me')
      .set('Authorization', `Bearer ${tokenB}`);
    expect(resB.status).toBe(200);
  });

  it('bypasses rate limit if tenant plan is loadtest (ADR-0006)', async () => {
    const fixtureLoadtest = await resetTenant(admin, TENANT_LOADTEST, { cache });
    await admin.query(`UPDATE tenants SET plan = 'loadtest' WHERE id = $1::uuid`, [TENANT_LOADTEST]);
    const tokenLoadtest = accessToken({
      tenantId: TENANT_LOADTEST,
      userId: fixtureLoadtest.userId,
      role: 'cashier',
    });

    // Preset Redis counter above limit
    const windowSec = 60;
    const nowSec = Math.floor(Date.now() / 1000);
    const windowSlice = Math.floor(nowSec / windowSec);
    const key = `t:${TENANT_LOADTEST}:rl:GET__api_v1_auth_me:${windowSlice}`;
    await cache.set(key, '9999', 'EX', 50);

    // Should succeed with 200 because plan === 'loadtest'
    const res = await request(app.getHttpServer())
      .get('/api/v1/auth/me')
      .set('Authorization', `Bearer ${tokenLoadtest}`);
    expect(res.status).toBe(200);
  });

  it('ignores forged X-Tenant-Id header and keys off JWT token only', async () => {
    const tokenA = accessToken({
      tenantId: TENANT_A,
      userId: fixtureA.userId,
      role: 'cashier',
    });

    // Preset Tenant B as exhausted
    const windowSec = 60;
    const nowSec = Math.floor(Date.now() / 1000);
    const windowSlice = Math.floor(nowSec / windowSec);
    const keyB = `t:${TENANT_B}:rl:GET__api_v1_auth_me:${windowSlice}`;
    await cache.set(keyB, '350', 'EX', 50);

    // Request carries Tenant A token, but attempts to spoof X-Tenant-Id: Tenant B
    const res = await request(app.getHttpServer())
      .get('/api/v1/auth/me')
      .set('Authorization', `Bearer ${tokenA}`)
      .set('X-Tenant-Id', TENANT_B);

    // Must answer 200 because actual token is Tenant A (unlimited), ignoring X-Tenant-Id
    expect(res.status).toBe(200);
  });
});
