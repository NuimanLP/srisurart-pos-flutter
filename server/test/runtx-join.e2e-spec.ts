import type { INestApplication } from '@nestjs/common';
import type { Redis } from 'ioredis';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import {
  runInTenantScope,
  setRequestTenant,
} from '../src/common/request-context.js';
import { DevicesService } from '../src/devices/devices.service.js';
import { VoidService } from '../src/sales/void.service.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedOpenShift,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';

// tx.2 (#151): every service now opens its own `TenantService.runTx`, and each one must
// JOIN the transaction already open rather than take a second pooled connection. Two
// call chains nest for real: `VoidService.void → SaleReadsService.byId` and
// `DevicesService.retire → ShiftsService.closeForRetirement → ShiftsService.close`.
//
// Two ways of seeing a second connection, because they fail differently:
//   - `pg_stat_activity`: while the request is parked on a row lock this suite holds, at
//     most one `pos_app` backend has a transaction open. It sees the connections, but only
//     up to the point the request is parked at.
//   - a spy on the app pool's `createQueryRunner`: counts every connection the whole
//     request asked for, including the nested reads after the lock (`byId`, `close()`).
// And two shapes: over HTTP, where (since tx.4 #153) the route's `runIdempotent` opens the
// outer transaction, and called directly with no HTTP at all, where the service's OUTER
// `runTx` opens it. In both only the nested calls can join it.
describe('runTx joins the open transaction instead of taking a second connection (e2e, #151)', () => {
  const TENANT = '15115115-2222-4222-8222-151151151151';
  const PIN = '1511';

  let app: INestApplication;
  let ds: DataSource;
  let admin: DataSource;
  let cache: Redis;
  let fixture: TenantFixture;
  let managerToken: string;
  let ownerToken: string;
  let keySeq = 0;

  beforeAll(async () => {
    ({ app, ds, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { pin: PIN, cache });
    const claims = {
      tenantId: TENANT,
      userId: fixture.userId,
      deviceId: fixture.posDeviceId,
      deviceRole: 'pos' as const,
    };
    managerToken = accessToken({ ...claims, role: 'owner' });
    ownerToken = accessToken({ ...claims, role: 'owner' });
    await seedProduct(admin, TENANT, {
      id: 'p1',
      partNo: 'OF-1',
      name: 'Oil Filter',
      price: 85,
      cost: 50,
      stock: 40,
    });
    await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
      userId: fixture.userId,
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  const post = (path: string, body: object, token: string) =>
    request(app.getHttpServer())
      .post(`/api/v1${path}`)
      .set('Authorization', `Bearer ${token}`)
      .set('Idempotency-Key', `k-runtx-${++keySeq}-${Date.now()}`)
      .send(body);

  const ringUp = async (): Promise<string> => {
    const res = await post(
      '/sales',
      {
        id: `s-runtx-${++keySeq}-${Date.now()}`,
        subtotal: '85.00',
        discount: '0.00',
        total: '85.00',
        paymentMethod: 'เงินสด',
        items: [
          {
            lineNo: 1,
            productId: 'p1',
            partNo: 'OF-1',
            name: 'Oil Filter',
            nameTH: 'Oil Filter',
            qty: 1,
            price: '85.00',
          },
        ],
      },
      managerToken,
    );
    expect(res.status).toBe(201);
    return res.body.data.id as string;
  };

  /**
   * `pos_app` backends with a transaction open, seen from the superuser pool (so the
   * observer never counts itself). The app pool sets no `application_name` to filter on:
   * this counts every `pos_app` transaction in the database, so a compose `worker` running
   * a job against the same Postgres during the sample would read as a false red. Run the
   * e2e suite without the compose `worker` up (CI starts only Postgres and both Redis).
   */
  const posAppTransactions = async () =>
    (await admin.query(
      `SELECT pid, state, wait_event_type FROM pg_stat_activity
        WHERE usename = 'pos_app' AND datname = current_database()
          AND xact_start IS NOT NULL`,
    )) as { pid: number; state: string; wait_event_type: string | null }[];

  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

  /**
   * Holds `lockSql` in a superuser transaction, runs `fire`, waits until a `pos_app`
   * backend is parked on that lock, and returns the most `pos_app` transactions seen
   * over a few samples while it stays parked. The lock is released and the request given
   * a short while to finish before returning; it is handed back as `pending` so the count
   * is asserted first — a broken join on the retire chain self-deadlocks after the lock (a
   * second connection waiting on the row the first holds) and would otherwise surface only
   * as a test timeout.
   */
  const whileParked = async <T>(
    lockSql: string,
    params: unknown[],
    fire: () => Promise<T>,
  ): Promise<{ most: number; pending: Promise<T> }> => {
    const holder = admin.createQueryRunner();
    await holder.connect();
    let pending: Promise<T> | undefined;
    try {
      await holder.startTransaction();
      await holder.query(lockSql, params);
      pending = fire();
      let settled: { value: unknown } | undefined;
      pending.then(
        (value) => (settled = { value }),
        (value) => (settled = { value }),
      );
      const deadline = Date.now() + 10_000;
      while (
        !(await posAppTransactions()).some((r) => r.wait_event_type === 'Lock')
      ) {
        // A request refused before it reaches the lock (a 4xx) must say so, not wait out
        // the deadline and report "never parked".
        if (settled) {
          const r = settled.value as { status?: number; body?: unknown };
          throw new Error(
            `the request finished before it parked on the lock: ${r?.status ?? ''} ${JSON.stringify(r?.body ?? r)}`,
          );
        }
        if (Date.now() > deadline)
          throw new Error('the request never parked on the lock');
        await sleep(20);
      }
      let most = 0;
      for (let i = 0; i < 5; i++) {
        most = Math.max(most, (await posAppTransactions()).length);
        await sleep(20);
      }
      return { most, pending };
    } finally {
      try {
        if (holder.isTransactionActive) await holder.commitTransaction();
      } finally {
        await holder.release();
      }
      // Let the request finish before any assertion can fail, so its connection is back in
      // the pool for the next hooks. Bounded: a self-deadlocked request never finishes.
      if (pending)
        await Promise.race([pending.catch(() => undefined), sleep(2_000)]);
    }
  };

  /**
   * Spies on the app pool and refuses a second query runner outright, so a nested
   * `runTx` that fails to join is reported as exactly that instead of as a hang.
   */
  const refuseSecondRunner = () => {
    const original = ds.createQueryRunner.bind(ds);
    let calls = 0;
    return vi
      .spyOn(ds, 'createQueryRunner')
      .mockImplementation(
        (...args: Parameters<DataSource['createQueryRunner']>) => {
          if (++calls > 1) {
            throw new Error(
              'a second query runner was requested while the first is held',
            );
          }
          return original(...args);
        },
      );
  };

  /** A tenant scope with no transaction — what `TenantScopeMiddleware` + the guard give tx.4. */
  const inTenantScope = <T>(fn: () => Promise<T>): Promise<T> =>
    runInTenantScope(async () => {
      setRequestTenant(TENANT);
      return fn();
    });

  it('POST /sales/:id/void: one pos_app transaction while parked; one query runner — claim + void → byId', async () => {
    const saleId = await ringUp();
    // Records each runner's creation and release, in order.
    const events: string[] = [];
    const original = ds.createQueryRunner.bind(ds);
    vi.spyOn(ds, 'createQueryRunner').mockImplementation(
      (...args: Parameters<DataSource['createQueryRunner']>) => {
        const n = events.filter((e) => e.startsWith('create')).length + 1;
        events.push(`create${n}`);
        const qr = original(...args);
        const release = qr.release.bind(qr);
        qr.release = async () => {
          events.push(`release${n}`);
          return release();
        };
        return qr;
      },
    );

    const { most, pending } = await whileParked(
      `SELECT id FROM sales WHERE tenant_id = $1::uuid AND id = $2 FOR UPDATE`,
      [TENANT, saleId],
      () =>
        post(`/sales/${saleId}/void`, { reason: 'Customer returned items' }, managerToken).then(
          (r) => r,
        ),
    );
    expect(most).toBe(1);

    const result = await pending;
    expect(events).toEqual(['create1', 'release1']);
    expect(result.status).toBe(200);
    expect(result.body.data.voided).toBe(true);
    // `byId` ran after the lock: it read the uncommitted void on the same connection.
    expect(result.body.data.items).toHaveLength(1);
  });

  it('POST /devices/:id/retire: one pos_app transaction while parked, one query runner (retire → closeForRetirement → close)', async () => {
    // Warm the guards' status and plan caches, as `ringUp` does for the void case. Since
    // tx.4 (#153) a cold cache is read on the pool — one short runner each, returned before
    // the handler's `runTx` takes the request's connection — and this case counts only the
    // handler's runners.
    await request(app.getHttpServer())
      .get('/api/v1/devices')
      .set('Authorization', `Bearer ${ownerToken}`)
      .expect(200);
    const runners = vi.spyOn(ds, 'createQueryRunner');

    // `closeForRetirement` locks the drawer row; `close()` runs after it.
    const { most, pending } = await whileParked(
      `SELECT id FROM shifts WHERE tenant_id = $1::uuid AND device_id = $2 FOR UPDATE`,
      [TENANT, fixture.posDeviceId],
      () =>
        post(
          `/devices/${fixture.posDeviceId}/retire`,
          { physicalCash: '0.00' },
          ownerToken,
        ).then((r) => r),
    );
    expect(most).toBe(1);

    const result = await pending;
    expect(runners).toHaveBeenCalledTimes(1);
    expect(result.status).toBe(200);
    expect(result.body.data.shift.closedAt).not.toBeNull();
  });

  it('with no request transaction (the tx.4 shape), the outer runTx opens one and void → byId joins it', async () => {
    const saleId = await ringUp();
    const voids = app.get(VoidService);
    const runners = refuseSecondRunner();

    const voided = await inTenantScope(() =>
      voids.void(saleId, {
        userId: fixture.userId,
        role: 'owner',
        deviceId: fixture.posDeviceId,
        reason: 'Customer return',
      }),
    );

    expect(voided.voided).toBe(true);
    expect(voided.items).toHaveLength(1);
    expect(runners).toHaveBeenCalledTimes(1);
    const rows = await admin.query(
      `SELECT voided FROM sales WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, saleId],
    );
    expect(rows[0].voided).toBe(true);
  });

  it('with no request transaction (the tx.4 shape), retire → closeForRetirement → close share one runner', async () => {
    const devices = app.get(DevicesService);
    const runners = refuseSecondRunner();

    const retired = await inTenantScope(() =>
      devices.retire({ userId: fixture.userId }, fixture.posDeviceId, 0),
    );

    expect(retired.device.retiredAt).not.toBeNull();
    expect(retired.shift?.closedAt).not.toBeNull();
    expect(runners).toHaveBeenCalledTimes(1);
    const rows = await admin.query(
      `SELECT closed_at, is_active FROM shifts WHERE tenant_id = $1::uuid AND device_id = $2`,
      [TENANT, fixture.posDeviceId],
    );
    expect(rows).toHaveLength(1);
    expect(rows[0].closed_at).not.toBeNull();
    expect(rows[0].is_active).toBe(false);
  });
});
