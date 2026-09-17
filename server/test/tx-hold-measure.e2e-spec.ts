import type { INestApplication } from '@nestjs/common';
import type { Redis } from 'ioredis';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedOpenShift,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';

// tx.4 (#153) AC2: how long does a `pos_app` transaction stay open? ADR-0003's addendum
// measured it on the prototype — 4 concurrent voids at `DB_POOL_SIZE=2`, longest transaction
// Postgres saw: 112–116 ms with the request-wide transaction, 18–28 ms handler-scoped.
//
// A measurement, not a gate: machine speed decides the numbers, so it asserts nothing about
// them and is skipped unless asked for. Run it on two checkouts and compare:
//
//   MEASURE_TX_HOLD=1 pnpm test:e2e test/tx-hold-measure.e2e-spec.ts
//
// Method: a superuser connection samples `pg_stat_activity` in a tight loop while the burst
// runs and keeps the largest `clock_timestamp() - xact_start` of any `pos_app` backend. The
// sample period (one round trip, ~1 ms) bounds how far the maximum can be under-read. The
// run needs no compose `worker` up — the app pool sets no `application_name` to filter on.
describe.skipIf(!process.env.MEASURE_TX_HOLD)(
  'longest pos_app transaction under a burst (measurement, #153)',
  () => {
    const TENANT = '15315315-4444-4444-8444-153153153153';
    const PIN = '1534';
    const ROUNDS = 5;

    let app: INestApplication;
    let admin: DataSource;
    let cache: Redis;
    let fixture: TenantFixture;
    let token: string;
    let seq = 0;

    beforeAll(async () => {
      const before = process.env.DB_POOL_SIZE;
      process.env.DB_POOL_SIZE = '2';
      try {
        ({ app, admin, cache } = await createTestApp());
      } finally {
        if (before === undefined) delete process.env.DB_POOL_SIZE;
        else process.env.DB_POOL_SIZE = before;
      }
      fixture = await resetTenant(admin, TENANT, { pin: PIN, cache });
      token = accessToken({
        tenantId: TENANT,
        userId: fixture.userId,
        role: 'owner',
        deviceId: fixture.posDeviceId,
        deviceRole: 'pos',
      });
      await seedProduct(admin, TENANT, {
        id: 'p1',
        partNo: 'OF-1',
        name: 'Oil Filter',
        price: 85,
        cost: 50,
        stock: 100000,
      });
      await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
        userId: fixture.userId,
      });
    });

    afterAll(async () => {
      await resetTenant(admin, TENANT, { cache });
      await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
      await app.close();
    });

    const post = (path: string, body: object) =>
      request(app.getHttpServer())
        .post(`/api/v1${path}`)
        .set('Authorization', `Bearer ${token}`)
        .set('Idempotency-Key', `k-153-${++seq}-${Date.now()}`)
        .send(body);

    const sale = () =>
      post('/sales', {
        id: `s-153-${++seq}-${Date.now()}`,
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
            qty: 1,
            price: '85.00',
          },
        ],
      });

    /** Runs `burst` while sampling; returns the longest transaction seen and each latency. */
    const measure = async (
      burst: () => Promise<{ status: number; ms: number }[]>,
    ) => {
      let longest = 0;
      let samples = 0;
      let done = false;
      const sampler = (async () => {
        while (!done) {
          const rows = (await admin.query(
            `SELECT coalesce(max(extract(epoch FROM clock_timestamp() - xact_start)) * 1000, 0)::float AS ms
               FROM pg_stat_activity
              WHERE usename = 'pos_app' AND datname = current_database()
                AND xact_start IS NOT NULL`,
          )) as { ms: number }[];
          longest = Math.max(longest, rows[0].ms);
          samples++;
        }
      })();
      const started = Date.now();
      const results = await burst();
      const wall = Date.now() - started;
      done = true;
      await sampler;
      return { longest, samples, wall, results };
    };

    const timed = async (req: () => PromiseLike<{ status: number }>) => {
      const t = Date.now();
      const r = await req();
      return { status: r.status, ms: Date.now() - t };
    };

    const report = (
      label: string,
      rounds: Awaited<ReturnType<typeof measure>>[],
    ) => {
      for (const [i, r] of rounds.entries()) {
        console.log(
          `MEASURE ${label} round ${i + 1}: longest tx ${r.longest.toFixed(1)} ms, ` +
            `wall ${r.wall} ms, latencies ${r.results
              .map((x) => x.ms)
              .sort((a, b) => a - b)
              .join('/')} ms, ` +
            `statuses ${r.results.map((x) => x.status).join(',')}, ${r.samples} samples`,
        );
      }
      const longest = rounds.map((r) => r.longest).sort((a, b) => a - b);
      console.log(
        `MEASURE ${label} longest tx over ${rounds.length} rounds: ` +
          `min ${longest[0].toFixed(1)} / median ${longest[Math.floor(longest.length / 2)].toFixed(1)} / ` +
          `max ${longest[longest.length - 1].toFixed(1)} ms`,
      );
    };

    it('4 concurrent voids at DB_POOL_SIZE=2', async () => {
      // Warm-up: status and plan caches, argon2's first call, the JIT.
      const warm = await sale();
      expect(warm.status).toBe(201);
      expect(
        (await post(`/sales/${warm.body.data.id}/void`, { reason: 'Return' })).status,
      ).toBe(200);

      const rounds = [];
      for (let round = 0; round < ROUNDS; round++) {
        const ids: string[] = [];
        for (let i = 0; i < 4; i++) {
          const r = await sale();
          expect(r.status).toBe(201);
          ids.push(r.body.data.id as string);
        }
        rounds.push(
          await measure(() =>
            Promise.all(
              ids.map((id) =>
                timed(() => post(`/sales/${id}/void`, { reason: 'Return' })),
              ),
            ),
          ),
        );
      }
      report('void x4 pool2', rounds);
      for (const r of rounds)
        expect(r.results.map((x) => x.status)).toEqual([200, 200, 200, 200]);
    });

    it('4 concurrent POST /sales at DB_POOL_SIZE=2 (no argon2 on the path)', async () => {
      expect((await sale()).status).toBe(201);
      const rounds = [];
      for (let round = 0; round < ROUNDS; round++) {
        rounds.push(
          await measure(() =>
            Promise.all(Array.from({ length: 4 }, () => timed(sale))),
          ),
        );
      }
      report('sale x4 pool2', rounds);
      for (const r of rounds)
        expect(r.results.map((x) => x.status)).toEqual([201, 201, 201, 201]);
    });
  },
);
