import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource, QueryRunner } from 'typeorm';
import { HEALTH_DATA_SOURCE } from '../src/infra/db.module.js';
import { createTestApp } from './support/fixture.js';

// #248: under the 500-VU demo run a Prometheus scrape got `503 NOT_READY {postgres: down}`
// from a healthy Postgres. `/health/ready`'s `SELECT 1` borrowed from the request pool, so
// once every slot was held by a real request the probe queued, the 2 s probe timeout
// tripped, and a busy database read as a dead one — to Prometheus, and to `deploy.yml`'s
// readiness gate after a rolling restart under traffic.
describe('readiness is not the request pool (e2e, #248)', () => {
  const POOL = 2;

  let app: INestApplication;
  let ds: DataSource;
  let health: DataSource;

  beforeAll(async () => {
    // Same seam as void-denial-pool.e2e-spec.ts: the fixture spreads process.env last.
    const before = process.env.DB_POOL_SIZE;
    process.env.DB_POOL_SIZE = String(POOL);
    try {
      ({ app, ds } = await createTestApp());
      health = app.get<DataSource>(HEALTH_DATA_SOURCE);
    } finally {
      if (before === undefined) delete process.env.DB_POOL_SIZE;
      else process.env.DB_POOL_SIZE = before;
    }
  });

  afterAll(async () => {
    await app.close();
  });

  const ready = () => request(app.getHttpServer()).get('/health/ready');

  it('answers 200 while every request-pool connection is held', async () => {
    // Hold every slot the way in-flight requests do: a checked-out connection each.
    const held: QueryRunner[] = [];
    for (let i = 0; i < POOL; i++) {
      const qr = ds.createQueryRunner();
      await qr.connect();
      held.push(qr);
    }
    try {
      // Postgres itself is fine: a held connection still answers at once.
      expect(await held[0].query('SELECT 1 AS ok')).toEqual([{ ok: 1 }]);

      const started = Date.now();
      const res = await ready();
      const ms = Date.now() - started;
      expect(res.status).toBe(200);
      expect(res.body.data.checks.postgres).toBe('up');
      expect(ms).toBeLessThan(1000);
    } finally {
      await Promise.all(held.map((qr) => qr.release()));
    }
  });

  it('probes on a pos_app pool of its own whose query the server ends at 2 s', async () => {
    expect(await health.query('SELECT current_user AS u')).toEqual([
      { u: 'pos_app' },
    ]);
    expect(await health.query('SHOW statement_timeout')).toEqual([
      { statement_timeout: '2s' },
    ]);
  });

  it('still answers 503 postgres: down when the probe cannot get a connection', async () => {
    // The health pool's only slot, held: the probe's connect times out exactly as it does
    // when Postgres does not accept connections.
    const qr = health.createQueryRunner();
    await qr.connect();
    try {
      const res = await ready();
      expect(res.status).toBe(503);
      expect(res.body.error.code).toBe('NOT_READY');
      expect(res.body.error.details.postgres).toBe('down');
    } finally {
      await qr.release();
    }
    expect((await ready()).status).toBe(200);
  });

  it('still answers 503 postgres: down when the probe query fails', async () => {
    // Last: the pool is gone, so every `SELECT 1` rejects. DbModule's destroy skips it.
    await health.destroy();
    const res = await ready();
    expect(res.status).toBe(503);
    expect(res.body.error.details).toEqual({
      postgres: 'down',
      redisCache: 'up',
      redisQueue: 'up',
    });
  });
});
