import { Redis } from 'ioredis';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { runInTenantScope } from '../common/request-context.js';
import { loadConfig } from '../config/config.js';
import { fakeRedis, untilReady, type FakeRedis } from '../../test/support/fake-redis.js';
import { createRedisClient } from './redis.module.js';
import { TenantCache } from './tenant-cache.service.js';

/**
 * #140: a Redis that keeps the TCP connection open but stops answering. `enableOfflineQueue:
 * false` never trips here — ioredis still believes the socket is fine — so before `commandTimeout`
 * every command on this client waited forever.
 */

const TIMEOUT_MS = 100;
/** Generous against CI jitter, and still far below "hangs forever". */
const BOUND_MS = 1500;
const TID = '00000000-0000-4000-8000-000000000140';

async function timed<T>(run: () => Promise<T>): Promise<{ value: T; ms: number }> {
  const started = Date.now();
  const value = await run();
  return { value, ms: Date.now() - started };
}

describe('REDIS_COMMAND_TIMEOUT_MS (#140)', () => {
  const base = {
    INSTANCE_ID: 'worker',
    DATABASE_URL: 'postgres://u:p@h/db',
    REDIS_CACHE_URL: 'redis://h:6379',
    REDIS_QUEUE_URL: 'redis://h:6380',
    JWT_PLATFORM_SECRET: 'test-only-platform-secret', // #398: required unconditionally
    POSTGRES_PASSWORD: 'test-only-postgres', // #410: the dev-only fallback is refused
  };

  it('defaults to 1000 ms and takes a positive integer', () => {
    expect(loadConfig(base).redisCommandTimeoutMs).toBe(1000);
    expect(loadConfig({ ...base, REDIS_COMMAND_TIMEOUT_MS: '750' }).redisCommandTimeoutMs).toBe(750);
  });

  it('refuses 0, negatives and garbage, which ioredis would turn into an instant timeout', () => {
    for (const bad of ['0', '-5', '1.5', 'abc']) {
      expect(() => loadConfig({ ...base, REDIS_COMMAND_TIMEOUT_MS: bad })).toThrow(
        /REDIS_COMMAND_TIMEOUT_MS/,
      );
    }
  });
});

describe('Redis commandTimeout (#140)', () => {
  const logger = { warn: vi.fn() };
  let fake: FakeRedis;
  let client: Redis;

  beforeEach(async () => {
    fake = await fakeRedis();
    client = createRedisClient(fake.url, 'cache', logger as any, TIMEOUT_MS);
    await untilReady(client);
  });

  afterEach(async () => {
    client.disconnect();
    await fake.close();
  });

  it('the fake reproduces the hang: without commandTimeout a command never settles', async () => {
    const bare = new Redis(fake.url, { enableOfflineQueue: false, maxRetriesPerRequest: 1 });
    try {
      await untilReady(bare);
      fake.hang();
      const outcome = await Promise.race([
        bare.get('k').then(
          () => 'settled',
          () => 'settled',
        ),
        new Promise((resolve) => setTimeout(() => resolve('pending'), 5 * TIMEOUT_MS)),
      ]);
      expect(outcome).toBe('pending');
      expect(bare.status).toBe('ready');
    } finally {
      bare.disconnect();
    }
  });

  it('a command on an open but silent connection rejects after the timeout', async () => {
    fake.hang();
    const started = Date.now();
    await expect(client.get('k')).rejects.toThrow(/Command timed out/);
    expect(Date.now() - started).toBeLessThan(BOUND_MS);
    // Not a disconnect: ioredis still thinks the socket is fine, which is the whole case.
    expect(client.status).toBe('ready');
  });

  it('TenantCache fails open on every call: no prefix, a miss, a no-op set and invalidate', async () => {
    fake.hang();
    const cache = new TenantCache(client, logger as any);

    const prefix = await timed(() => cache.prefix(TID, 'products'));
    expect(prefix.value).toBeNull();
    expect(prefix.ms).toBeLessThan(BOUND_MS);

    const get = await timed(() => cache.get('t:x:products:g:y:list'));
    expect(get.value).toBeNull();
    expect(get.ms).toBeLessThan(BOUND_MS);

    const set = await timed(() => cache.set('t:x:products:g:y:list', { total: 1 }, 'products'));
    expect(set.value).toBeUndefined();
    expect(set.ms).toBeLessThan(BOUND_MS);

    const inv = await timed(() => cache.invalidate(TID, 'products'));
    expect(inv.value).toBeUndefined();
    expect(inv.ms).toBeLessThan(BOUND_MS);
  });

  it('the stampede lock: a timed-out acquire answers a no-op release, and never waits out LOCK_WAIT_MS', async () => {
    fake.hang();
    const cache = new TenantCache(client, logger as any);
    const flight = await timed(() => cache.singleFlight('t:x:products:g:y:list'));
    expect('release' in flight.value).toBe(true);
    expect(flight.ms).toBeLessThan(BOUND_MS);
    const release = (flight.value as { release: () => Promise<void> }).release;
    await expect(release()).resolves.toBeUndefined();
  });

  it('the stampede lock: a lock taken before the hang releases without throwing to the caller', async () => {
    const cache = new TenantCache(client, logger as any);
    const flight = await cache.singleFlight('t:x:products:g:y:list');
    expect('release' in flight).toBe(true);

    fake.hang();
    const release = (flight as { release: () => Promise<void> }).release;
    const released = await timed(() => release());
    expect(released.value).toBeUndefined();
    expect(released.ms).toBeLessThan(BOUND_MS);
  });

  it('TenantGuard reads tenant status from Postgres when the cached read times out', async () => {
    fake.hang();
    const jwtVerifier = {
      verify: vi.fn().mockReturnValue({
        sub: 'u1',
        tid: TID,
        aud: 'tenant',
        role: 'owner',
        did: 'd1',
        drole: 'pos',
      }),
    };
    const reflector = { getAllAndOverride: vi.fn().mockReturnValue(undefined) };
    const ds = {
      query: vi.fn(async (sql: string) => (sql.includes('FROM tenants') ? [{ status: 'active' }] : [])),
    };
    const guard = new TenantGuard(jwtVerifier as any, reflector as any, client, ds as any);
    const request = { headers: { authorization: 'Bearer token' } };
    const ctx = {
      switchToHttp: () => ({ getRequest: () => request }),
      getHandler: () => ({}),
      getClass: () => ({}),
    } as any;

    const result = await timed(() =>
      runInTenantScope(() => guard.canActivate(ctx)),
    );

    expect(result.value).toBe(true);
    // The status read and the write-back each time out once; nothing waits longer.
    expect(result.ms).toBeLessThan(BOUND_MS);
    expect(ds.query).toHaveBeenCalledWith(`SELECT status FROM tenants WHERE id = $1`, [TID]);
  });
});
