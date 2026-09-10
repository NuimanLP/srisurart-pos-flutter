import {
  Body,
  Controller,
  HttpCode,
  Module,
  Post,
  UseInterceptors,
  type INestApplication,
  type CallHandler,
  type ExecutionContext,
  type NestInterceptor,
} from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { pino } from 'pino';
import { lastValueFrom, of, type Observable } from 'rxjs';
import request from 'supertest';
import { DataSource, type QueryRunner } from 'typeorm';
import { AppModule } from '../src/app.module.js';
import { configureApp } from '../src/app.setup.js';
import { loadConfig } from '../src/config/config.js';
import { IdempotencyInterceptor } from '../src/idempotency/idempotency.interceptor.js';
import { IdempotencyModule } from '../src/idempotency/idempotency.module.js';
import { IdempotencyService } from '../src/idempotency/idempotency.service.js';
import {
  currentRequestContext,
  runInRequestContext,
} from '../src/common/request-context.js';

// #18 acceptance suite. Runs against the real compose Postgres and Redis as `pos_app`,
// with RLS on — no mocks, because the primary key and RLS ARE the mechanism under test.
const TENANT_A = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
const TENANT_B = 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb';

/**
 * Stands in for TenantGuard (#4), which does not exist yet: opens the request
 * transaction, applies `SET LOCAL app.tenant_id`, and publishes the context the
 * interceptor reads. Production has no equivalent — that is the point (nothing in
 * `src/` can reach tenant data until #4 lands).
 */
class StandInTenantGuard implements NestInterceptor {
  constructor(private readonly ds: DataSource) {}

  async intercept(
    context: ExecutionContext,
    next: CallHandler,
  ): Promise<Observable<unknown>> {
    const tenantId = context
      .switchToHttp()
      .getRequest<{ headers: Record<string, string> }>()
      .headers['x-test-tenant'];
    const qr = this.ds.createQueryRunner();
    await qr.connect();
    await qr.startTransaction();
    try {
      await qr.query(`SELECT set_config('app.tenant_id', $1, true)`, [tenantId]);
      const value = await runInRequestContext(
        { tenantId, manager: qr.manager },
        () => lastValueFrom(next.handle()),
      );
      await qr.commitTransaction();
      return of(value);
    } catch (err) {
      await qr.rollbackTransaction();
      throw err;
    } finally {
      await qr.release();
    }
  }
}

/** The "one trivial write endpoint" #18 asks to be proved against. */
@Controller('test-writes')
class TestWriteController {
  @Post()
  @UseInterceptors(IdempotencyInterceptor)
  async create(
    @Body() body: { note: string; slow?: boolean; fail?: boolean },
  ): Promise<Record<string, unknown>> {
    const { tenantId, manager } = currentRequestContext();
    // Holds the claim's row lock long enough that a second request really does
    // arrive mid-flight, instead of tidily after the first has committed.
    if (body.slow) await manager.query(`SELECT pg_sleep(0.4)`);
    await manager.query(
      `INSERT INTO audit_log (tenant_id, action, entity, after)
            VALUES ($1::uuid, 'system.test-write', 'test', $2::jsonb)`,
      [tenantId, JSON.stringify(body)],
    );
    if (body.fail) throw new Error('handler exploded after writing');
    // Echoes the body minus the control flags, so a test can hand it a multi-key
    // object and see what a replay does to key order.
    const { slow: _slow, fail: _fail, ...data } = body;
    return data;
  }
}

/** A second route, with a non-default status, so the replayed code is observable. */
@Controller('test-accepted')
class TestAcceptedController {
  @Post()
  @HttpCode(202)
  @UseInterceptors(IdempotencyInterceptor)
  async create(@Body() body: { note: string }): Promise<{ note: string }> {
    const { tenantId, manager } = currentRequestContext();
    await manager.query(
      `INSERT INTO audit_log (tenant_id, action, entity, after)
            VALUES ($1::uuid, 'system.test-write', 'test', $2::jsonb)`,
      [tenantId, JSON.stringify(body)],
    );
    return { note: body.note };
  }
}

@Module({
  imports: [IdempotencyModule],
  controllers: [TestWriteController, TestAcceptedController],
})
class TestWriteModule {}

