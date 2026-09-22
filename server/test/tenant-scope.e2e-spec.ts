import {
  Controller,
  Get,
  Module,
  UseGuards,
  type INestApplication,
} from '@nestjs/common';
import type { Redis } from 'ioredis';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import { TenantService } from '../src/common/database/tenant.service.js';
import { TenantGuard } from '../src/common/guards/tenant.guard.js';
import { HEALTH_DATA_SOURCE } from '../src/infra/db.module.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  type TenantFixture,
} from './support/fixture.js';

/**
 * A controller no config file knows about: mounted from this test only, guarded like any
 * production controller, reading through `runTx`. Before tx.4 (#153) it would have needed an
 * entry in `app.module.ts`'s `TENANT_ROUTES`, or the guard found no transaction and 500'd.
 */
@Controller('tx4-probe')
@UseGuards(TenantGuard)
class Tx4ProbeController {
  constructor(private readonly tenants: TenantService) {}

  @Get()
  probe(): Promise<{ tenantId: string; users: number }> {
    return this.tenants.runTx(async (manager) => {
      const [row] = (await manager.query(
        `SELECT current_setting('app.tenant_id', true) AS "tenantId",
                (SELECT count(*)::int FROM users) AS users`,
      )) as { tenantId: string; users: number }[];
      return row;
    });
  }
}

/** The same read with no guard: `runTx` has no tenant to name, so it must refuse. */
@Controller('tx4-probe-unguarded')
class UnguardedProbeController {
  constructor(private readonly tenants: TenantService) {}

  @Get()
  probe(): Promise<unknown> {
    return this.tenants.runTx((manager) =>
      manager.query(`SELECT count(*)::int AS n FROM users`),
    );
  }
}

@Module({ controllers: [Tx4ProbeController, UnguardedProbeController] })
class Tx4ProbeModule {}

describe('the tenant scope without a request transaction (e2e, tx.4 #153)', () => {
  const TENANT = '15315315-5555-4555-8555-153153153153';

  let app: INestApplication;
  let ds: DataSource;
  let admin: DataSource;
  let cache: Redis;
  let fixture: TenantFixture;
  let token: string;

  beforeAll(async () => {
    ({ app, ds, admin, cache } = await createTestApp([Tx4ProbeModule]));
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { cache });
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

  const http = () => request(app.getHttpServer());

  it('a new TenantGuard controller works with no config entry: the guard names the tenant, runTx applies it', async () => {
    const res = await http()
      .get('/api/v1/tx4-probe')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.data.tenantId).toBe(TENANT);
    // RLS answered for this tenant: the fixture's manager is visible.
    expect(res.body.data.users).toBeGreaterThan(0);
  });

  it('the same read with no guard is refused, not answered for nobody', async () => {
    // Warm the rate limiter's plan cache, so the only runner that could appear is runTx's.
    await http()
      .get('/api/v1/tx4-probe')
      .set('Authorization', `Bearer ${token}`)
      .expect(200);
    const runners = vi.spyOn(ds, 'createQueryRunner');
    const res = await http()
      .get('/api/v1/tx4-probe-unguarded')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(500);
    expect(runners).not.toHaveBeenCalled();
  });

  it('a request the guard refuses takes no connection; a suspended shop is never named', async () => {
    const runners = vi.spyOn(ds, 'createQueryRunner');

    expect((await http().get('/api/v1/tx4-probe')).status).toBe(401);
    expect(
      (
        await http()
          .get('/api/v1/tx4-probe')
          .set('Authorization', 'Bearer not-a-token')
      ).status,
    ).toBe(401);
    expect(runners).not.toHaveBeenCalled();

    await admin.query(
      `UPDATE tenants SET status = 'suspended' WHERE id = $1::uuid`,
      [TENANT],
    );
    // Both caches cold, so the count below is exact rather than "at most".
    await cache.del(`t:${TENANT}:status`, `t:${TENANT}:plan`);
    runners.mockRestore();
    const original = ds.createQueryRunner.bind(ds);
    const seen: { sql: string[]; began: boolean }[] = [];
    const counted = vi
      .spyOn(ds, 'createQueryRunner')
      .mockImplementation(
        (...args: Parameters<DataSource['createQueryRunner']>) => {
          const qr = original(...args);
          const record = { sql: [] as string[], began: false };
          seen.push(record);
          const query = qr.query.bind(qr);
          qr.query = ((sql: string, ...rest: unknown[]) => {
            record.sql.push(sql);
            return (query as (...a: unknown[]) => unknown)(sql, ...rest);
          }) as typeof qr.query;
          const start = qr.startTransaction.bind(qr);
          qr.startTransaction = ((...a: Parameters<typeof start>) => {
            record.began = true;
            return start(...a);
          }) as typeof qr.startTransaction;
          return qr;
        },
      );
    const res = await http()
      .get('/api/v1/tx4-probe')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('TENANT_SUSPENDED');
    // Exactly two short pool reads — the rate limiter's `SELECT plan` and the guard's
    // `SELECT status` — and no transaction: no runTx runner, no `set_config` for the shop.
    expect(counted).toHaveBeenCalledTimes(2);
    expect(seen.map((r) => r.began)).toEqual([false, false]);
    expect(seen.flatMap((r) => r.sql).sort()).toEqual([
      'SELECT plan FROM tenants WHERE id = $1',
      'SELECT status FROM tenants WHERE id = $1',
    ]);
    expect(
      seen.flatMap((r) => r.sql).some((s) => s.includes('set_config')),
    ).toBe(false);
    await admin.query(
      `UPDATE tenants SET status = 'active' WHERE id = $1::uuid`,
      [TENANT],
    );
  });

  // #383: the test that used to live here only `vi.spyOn`'d `cache.get`/`cache.set`
  // to reject — proving the guard's own `catch` runs, not that the app survives a
  // `redis-cache` that is genuinely unreachable — and hit this file's internal
  // `/tx4-probe` route rather than the `GET /products` + `POST /sales` (with a real
  // stock decrement) that #294's AC names. Real coverage, with `redis-cache`
  // actually unreachable two different ways, now lives in
  // `redis-cache-outage.e2e-spec.ts`.

  it('/health/live touches no Postgres connection and /health/ready exactly one, off the request pool', async () => {
    const runners = vi.spyOn(ds, 'createQueryRunner');
    const healthRunners = vi.spyOn(
      app.get<DataSource>(HEALTH_DATA_SOURCE),
      'createQueryRunner',
    );

    expect((await http().get('/health/live')).status).toBe(200);
    expect(runners).toHaveBeenCalledTimes(0);
    expect(healthRunners).toHaveBeenCalledTimes(0);

    expect((await http().get('/health/ready')).status).toBe(200);
    // `SELECT 1` through `DataSource.query`, which takes one runner — from the probe's own
    // pool of one, never the request pool (#248, `health-pool.e2e-spec.ts`).
    expect(healthRunners).toHaveBeenCalledTimes(1);
    expect(runners).toHaveBeenCalledTimes(0);
  });
});
