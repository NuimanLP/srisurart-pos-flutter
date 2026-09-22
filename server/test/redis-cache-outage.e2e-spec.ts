import { createServer } from 'node:net';
import type { AddressInfo } from 'node:net';
import type { INestApplication } from '@nestjs/common';
import type { Redis } from 'ioredis';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import { fakeRedis, untilReady, type FakeRedis } from './support/fake-redis.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedOpenShift,
  seedProduct,
} from './support/fixture.js';

/**
 * #383 — closes the gap in #294's DoD line ("ดับ `redis-cache` แล้วร้านที่ `suspended`
 * ยังถูกปฏิเสธ และร้านปกติยังใช้งานได้", ADR-0003 §5) that the old evidence
 * (`tenant-scope.e2e-spec.ts`'s removed test, see its git history) never actually proved:
 * it `vi.spyOn`'d the cache client's own methods — proving the guard's `catch` runs, not
 * that the app survives a `redis-cache` that is genuinely unreachable — and hit the
 * internal `/tx4-probe` route rather than `GET /products` + `POST /sales` with a real
 * stock decrement, which is what #294's AC and this file's issue both name.
 *
 * Two real failure shapes, both without touching a line of `cache`/`TenantCache`:
 * - "refused": `REDIS_CACHE_URL` points at a port nothing listens on.
 * - "hung": a real TCP server that finishes the ioredis handshake (so the client
 *   believes it is `ready`) and then answers nothing — the #140 case, reproduced with
 *   the same technique `src/infra/redis-command-timeout.spec.ts` uses at the unit level.
 */

const TENANT_REFUSED = '38338338-3833-4833-8383-383383383381';
const TENANT_HANG = '38338338-3833-4833-8383-383383383382';

/** Opens an ephemeral port and closes it at once: guaranteed nothing is listening there. */
async function closedPort(): Promise<number> {
  const srv = createServer();
  await new Promise<void>((resolve) => srv.listen(0, '127.0.0.1', resolve));
  const { port } = srv.address() as AddressInfo;
  await new Promise<void>((resolve) => srv.close(() => resolve()));
  return port;
}

interface Scenario {
  app: INestApplication;
  admin: DataSource;
  tenantId: string;
  token: string;
}

/**
 * `GET /products` (200, the seeded part listed) and `POST /sales` (201, stock really
 * decremented — read before/after, never just the status code) for an active tenant;
 * then the same tenant `suspended` is refused with `TENANT_SUSPENDED` on its very next
 * request — no cache to hold a stale `active` and nothing to wait out (ADR-0003 §5).
 */
async function assertActiveSellsAndSuspendedIsRejectedAtOnce(s: Scenario): Promise<void> {
  const http = () => request(s.app.getHttpServer());
  const productId = `p-${s.tenantId.slice(-4)}`;

  await seedProduct(s.admin, s.tenantId, {
    id: productId,
    partNo: `OUT-${s.tenantId.slice(-4)}`,
    name: 'Outage Test Part',
    price: 100,
    cost: 60,
    stock: 10,
  });

  const list = await http()
    .get('/api/v1/products')
    .set('Authorization', `Bearer ${s.token}`);
  expect(list.status).toBe(200);
  expect(
    (list.body.data as { id: string }[]).some((p) => p.id === productId),
  ).toBe(true);

  const stockBefore = (await s.admin.query(
    `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = $2`,
    [s.tenantId, productId],
  )) as { stock: number }[];
  expect(stockBefore[0].stock).toBe(10);

  const idempotencyKey = `k-outage-${s.tenantId}-${Date.now()}`;
  const saleBody = {
    id: `s-outage-${s.tenantId}`,
    subtotal: '100.00',
    discount: '0.00',
    total: '100.00',
    paymentMethod: 'เงินสด',
    items: [
      { lineNo: 1, productId, name: 'Outage Test Part', qty: 1, price: '100.00' },
    ],
  };
  const postSale = () =>
    http()
      .post('/api/v1/sales')
      .set('Authorization', `Bearer ${s.token}`)
      .set('Idempotency-Key', idempotencyKey)
      .send(saleBody);

  const sale = await postSale();
  expect(sale.status).toBe(201);

  // Stock really moved, not just a 201 with no side effect.
  const stockAfter = (await s.admin.query(
    `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = $2`,
    [s.tenantId, productId],
  )) as { stock: number }[];
  expect(stockAfter[0].stock).toBe(9);

  // IdempotencyService's own Redis use (readCache/writeCache) is a separate fail-open
  // path from TenantGuard's and TenantCache's — replaying the same key is the only way
  // to reach it, so a bare 201 above would leave it completely unexercised. It must
  // fail open here too: same response, no second decrement.
  const replay = await postSale();
  expect(replay.status).toBe(201);
  expect(replay.body).toEqual(sale.body);
  const stockAfterReplay = (await s.admin.query(
    `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = $2`,
    [s.tenantId, productId],
  )) as { stock: number }[];
  expect(stockAfterReplay[0].stock).toBe(9);

  await s.admin.query(
    `UPDATE tenants SET status = 'suspended' WHERE id = $1::uuid`,
    [s.tenantId],
  );

  const suspended = await http()
    .get('/api/v1/products')
    .set('Authorization', `Bearer ${s.token}`);
  expect(suspended.status).toBe(403);
  expect(suspended.body.error.code).toBe('TENANT_SUSPENDED');
}