describe('idempotency (e2e)', () => {
  let app: INestApplication;
  let ds: DataSource;

  const post = (tenant: string, key: string | undefined, body: unknown) => {
    const r = request(app.getHttpServer())
      .post('/api/v1/test-writes')
      .set('x-test-tenant', tenant);
    return (key === undefined ? r : r.set('Idempotency-Key', key)).send(
      body as object,
    );
  };

  /**
   * Runs `fn` as the tenant. `SET LOCAL` only lives inside a transaction, and the
   * pool hands out a different connection per query, so a bare `ds.query` after a
   * `set_config` would land on a connection with no tenant — and RLS, forced, would
   * answer zero rows. Every assertion about the database goes through here.
   */
  const asTenant = async <T>(
    tenant: string,
    fn: (qr: QueryRunner) => Promise<T>,
  ): Promise<T> => {
    const qr = ds.createQueryRunner();
    await qr.connect();
    await qr.startTransaction();
    try {
      await qr.query(`SELECT set_config('app.tenant_id', $1, true)`, [tenant]);
      const out = await fn(qr);
      await qr.commitTransaction();
      return out;
    } catch (err) {
      await qr.rollbackTransaction();
      throw err;
    } finally {
      await qr.release();
    }
  };

  /** How many times the handler actually ran for a tenant. */
  const effects = (tenant: string): Promise<number> =>
    asTenant(tenant, async (qr) => {
      const rows = (await qr.query(
        `SELECT count(*)::int AS n FROM audit_log
          WHERE tenant_id = $1::uuid AND action = 'system.test-write'`,
        [tenant],
      )) as { n: number }[];
      return rows[0].n;
    });

  beforeAll(async () => {
    const config = loadConfig({
      DATABASE_URL: 'postgres://pos_app:dev-only-pos-app@127.0.0.1:5432/pos',
      // The concurrency test needs three in-flight transactions at once; with a
      // smaller pool they would queue and prove nothing.
      DB_POOL_SIZE: '5',
      REDIS_CACHE_URL: 'redis://:dev-only-redis@127.0.0.1:6379',
      REDIS_QUEUE_URL: 'redis://:dev-only-redis@127.0.0.1:6380',
      JWT_PRIVATE_KEY: 'dummy',
      JWT_PUBLIC_KEYS: 'dummy',
      ...process.env,
    });
    const logger = pino({ level: 'silent' });
    const moduleRef = await Test.createTestingModule({
      imports: [AppModule.forRoot(config, logger), TestWriteModule],
    }).compile();
    app = moduleRef.createNestApplication();
    ds = app.get(DataSource);
    // Outermost, so it wraps the route-scoped IdempotencyInterceptor — the order
    // #4's guard will have for real, since guards run before interceptors.
    app.useGlobalInterceptors(new StandInTenantGuard(ds));
    await configureApp(app, logger);
  });

  afterAll(async () => {
    for (const t of [TENANT_A, TENANT_B]) {
      await asTenant(t, async (qr) => {
        await qr.query(
          `DELETE FROM audit_log WHERE tenant_id = $1::uuid AND action = 'system.test-write'`,
          [t],
        );
        await qr.query(`DELETE FROM idempotency_keys WHERE tenant_id = $1::uuid`, [t]);
      });
    }
    await app.close();
  });

  it('the same key five times → one effect and five equal responses', async () => {
    const before = await effects(TENANT_A);
    const key = `k-five-${Date.now()}`;
    // Several keys on purpose: a replay comes back through jsonb, which does not
    // preserve key order, so what is promised — and tested — is JSON equality, not
    // byte equality. A single-key body could not tell the two apart.
    const body = { note: 'five', total: 1250.5, ref: 'RC-001' };
    const responses = [];
    for (let i = 0; i < 5; i++) {
      responses.push(await post(TENANT_A, key, body));
    }
    for (const res of responses) {
      expect(res.status).toBe(201);
      expect(res.body).toEqual({ status: 'success', data: body });
    }
    expect(await effects(TENANT_A)).toBe(before + 1);
  });

  it('replays the original status, not the route default', async () => {
    const key = `k-202-${Date.now()}`;
    const send = () =>
      request(app.getHttpServer())
        .post('/api/v1/test-accepted')
        .set('x-test-tenant', TENANT_A)
        .set('Idempotency-Key', key)
        .send({ note: 'accepted' });
    expect((await send()).status).toBe(202);
    const replay = await send();
    expect(replay.status).toBe(202);
    expect(replay.body).toEqual({ status: 'success', data: { note: 'accepted' } });
  });

  it('the same key and body on a different endpoint replays nothing — 409', async () => {
    const key = `k-endpoint-${Date.now()}`;
    const body = { note: 'crossed' };
    await post(TENANT_A, key, body).expect(201);
    const before = await effects(TENANT_A);

    const res = await request(app.getHttpServer())
      .post('/api/v1/test-accepted')
      .set('x-test-tenant', TENANT_A)
      .set('Idempotency-Key', key)
      .send(body);

    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('IDEMPOTENCY_KEY_REUSED');
    expect(await effects(TENANT_A)).toBe(before);
  });

  it('the same key with a changed body → 409 IDEMPOTENCY_KEY_REUSED, no second effect', async () => {
    const key = `k-changed-${Date.now()}`;
    await post(TENANT_A, key, { note: 'original' }).expect(201);
    const before = await effects(TENANT_A);

    const res = await post(TENANT_A, key, { note: 'tampered' });
    expect(res.status).toBe(409);
    expect(res.body.status).toBe('error');
    expect(res.body.error.code).toBe('IDEMPOTENCY_KEY_REUSED');
    expect(await effects(TENANT_A)).toBe(before);
  });

  it('three genuinely concurrent requests with one key → one effect, all replayed alike', async () => {
    const before = await effects(TENANT_A);
    const key = `k-race-${Date.now()}`;
    const body = { note: 'race', slow: true };
    // The handler holds its transaction for 400ms, so the other two are inside the
    // primary key's wait, not merely after it — this is the contention path.
    const [a, b, c] = await Promise.all([
      post(TENANT_A, key, body),
      post(TENANT_A, key, body),
      post(TENANT_A, key, body),
    ]);
    for (const res of [a, b, c]) {
      expect(res.status).toBe(201);
      expect(res.body).toEqual({ status: 'success', data: { note: 'race' } });
    }
    expect(await effects(TENANT_A)).toBe(before + 1);
  });

  it('a key from tenant A is invisible to tenant B — both execute', async () => {
    const key = `k-shared-${Date.now()}`;
    const beforeA = await effects(TENANT_A);
    const beforeB = await effects(TENANT_B);

    await post(TENANT_A, key, { note: 'mine' }).expect(201);
    const res = await post(TENANT_B, key, { note: 'mine' });

    expect(res.status).toBe(201);
    expect(await effects(TENANT_A)).toBe(beforeA + 1);
    expect(await effects(TENANT_B)).toBe(beforeB + 1);
  });

  it('a record committed by a process that never answered is replayed, not re-run', async () => {
    // What a crash between COMMIT and the response leaves behind: the work and its
    // idempotency record are both committed, the client saw nothing and retries.
    const key = `k-crashed-${Date.now()}`;
    const body = { note: 'crashed' };
    const idempotency = app.get(IdempotencyService);
    await asTenant(TENANT_A, async (qr) => {
      await idempotency.claim(qr.manager, {
        tenantId: TENANT_A,
        key,
        // Exactly what the interceptor records for this route.
        endpoint: 'POST /api/v1/test-writes',
        requestHash: IdempotencyService.requestHash(body),
      });
      await qr.manager.query(
        `INSERT INTO audit_log (tenant_id, action, entity, after)
              VALUES ($1::uuid, 'system.test-write', 'test', $2::jsonb)`,
        [TENANT_A, JSON.stringify(body)],
      );
      await idempotency.complete(qr.manager, {
        tenantId: TENANT_A,
        key,
        response: { code: 201, body: { note: 'crashed' } },
      });
    });

    const before = await effects(TENANT_A);
    const res = await post(TENANT_A, key, body);
    expect(res.status).toBe(201);
    expect(res.body).toEqual({ status: 'success', data: { note: 'crashed' } });
    expect(await effects(TENANT_A)).toBe(before);
  });

  it('a failed request keeps no key, so the retry runs the work rather than replaying a failure', async () => {
    const key = `k-failed-${Date.now()}`;
    const before = await effects(TENANT_A);

    await post(TENANT_A, key, { note: 'boom', fail: true }).expect(500);
    // The claim rolled back with the work: the key is free again.
    expect(await effects(TENANT_A)).toBe(before);

    const retry = await post(TENANT_A, key, { note: 'boom' });
    expect(retry.status).toBe(201);
    expect(await effects(TENANT_A)).toBe(before + 1);
  });

  it('no Idempotency-Key → 400, and nothing is written', async () => {
    const before = await effects(TENANT_A);
    const res = await post(TENANT_A, undefined, { note: 'keyless' });
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('IDEMPOTENCY_KEY_INVALID');
    expect(await effects(TENANT_A)).toBe(before);
  });

  it('an oversized Idempotency-Key → 400, not a btree failure at 500', async () => {
    const before = await effects(TENANT_A);
    const res = await post(TENANT_A, 'x'.repeat(3000), { note: 'huge' });
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('IDEMPOTENCY_KEY_INVALID');
    expect(await effects(TENANT_A)).toBe(before);
  });
});
