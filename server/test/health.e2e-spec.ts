import { Test } from '@nestjs/testing';
import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { pino } from 'pino';
import { AppModule } from '../src/app.module.js';
import { configureApp } from '../src/app.setup.js';
import { loadConfig } from '../src/config/config.js';

// Runs against the real compose stack — no mocks. The datastore ports live on 127.0.0.1
// only through docker-compose.dev.yml; the defaults below match server/.env.example.
describe('health (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    const config = loadConfig({
      DATABASE_URL: 'postgres://pos_app:dev-only-pos-app@127.0.0.1:5432/pos',
      REDIS_CACHE_URL: 'redis://:dev-only-redis@127.0.0.1:6379',
      REDIS_QUEUE_URL: 'redis://:dev-only-redis@127.0.0.1:6380',
      ...process.env,
    });
    const logger = pino({ level: 'silent' });
    const moduleRef = await Test.createTestingModule({
      imports: [AppModule.forRoot(config, logger)],
    }).compile();
    app = moduleRef.createNestApplication();
    await configureApp(app, logger);
  });

  afterAll(async () => {
    await app.close();
  });

  it('GET /health/live → 200 success envelope, outside /api/v1', async () => {
    const res = await request(app.getHttpServer())
      .get('/health/live')
      .expect(200);
    expect(res.body).toEqual({ status: 'success', data: { status: 'up' } });
  });

  it('GET /health/ready → 200 with every dependency up', async () => {
    const res = await request(app.getHttpServer())
      .get('/health/ready')
      .expect(200);
    expect(res.body.data.checks).toEqual({
      postgres: 'up',
      redisCache: 'up',
      redisQueue: 'up',
    });
  });

  it('echoes X-Correlation-ID and generates one when absent', async () => {
    const given = await request(app.getHttpServer())
      .get('/health/live')
      .set('X-Correlation-ID', 'corr-123');
    expect(given.headers['x-correlation-id']).toBe('corr-123');
    const generated = await request(app.getHttpServer()).get('/health/live');
    expect(generated.headers['x-correlation-id']).toMatch(/^[0-9a-f-]{36}$/);
  });

  it('unknown route → 404 error envelope', async () => {
    const res = await request(app.getHttpServer())
      .get('/api/v1/nope')
      .expect(404);
    expect(res.body.status).toBe('error');
    expect(res.body.error.code).toBe('NOT_FOUND');
  });
});
