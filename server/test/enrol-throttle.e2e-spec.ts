import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import { windowKey } from '../src/rate-limit/rate-limit.service.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  type TenantFixture,
} from './support/fixture.js';

// Security review 2026-10-21: `POST /auth/device` had no throttle, while an enrolment code is
// 8 hex characters (32 bits), lives up to 7 days, is looked up across every tenant, and buys a
// device token that can push owner writes through `/sync/push`. Now: 10 attempts per IP per
// 60 s, and 100 failed attempts per 600 s across ALL IPs — after that everyone gets 429.
//
// Every request sends its own `X-Forwarded-For` (CLAUDE.md, #449): the buckets live in the
// Redis every e2e file shares. The all-IP bucket is reset around each case so it never
// refuses another suite's enrolment.
const TENANT = '15515515-5555-4155-8155-155155155155';
const GLOBAL_KEY = 'auth:enrol:global';
const GLOBAL_WINDOW_SEC = 600;
// A random /24 per run in the benchmark range, so a re-run never inherits a full bucket.
const NET = `198.18.${Math.floor(Math.random() * 250) + 1}`;

describe('POST /auth/device throttle (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;
  let keySeq = 0;

  const enrol = (ip: string, code: string) =>
    request(app.getHttpServer())
      .post('/api/v1/auth/device')
      .set('X-Forwarded-For', ip)
      .send({ code });

  /** 8 hex characters that are (almost surely) nobody's code. */
  const wrongCode = () =>
    Math.floor(Math.random() * 0xffffffff)
      .toString(16)
      .padStart(8, '0');

  const resetGlobalBucket = async () => {
    await cache.del(windowKey(GLOBAL_KEY, GLOBAL_WINDOW_SEC));
  };

  /** Waits out a window that would roll over while this case is still counting. */
  const awaitRoomInWindow = async (windowSec: number, needSec: number) => {
    const left = windowSec - (Math.floor(Date.now() / 1000) % windowSec);
    if (left < needSec) await new Promise((r) => setTimeout(r, (left + 1) * 1000));
  };

  const newEnrolCode = async (): Promise<string> => {
    const res = await request(app.getHttpServer())
      .post('/api/v1/devices')
      .set(
        'Authorization',
        `Bearer ${accessToken({
          tenantId: TENANT,
          userId: fixture.userId,
          role: 'owner',
          deviceId: fixture.backofficeDeviceId,
          deviceRole: 'backoffice',
        })}`,
      )
      .set('Idempotency-Key', `k-enrol-throttle-${++keySeq}-${Date.now()}`)
      .send({ label: `throttle ${keySeq}`, role: 'backoffice' });
    expect(res.status).toBe(201);
    return res.body.data.enrolCode as string;
  };

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { cache });
    await resetGlobalBucket();
  });

  afterEach(async () => {
    await resetGlobalBucket();
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it('refuses the 11th attempt from one IP within a minute with 429 RATE_LIMITED + Retry-After; another IP is unaffected', async () => {
    await awaitRoomInWindow(60, 15);
    const ip = `${NET}.1`;
    for (let i = 0; i < 10; i++) {
      expect((await enrol(ip, wrongCode())).status).toBe(401);
    }
    const refused = await enrol(ip, wrongCode());
    expect(refused.status).toBe(429);
    expect(refused.body.error.code).toBe('RATE_LIMITED');
    expect(Number(refused.headers['retry-after'])).toBeGreaterThan(0);

    // Even the right code is refused from that IP until the window rolls over…
    const code = await newEnrolCode();
    expect((await enrol(ip, code)).status).toBe(429);
    // …while the same code still works from another address.
    expect((await enrol(`${NET}.2`, code)).status).toBe(200);
  });

  it('a successful enrolment gives its own attempt back: 9 wrong + 1 right + 1 wrong from one IP are all answered', async () => {
    await awaitRoomInWindow(60, 15);
    const ip = `${NET}.3`;
    for (let i = 0; i < 9; i++) {
      expect((await enrol(ip, wrongCode())).status).toBe(401);
    }
    expect((await enrol(ip, await newEnrolCode())).status).toBe(200);
    expect((await enrol(ip, wrongCode())).status).toBe(401);
  });

  it('100 failures spread over many IPs refuse every caller with 429, even with a valid code', async () => {
    await awaitRoomInWindow(GLOBAL_WINDOW_SEC, 30);
    const code = await newEnrolCode();
    // 20 addresses × 5 wrong codes: no single IP comes near its own limit of 10.
    for (let n = 0; n < 20; n++) {
      for (let i = 0; i < 5; i++) {
        expect((await enrol(`${NET}.${10 + n}`, wrongCode())).status).toBe(401);
      }
    }
    const fresh = await enrol(`${NET}.200`, code);
    expect(fresh.status).toBe(429);
    expect(fresh.body.error.code).toBe('RATE_LIMITED');
    expect(Number(fresh.headers['retry-after'])).toBeGreaterThan(0);

    // Once the cap is lifted, the code — never consumed by the refusal — still enrols.
    await resetGlobalBucket();
    expect((await enrol(`${NET}.201`, code)).status).toBe(200);
  });
});
