import { Body, Controller, Get, Module, Post, Req, type INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import type { Request } from 'express';
import pino from 'pino';
import request from 'supertest';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { configureApp } from './app.setup.js';
import { signJwt } from './common/jwt.js';
import { APP_CONFIG } from './config/config.js';

@Controller('probe')
class IpProbeController {
  @Get('ip')
  ip(@Req() req: Request) {
    return { ip: req.ip };
  }
}

@Module({ controllers: [IpProbeController] })
class ProbeModule {}

describe('configureApp trust proxy', () => {
  let app: INestApplication;

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({ imports: [ProbeModule] }).compile();
    app = moduleRef.createNestApplication();
    await configureApp(app, pino({ level: 'silent' }));
  });

  afterAll(async () => {
    await app.close();
  });

  const ipFor = async (xff: string) =>
    (await request(app.getHttpServer()).get('/api/v1/probe/ip').set('X-Forwarded-For', xff))
      .body.data.ip;

  it('takes the entry nginx appended, not the one the client wrote', async () => {
    expect(await ipFor('1.1.1.1, 10.0.0.5')).toBe('10.0.0.5');
  });

  it('gives two clients behind the same nginx different addresses', async () => {
    expect(await ipFor('10.0.0.5')).not.toBe(await ipFor('10.0.0.6'));
  });
});

@Controller('platform/tenants/:id')
class ImportProbeController {
  @Post('import')
  import(@Body() body: { blob?: string }) {
    return { length: body?.blob?.length ?? 0 };
  }
}

@Controller('probe')
class BodyProbeController {
  @Post('body')
  body(@Body() body: { blob?: string }) {
    return { length: body?.blob?.length ?? 0 };
  }
}

const PLATFORM_SECRET = 'app-setup-spec-platform-secret';

@Module({
  controllers: [ImportProbeController, BodyProbeController],
  providers: [{ provide: APP_CONFIG, useValue: { jwtPlatformSecret: PLATFORM_SECRET, corsOrigins: [] } }],
})
class BodyProbeModule {}

// #185 / review of #244: the import route's 10 MiB parser, and the envelope for oversize bodies.
describe('configureApp body limits', () => {
  let app: INestApplication;
  const big = { blob: 'x'.repeat(200 * 1024) };
  const platformToken = signJwt({ iss: 'srisurart-pos', aud: 'platform', sub: 'adm1', username: 'admin' }, PLATFORM_SECRET);
  const importPost = () => request(app.getHttpServer()).post('/api/v1/platform/tenants/t1/import');

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({ imports: [BodyProbeModule] }).compile();
    app = moduleRef.createNestApplication();
    await configureApp(app, pino({ level: 'silent' }));
  });

  afterAll(async () => {
    await app.close();
  });

  it('parses a large import body that carries a verified platform token', async () => {
    const res = await importPost().set('Authorization', `Bearer ${platformToken}`).send(big);
    expect(res.status).toBe(201);
    expect(res.body.data.length).toBe(big.blob.length);
  });

  it('does not give an anonymous import the large limit, and answers 413 not 500', async () => {
    const res = await importPost().send(big);
    expect(res.status).toBe(413);
    expect(res.body.error.code).toBe('PAYLOAD_TOO_LARGE');
  });

  it('does not give an unverified bearer token the large limit', async () => {
    expect((await importPost().set('Authorization', 'Bearer x').send(big)).status).toBe(413);
    const forged = signJwt({ aud: 'platform', sub: 'adm1' }, 'not-the-secret');
    expect((await importPost().set('Authorization', `Bearer ${forged}`).send(big)).status).toBe(413);
    const tenantAudience = signJwt({ aud: 'tenant', sub: 'u1' }, PLATFORM_SECRET);
    expect((await importPost().set('Authorization', `Bearer ${tenantAudience}`).send(big)).status).toBe(413);
  });

  it('keeps every other route on the default limit and still parses its bodies', async () => {
    expect((await request(app.getHttpServer()).post('/api/v1/probe/body').set('Authorization', `Bearer ${platformToken}`).send(big)).status).toBe(413);
    const small = await request(app.getHttpServer()).post('/api/v1/probe/body').send({ blob: 'abc' });
    expect(small.status).toBe(201);
    expect(small.body.data.length).toBe(3);
  });
});
