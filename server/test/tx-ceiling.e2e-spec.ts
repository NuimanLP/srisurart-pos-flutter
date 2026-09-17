import type { INestApplication } from '@nestjs/common';
import type { Redis } from 'ioredis';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import { APP_ROLE_TIMEOUTS } from '../src/common/database/commit-ceiling.js';
import { TenantService } from '../src/common/database/tenant.service.js';
import { runInTenantScope, setRequestTenant } from '../src/common/request-context.js';
import { DocNumberService } from '../src/documents/doc-number.service.js';
import { AUDIT_DATA_SOURCE } from '../src/infra/db.module.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedOpenShift,
  seedProduct,
} from './support/fixture.js';

// #213: the transaction ceiling behind ADR-0010's 30 s cursor rewind — README
// *The transaction ceiling (#213)* has the design. Each case runs a real request (or a real
// `runTx`) at `DB_POOL_SIZE=2` and checks what it leaves behind: an error instead of a hang,
// nothing committed, and a pool the next burst can still use. The short connect timeout
// makes a leaked connection a fast red (the #162 signature) rather than a ten-second one.
describe('pos_app transactions cannot outlive the 30 s cursor rewind (e2e, #213)', () => {
  const TENANT = '21321321-3333-4333-8333-213213213213';

  let app: INestApplication;
  let ds: DataSource;
  let admin: DataSource;
  let cache: Redis;
  let tenants: TenantService;
  let token: string;
  let seq = 0;

  beforeAll(async () => {
    const before = {
      pool: process.env.DB_POOL_SIZE,
      timeout: process.env.DB_CONNECTION_TIMEOUT_MS,
    };
    process.env.DB_POOL_SIZE = '2';
    process.env.DB_CONNECTION_TIMEOUT_MS = '5000';
    try {
      ({ app, ds, admin, cache } = await createTestApp());
    } finally {
      if (before.pool === undefined) delete process.env.DB_POOL_SIZE;
      else process.env.DB_POOL_SIZE = before.pool;
      if (before.timeout === undefined) delete process.env.DB_CONNECTION_TIMEOUT_MS;
      else process.env.DB_CONNECTION_TIMEOUT_MS = before.timeout;
    }
    tenants = app.get(TenantService);
    const t = await resetTenant(admin, TENANT, { posDeviceNo: 13, cache });
    token = accessToken({
      tenantId: TENANT,
      userId: t.userId,
      role: 'owner',
      deviceId: t.posDeviceId,
      deviceRole: 'pos',
    });
    for (const id of ['p1', 'p2']) {
      await seedProduct(admin, TENANT, {
        id,
        partNo: `OF-${id}`,
        name: `Oil Filter ${id}`,
        price: 85,
        cost: 50,
        stock: 100,
      });
    }
    await seedOpenShift(admin, TENANT, t.posDeviceId, { userId: t.userId });
  });

  afterEach(() => {
    vi.restoreAllMocks();
    tenants.commitCeilingMs = 25_000;
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT, { cache });
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
  const fresh = (what: string) => `${what}-213-${++seq}-${Date.now()}`;

  const sell = (key: string, id: string, productId = 'p1') =>
    request(app.getHttpServer())
      .post('/api/v1/sales')
      .set('Authorization', `Bearer ${token}`)
      .set('Idempotency-Key', key)
      .send({
        id,
        subtotal: '85.00',
        discount: '0.00',
        total: '85.00',
        paymentMethod: 'เงินสด',
        items: [
          {
            lineNo: 1,
            productId,
            partNo: `OF-${productId}`,
            name: `Oil Filter ${productId}`,
            nameTH: `Oil Filter ${productId}`,
            qty: 1,
            price: '85.00',
          },
        ],
      })
      // Bounded, so a missing ceiling fails as a timeout instead of hanging the suite.
      .timeout(30_000);

  const current = () =>
    request(app.getHttpServer())
      .get('/api/v1/shifts/current')
      .set('Authorization', `Bearer ${token}`);

  const count = async (sql: string, params: unknown[]) =>
    ((await admin.query(sql, params)) as { n: number }[])[0].n;
  const saleCount = (id: string) =>
    count(`SELECT count(*)::int AS n FROM sales WHERE tenant_id = $1::uuid AND id = $2`, [
      TENANT,
      id,
    ]);
  const keyCount = (key: string) =>
    count(
      `SELECT count(*)::int AS n FROM idempotency_keys WHERE tenant_id = $1::uuid AND key = $2`,
      [TENANT, key],
    );

  /** Whether the next burst is served at once, after whatever the case did to the pool. */
  const expectPoolServes = async () => {
    const started = Date.now();
    const [bills, reads] = await Promise.all([
      Promise.all([0, 1, 2].map(() => sell(fresh('k-after'), fresh('s-after')))),
      Promise.all([0, 1, 2].map(current)),
    ]);
    const elapsed = Date.now() - started;
    console.log(
      `PROBE burst at pool 2: ${bills.map((r) => r.status).join(',')} | ` +
        `${reads.map((r) => r.status).join(',')}  ${elapsed} ms`,
    );
    expect(bills.map((r) => r.status)).toEqual([201, 201, 201]);
    expect(reads.map((r) => r.status)).toEqual([200, 200, 200]);
    expect(elapsed).toBeLessThan(3000);
  };

  it('every pos_app pool carries the role timeouts; the owner connection does not', async () => {
    const show = async (on: DataSource) => {
      const [s] = await on.query(`SHOW statement_timeout`);
      const [i] = await on.query(`SHOW idle_in_transaction_session_timeout`);
      return [s.statement_timeout, i.idle_in_transaction_session_timeout];
    };
    const expected = [
      APP_ROLE_TIMEOUTS.statement_timeout,
      APP_ROLE_TIMEOUTS.idle_in_transaction_session_timeout,
    ];
    expect(expected).toEqual(['25s', '5s']);
    expect(await show(ds)).toEqual(expected);
    expect(await show(app.get<DataSource>(AUDIT_DATA_SOURCE))).toEqual(expected);
    // Migrations and platform provisioning/import run as the owner, uncapped.
    expect(await show(admin)).toEqual(['0', '0']);
  });

  it('a read statement longer than the idle timeout still answers (reports over years of data)', async () => {
    const started = Date.now();
    const rows = await runInTenantScope(async () => {
      setRequestTenant(TENANT);
      return tenants.runTx((m) => m.query(`SELECT pg_sleep(6), 1 AS ok`));
    });
    const elapsed = Date.now() - started;
    console.log(`PROBE 6 s read in runTx: ok after ${elapsed} ms`);
    expect(rows).toEqual([{ pg_sleep: '', ok: 1 }]);
    expect(elapsed).toBeGreaterThanOrEqual(6000);
  });

  it('a write transaction past the commit ceiling is rolled back — nothing commits, the claim included — and its resend goes through', async () => {
    // Lowered so the suite does not sleep 25 s; the check is the production one.
    tenants.commitCeilingMs = 300;
    const docs = app.get(DocNumberService);
    const issue = docs.issue.bind(docs);
    vi.spyOn(docs, 'issue').mockImplementation(async (...args) => {
      await sleep(600);
      return issue(...args);
    });
    const key = fresh('k-guard');
    const id = fresh('s-guard');

    const started = Date.now();
    const res = await sell(key, id);
    const elapsed = Date.now() - started;
    console.log(`PROBE bill past the commit ceiling: ${res.status} after ${elapsed} ms`);

    // A 5xx, not a 4xx: the client reads it as "fate unknown" and resends the same key.
    expect(res.status).toBe(500);
    expect(elapsed).toBeLessThan(3000);
    expect(await saleCount(id)).toBe(0);
    expect(await keyCount(key)).toBe(0);
    const stock = await count(
      `SELECT stock AS n FROM products WHERE tenant_id = $1::uuid AND id = 'p1'`,
      [TENANT],
    );

    vi.restoreAllMocks();
    tenants.commitCeilingMs = 25_000;
    const retry = await sell(key, id);
    expect(retry.status).toBe(201);
    expect(await saleCount(id)).toBe(1);
    expect(
      await count(`SELECT stock AS n FROM products WHERE tenant_id = $1::uuid AND id = 'p1'`, [
        TENANT,
      ]),
    ).toBe(stock - 1);
  });

  it('a transaction the app stalls past the idle timeout is ended by Postgres, and the pool recovers', async () => {
    const docs = app.get(DocNumberService);
    const issue = docs.issue.bind(docs);
    vi.spyOn(docs, 'issue').mockImplementation(async (...args) => {
      await sleep(5500);
      return issue(...args);
    });

    // Count only clients pg-pool drops after the connection itself failed — a plain idle
    // expiry during the stall must not count.
    type PgClient = import('events').EventEmitter;
    const pool = (ds.driver as unknown as { master: import('events').EventEmitter }).master;
    const failed = new WeakSet<PgClient>();
    const onAcquire = (client: PgClient) => {
      client.once('error', () => failed.add(client));
    };
    let removedAfterError = 0;
    const onRemove = (client: PgClient) => {
      if (failed.has(client)) removedAfterError++;
    };
    pool.on('acquire', onAcquire);
    pool.on('remove', onRemove);

    // Two at once, on different parts so neither queues on the other's row lock: both
    // pooled connections are the ones Postgres ends.
    const ids = [fresh('s-idle'), fresh('s-idle')];
    const started = Date.now();
    let stalled: request.Response[];
    try {
      stalled = await Promise.all(ids.map((id, i) => sell(fresh('k-idle'), id, `p${i + 1}`)));
    } finally {
      pool.off('acquire', onAcquire);
      pool.off('remove', onRemove);
    }
    const elapsed = Date.now() - started;
    console.log(
      `PROBE stalled bills: ${stalled.map((r) => r.status).join(',')} after ${elapsed} ms, ` +
        `${removedAfterError} clients dropped after an error`,
    );
    expect(stalled.map((r) => r.status)).toEqual([500, 500]);
    expect(elapsed).toBeLessThan(8000);
    for (const id of ids) expect(await saleCount(id)).toBe(0);
    expect(removedAfterError).toBe(2);

    vi.restoreAllMocks();
    await expectPoolServes();
  });

  it('a resend while the original still holds its claim answers 503 IDEMPOTENCY_KEY_IN_FLIGHT (lock_timeout fires before statement_timeout)', async () => {
    const key = fresh('k-inflight');
    // The original, stood in by the owner connection: an uncommitted claim row.
    const original = admin.createQueryRunner();
    await original.connect();
    let res: request.Response;
    let elapsed: number;
    try {
      await original.startTransaction();
      await original.query(
        `INSERT INTO idempotency_keys (tenant_id, key, endpoint, request_hash, status)
              VALUES ($1::uuid, $2, 'POST /api/v1/sales', 'x', 'in_progress')`,
        [TENANT, key],
      );
      const started = Date.now();
      res = await sell(key, fresh('s-inflight'));
      elapsed = Date.now() - started;
    } finally {
      if (original.isTransactionActive) await original.rollbackTransaction();
      await original.release();
    }
    console.log(`PROBE resend during the original: ${res.status} ${res.body?.error?.code} after ${elapsed} ms`);
    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe('IDEMPOTENCY_KEY_IN_FLIGHT');
    expect(elapsed).toBeGreaterThanOrEqual(4900);
    expect(elapsed).toBeLessThan(10_000);
    await expectPoolServes();
  });
});