describe('redis-cache unreachable: connection refused (e2e, #383)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: Redis;
  let token: string;

  beforeAll(async () => {
    const before = process.env.REDIS_CACHE_URL;
    // Nothing listens here: every cache/plan/idempotency call ioredis makes rejects
    // with ECONNREFUSED, and `enableOfflineQueue: false` (redis.module.ts) means every
    // one of those calls fails fast rather than queueing behind a reconnect.
    process.env.REDIS_CACHE_URL = `redis://127.0.0.1:${await closedPort()}`;
    try {
      ({ app, admin, cache } = await createTestApp());
    } finally {
      if (before === undefined) delete process.env.REDIS_CACHE_URL;
      else process.env.REDIS_CACHE_URL = before;
    }
  });

  beforeEach(async () => {
    // No `cache` passed: redis-cache is unreachable by construction, so there is
    // nothing for resetTenant to clear there.
    const fixture = await resetTenant(admin, TENANT_REFUSED, { posDeviceNo: 33 });
    await seedOpenShift(admin, TENANT_REFUSED, fixture.posDeviceId);
    token = accessToken({
      tenantId: TENANT_REFUSED,
      userId: fixture.userId,
      role: 'owner',
      deviceId: fixture.posDeviceId,
      deviceRole: 'pos',
    });
  });

  afterAll(async () => {
    try {
      // Wipes every child table first (FK order), same as `beforeEach`, before dropping
      // the tenant row itself — the sale above left a `movements` row referencing the
      // product, which a bare `DELETE FROM tenants` cannot cascade through.
      await resetTenant(admin, TENANT_REFUSED, { posDeviceNo: 33 });
      await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT_REFUSED]);
    } finally {
      // This client never reached `ready`, so `RedisModule.onModuleDestroy`'s own
      // `cache.quit()` (run inside `app.close()` below) rejects instantly without ever
      // calling `disconnect()` — `enableOfflineQueue: false` makes ioredis refuse the
      // command outright instead of reaching `quit`'s own disconnect path. Left alone,
      // the client's `retryStrategy` would keep retrying this dead port forever, in the
      // background, for the rest of the single-process `pnpm test:e2e` run
      // (`fileParallelism: false`). Disconnect it directly first.
      cache.disconnect();
      await app.close();
    }
  });

  it('an active tenant still sells for real, and a suspended tenant is rejected at once', async () => {
    await assertActiveSellsAndSuspendedIsRejectedAtOnce({
      app,
      admin,
      tenantId: TENANT_REFUSED,
      token,
    });
  });
});

describe('redis-cache unreachable: connected but silent until timeout (e2e, #140/#383)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let fake: FakeRedis;
  let cache: Redis;
  let token: string;

  beforeAll(async () => {
    fake = await fakeRedis();
    const beforeUrl = process.env.REDIS_CACHE_URL;
    const beforeTimeout = process.env.REDIS_COMMAND_TIMEOUT_MS;
    process.env.REDIS_CACHE_URL = fake.url;
    // Short and deterministic rather than the 1000 ms default, purely so this suite's
    // several guarded requests (each making several cache/plan calls that all pay one
    // full command timeout apiece once the fake goes silent) don't turn this file slow.
    // #140's own unit spec already proves the timeout mechanism works at any value.
    process.env.REDIS_COMMAND_TIMEOUT_MS = '300';
    try {
      ({ app, admin, cache } = await createTestApp());
    } finally {
      if (beforeUrl === undefined) delete process.env.REDIS_CACHE_URL;
      else process.env.REDIS_CACHE_URL = beforeUrl;
      if (beforeTimeout === undefined) delete process.env.REDIS_COMMAND_TIMEOUT_MS;
      else process.env.REDIS_COMMAND_TIMEOUT_MS = beforeTimeout;
    }
    // Let the app's own client finish its real handshake and reach `ready` BEFORE
    // cutting the fake off — the case this covers is a socket that stays open and
    // goes silent (#140), not one that never connects at all (the describe block
    // above already covers "never connects").
    await untilReady(cache);
    fake.hang();
  });

  beforeEach(async () => {
    const fixture = await resetTenant(admin, TENANT_HANG, { posDeviceNo: 34 });
    await seedOpenShift(admin, TENANT_HANG, fixture.posDeviceId);
    token = accessToken({
      tenantId: TENANT_HANG,
      userId: fixture.userId,
      role: 'owner',
      deviceId: fixture.posDeviceId,
      deviceRole: 'pos',
    });
  });

  afterAll(async () => {
    try {
      await resetTenant(admin, TENANT_HANG, { posDeviceNo: 34 });
      await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT_HANG]);
    } finally {
      // Same reasoning as the "connection refused" describe's afterAll: `app.close()`
      // alone leaves `cache` retrying this fake forever in the background once
      // `fake.close()` tears down its socket, because `quit()` never reaches its own
      // disconnect path when the client isn't currently writable. Disconnect first.
      cache.disconnect();
      await app.close();
      await fake.close();
    }
  });

  it('an active tenant still sells for real, and a suspended tenant is rejected at once', async () => {
    await assertActiveSellsAndSuspendedIsRejectedAtOnce({
      app,
      admin,
      tenantId: TENANT_HANG,
      token,
    });
  });
});
