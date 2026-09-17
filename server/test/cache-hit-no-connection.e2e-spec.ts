import type { INestApplication } from '@nestjs/common';
import type { Redis } from 'ioredis';
import request, { type Response } from 'supertest';
import { DataSource } from 'typeorm';
import { TenantCache } from '../src/infra/tenant-cache.service.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedProduct,
} from './support/fixture.js';

/**
 * #173 — a cached read looks at Redis before it takes a pooled connection. tx.2 wrapped
 * each cached read whole in `runTx`, so after tx.4 removed the request-wide transaction a
 * HIT still ran BEGIN / set_config / COMMIT on a pooled connection, and a `singleFlight`
 * waiter sat `idle in transaction` for up to `LOCK_WAIT_MS` doing nothing but poll Redis.
 */
const TENANT = '17317317-3173-4173-8173-173173173173';

describe('cached reads take no connection until they miss (e2e, #173)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: Redis;
  let token: string;

  const get = (path: string): Promise<Response> =>
    request(app.getHttpServer())
      .get(`/api/v1${path}`)
      .set('Authorization', `Bearer ${token}`);

  beforeAll(async () => {
    // Pool 2: small enough that two idle-in-transaction waiters would be the whole pool.
    const before = process.env.DB_POOL_SIZE;
    process.env.DB_POOL_SIZE = '2';
    try {
      ({ app, admin, cache } = await createTestApp());
    } finally {
      if (before === undefined) delete process.env.DB_POOL_SIZE;
      else process.env.DB_POOL_SIZE = before;
    }
  });

  beforeEach(async () => {
    const fixture = await resetTenant(admin, TENANT, { posDeviceNo: 17, cache });
    await seedProduct(admin, TENANT, {
      id: 'p1',
      partNo: 'BP-1',
      name: 'Brake Pad',
      price: 100,
      cost: 60,
      stock: 50,
    });
    token = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'owner',
      deviceId: fixture.posDeviceId,
      deviceRole: 'pos',
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT, { cache });
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it.each([
    ['/products?page=1&limit=20'],
    ['/products/p1'],
    ['/categories'],
    ['/settings'],
  ])('a HIT on %s creates zero query runners', async (path) => {
    // Warm everything a request reads: the cache entry itself, and the guard's cached
    // tenant status and plan, so the second request has no reason to touch Postgres.
    const miss = await get(path);
    expect(miss.status).toBe(200);
    expect(miss.headers['x-cache']).toBe('MISS');

    // `DataSource.query` opens a runner too, so this counts every pool use.
    const runners = vi.spyOn(app.get(DataSource), 'createQueryRunner');
    const hit = await get(path);

    expect(hit.status).toBe(200);
    expect(hit.headers['x-cache']).toBe('HIT');
    expect(hit.body).toEqual(miss.body);
    expect(runners).not.toHaveBeenCalled();
  });

  it('singleFlight waiters hold no connection idle in a transaction while they wait', async () => {
    const LIST = '/products?page=1&limit=20';
    // Warm the guard's caches with a different key, so the burst below is all list misses.
    expect((await get('/products?page=2&limit=20')).status).toBe(200);

    // A slow store keeps the lock held while the waiters poll.
    const tenantCache = app.get(TenantCache);
    const store = tenantCache.set.bind(tenantCache);
    vi.spyOn(tenantCache, 'set').mockImplementation(async (key, value, ns) => {
      await new Promise((resolve) => setTimeout(resolve, 600));
      return store(key, value, ns);
    });

    const burst = Promise.all(Array.from({ length: 4 }, () => get(LIST)));
    await new Promise((resolve) => setTimeout(resolve, 300));
    const [{ n }] = (await admin.query(
      `SELECT count(*)::int AS n FROM pg_stat_activity
        WHERE usename = 'pos_app' AND state = 'idle in transaction'`,
    )) as { n: number }[];
    const answers = await burst;

    expect(answers.map((r) => r.status)).toEqual([200, 200, 200, 200]);
    expect(answers.filter((r) => r.headers['x-cache'] === 'MISS')).toHaveLength(1);
    expect(n).toBe(0);
  });
});
