import type { INestApplication } from '@nestjs/common';
import type { Redis } from 'ioredis';
import type { DataSource } from 'typeorm';
import request from 'supertest';
import {
  accessToken,
  clearTenantCache,
  createTestApp,
  resetTenant,
} from './support/fixture.js';

// What this guards since tx.4 (#153): **nothing may take a pool connection before the guards
// run.** The global `TenantRateLimitGuard` and `TenantGuard` read `tenants` on the pool on a
// cold cache; that is safe only because the request holds no other connection yet — the
// handler's `runTx` takes it afterwards. A middleware, interceptor or earlier guard that
// held a connection across the guards would bring back the deadlock below.
//
// History (#162). `shifts.e2e-spec.ts` › *ten simultaneous opens* 500'd locally and passed in
// CI, and was filed as the request-wide-transaction pool limit. It was not a limit: it was a
// pool **deadlock**. The rate-limit guard looked the plan up with `DataSource.query` — a
// SECOND pool connection, taken while the (since deleted) request-wide middleware already
// held the request's first. Measured on clean `main`, `DB_POOL_SIZE=8`, ten simultaneous
// opens with the cache reset:
//
//   8 × plan lookup started within 6 ms
//   8 × plan lookup FAILED after 10 000 ms: timeout exceeded when trying to connect
//   2 × 500 from the middleware (`could not open the request transaction`)
//
// Eight requests each held one connection and waited for another; the two queued for a
// first connection timed out; the eight then failed open to `'basic'` and succeeded. A
// bigger pool only moves the burst size that trips it, and production's plan cache goes
// cold every five minutes. Whether it trips depends on every middleware connecting before
// any guard runs, which is why a fast Linux runner usually escaped and this machine never
// did — so this suite forces it: a pool of two, twice as many requests as the pool plus
// as many again, and the cache reset right before the burst.
describe('the rate-limit plan lookup does not deadlock the request pool (e2e)', () => {
  const TENANT = 'abababab-1621-4621-8621-abababababab';

  let app: INestApplication;
  let admin: DataSource;
  let cache: Redis;
  let posToken: string;

  beforeAll(async () => {
    // The fixture asks for 8 but spreads `process.env` after it (see
    // `void-denial-pool.e2e-spec.ts`). A short connect timeout keeps a regression a fast
    // red test rather than a ten-second one.
    const before = {
      pool: process.env.DB_POOL_SIZE,
      timeout: process.env.DB_CONNECTION_TIMEOUT_MS,
    };
    process.env.DB_POOL_SIZE = '2';
    process.env.DB_CONNECTION_TIMEOUT_MS = '5000';
    try {
      ({ app, admin, cache } = await createTestApp());
    } finally {
      if (before.pool === undefined) delete process.env.DB_POOL_SIZE;
      else process.env.DB_POOL_SIZE = before.pool;
      if (before.timeout === undefined) delete process.env.DB_CONNECTION_TIMEOUT_MS;
      else process.env.DB_CONNECTION_TIMEOUT_MS = before.timeout;
    }

    const t = await resetTenant(admin, TENANT, { posDeviceNo: 7, cache });
    posToken = accessToken({
      tenantId: TENANT,
      userId: t.userId,
      role: 'owner',
      deviceId: t.posDeviceId,
      deviceRole: 'pos',
    });
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT, { cache });
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  const open = (i: number) =>
    request(app.getHttpServer())
      .post('/api/v1/shifts/open')
      .set('Authorization', `Bearer ${posToken}`)
      .set('Idempotency-Key', `k-162-${i}-${Date.now()}`)
      .send({ startingCash: '1000.00' });

  const current = () =>
    request(app.getHttpServer())
      .get('/api/v1/shifts/current')
      .set('Authorization', `Bearer ${posToken}`);

  it('answers a cold-cache burst larger than the pool with no 500 and no connect timeout', async () => {
    // Cold, exactly as after a tenant reset or a plan-cache expiry.
    await clearTenantCache(cache, TENANT);

    const started = Date.now();
    const [opens, reads] = await Promise.all([
      Promise.all(Array.from({ length: 6 }, (_, i) => open(i))),
      Promise.all(Array.from({ length: 6 }, current)),
    ]);
    const elapsed = Date.now() - started;
    console.log(
      `PROBE 6 opens + 6 reads at pool 2: ${opens.map((r) => r.status).join(',')} | ` +
        `${reads.map((r) => r.status).join(',')}  ${elapsed} ms`,
    );

    expect(opens.map((r) => r.status)).toEqual([200, 200, 200, 200, 200, 200]);
    expect(reads.map((r) => r.status)).toEqual([200, 200, 200, 200, 200, 200]);
    // The open race still has to hold under real contention: one drawer.
    expect(new Set(opens.map((r) => r.body.data.id)).size).toBe(1);
    const rows = (await admin.query(
      `SELECT count(*)::int AS n FROM shifts WHERE tenant_id = $1::uuid`,
      [TENANT],
    )) as { n: number }[];
    expect(rows[0].n).toBe(1);
    // The deadlock's signature is every request waiting out `connectionTimeoutMillis`.
    expect(elapsed).toBeLessThan(3000);
    // And the lookup really succeeded rather than failing open to 'basic' — a failed
    // lookup caches nothing.
    expect(await cache.get(`t:${TENANT}:plan`)).not.toBeNull();
  });
});
