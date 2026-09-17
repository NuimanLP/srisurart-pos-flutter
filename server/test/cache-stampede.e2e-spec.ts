import type { INestApplication } from '@nestjs/common';
import type { Redis } from 'ioredis';
import request, { type Response } from 'supertest';
import type { DataSource } from 'typeorm';
import { TenantCache } from '../src/infra/tenant-cache.service.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedProduct,
} from './support/fixture.js';

/**
 * #124 — the stampede lock on a `GET /products` miss (02_API_SCREENS.md §5,
 * `SET key NX PX 5000`). Only one of a burst of concurrent misses reads Postgres; the
 * others answer the value it stored. And the lock never costs a request its answer:
 * Redis down, or a loader that died holding the lock, still reads Postgres.
 */
const TENANT = '12412412-1241-4124-8124-124124124124';
const LIST = '/products?page=1&limit=20';

describe('cache stampede lock (e2e, #124)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: Redis;
  let token: string;

  const get = (path: string): Promise<Response> =>
    request(app.getHttpServer())
      .get(`/api/v1${path}`)
      .set('Authorization', `Bearer ${token}`);

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    const fixture = await resetTenant(admin, TENANT, { posDeviceNo: 24, cache });
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

  it('six concurrent misses on one key: one reads Postgres, five answer its value', async () => {
    // A slow store stands in for a slow list query: without the lock every request
    // misses before the first one's value lands.
    const tenantCache = app.get(TenantCache);
    const store = tenantCache.set.bind(tenantCache);
    vi.spyOn(tenantCache, 'set').mockImplementation(async (key, value, ns) => {
      await new Promise((resolve) => setTimeout(resolve, 300));
      return store(key, value, ns);
    });

    const answers = await Promise.all(Array.from({ length: 6 }, () => get(LIST)));

    expect(answers.map((r) => r.status)).toEqual([200, 200, 200, 200, 200, 200]);
    expect(answers.filter((r) => r.headers['x-cache'] === 'MISS')).toHaveLength(1);
    expect(answers.filter((r) => r.headers['x-cache'] === 'HIT')).toHaveLength(5);
    for (const r of answers) expect(r.body.data).toEqual(answers[0].body.data);
    expect(tenantCache.set).toHaveBeenCalledTimes(1);
  });

  it('with Redis failing every call, the list still answers 200 from Postgres', async () => {
    vi.spyOn(cache, 'get').mockRejectedValue(new Error('redis down'));
    vi.spyOn(cache, 'set').mockRejectedValue(new Error('redis down'));

    const res = await get(LIST);

    expect(res.status).toBe(200);
    expect(res.headers['x-cache']).toBe('MISS');
    expect((res.body.data as { id: string }[]).map((p) => p.id)).toEqual(['p1']);
  });

  it('a lock left by a loader that died costs a bounded wait, then Postgres answers', async () => {
    const prefix = await app.get(TenantCache).prefix(TENANT, 'products');
    await cache.set(`${prefix}list:1:20:lock`, 'dead-loader', 'PX', 5000);

    const started = Date.now();
    const res = await get(LIST);
    const waited = Date.now() - started;

    expect(res.status).toBe(200);
    expect(res.headers['x-cache']).toBe('MISS');
    expect(waited).toBeGreaterThanOrEqual(900);
    expect(waited).toBeLessThan(4000);
    // Not this request's lock: it is left to expire, not freed.
    expect(await cache.get(`${prefix}list:1:20:lock`)).toBe('dead-loader');
  });
});
