import { randomUUID } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { INestApplication } from '@nestjs/common';
import type { Redis } from 'ioredis';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import { hashPassword } from '../src/common/password.js';
import {
  accessToken,
  createTestApp,
  refreshToken,
  resetTenant,
  seedCustomer,
  seedMechanic,
  seedOpenShift,
  seedProduct,
  seedSettings,
  type TenantFixture,
} from './support/fixture.js';

/**
 * Client → server REQUEST contract (ci/server-contract-gates, 2026-10-03).
 *
 * On 2026-10-03 the till sent `POST /quotes/:id/convert` with no body while the server
 * required one: a 400, and the screen did nothing. Both sides' unit tests were green,
 * because each tested against its own fake. The Flutter test
 * `frontend/test/contract/client_requests_contract_test.dart` records exactly what every
 * online write puts on the wire (real `ApiClient`, recording transport) into
 * `docs/Backend_design/fixtures/client-requests/`, and fails when the client drifts from
 * those files. This spec replays every one of them through the REAL app — guards, the
 * idempotency seam, the controller's own parser, the service, Postgres — and fails when
 * the server would refuse the request's *shape*:
 *
 *   - any 400 (every 400 this API returns is a malformed request — a business refusal is a
 *     409/404/422 with its own code),
 *   - a 404 Nest raises for a route that does not exist (`Cannot POST …`),
 *   - any 5xx,
 *   - any 401 (every fixture is replayed with a valid credential for it).
 *
 * Every other 4xx is a verdict about state and is allowed. Each fixture gets a fresh tenant
 * in which every sentinel id the client used (`ct-product-1`, …) exists, so a route that
 * looks its row up first still reaches the body parser instead of hiding behind a 404.
 */

const TENANT = 'c7c7c7c7-0000-4c7c-8c7c-c7c7c7c7c7c7';
const USERNAME = 'ct-owner';
const PASSWORD = 'ct-password-1';
const FIXTURES_DIR = join(
  fileURLToPath(new URL('.', import.meta.url)),
  '../../docs/Backend_design/fixtures/client-requests',
);

interface RecordedRequest {
  route: string;
  method: 'GET' | 'POST' | 'PATCH' | 'PUT' | 'DELETE';
  path: string;
  idempotencyKey: boolean;
  authorization: 'bearer' | 'custom' | 'none';
  body: unknown;
}

interface Fixture {
  name: string;
  caller: string;
  requests: RecordedRequest[];
}

const fixtureFiles = readdirSync(FIXTURES_DIR)
  .filter((f) => f.endsWith('.json'))
  .sort();

function load(file: string): Fixture {
  return JSON.parse(readFileSync(join(FIXTURES_DIR, file), 'utf8')) as Fixture;
}

let xffCounter = 0;
/** One address per request: the per-IP login bucket (10/60 s) is shared by every e2e file. */
function nextIp(): string {
  xffCounter += 1;
  return `10.88.${Math.floor(xffCounter / 250) % 250}.${(xffCounter % 250) + 1}`;
}

describe('client request fixtures replay against the real server', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: Redis;
  let passwordHash: string;

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
    passwordHash = await hashPassword(PASSWORD);
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT, { cache });
    await app.close();
  });

  it('has fixtures to replay (the Flutter test writes them)', () => {
    expect(fixtureFiles.length).toBeGreaterThan(0);
  });

  /** A fresh tenant holding a row under every sentinel id the client fixtures use. */
  async function world(): Promise<{ f: TenantFixture; token: string; swaps: Map<string, string> }> {
    const f = await resetTenant(admin, TENANT, { cache });
    await admin.query(
      `UPDATE users SET username = $3, password_hash = $4 WHERE tenant_id = $1::uuid AND id = $2::uuid`,
      [TENANT, f.userId, USERNAME, passwordHash],
    );
    await seedSettings(admin, TENANT);
    await seedOpenShift(admin, TENANT, f.posDeviceId, { userId: f.userId, startingCash: 1000 });
    await seedProduct(admin, TENANT, {
      id: 'ct-product-1',
      partNo: 'CT-001',
      name: 'Contract part',
      price: 100,
      cost: 60,
      stock: 50,
    });
    await seedCustomer(admin, TENANT, { id: 'ct-customer-1', code: 'CT-C1', name: 'Contract customer' });
    await seedMechanic(admin, TENANT, {
      id: 'ct-mechanic-1',
      code: 'CT-M1',
      name: 'Contract mechanic',
      creditLimit: 100000,
      creditBalance: 500,
    });
    await admin.query(
      `INSERT INTO owner_review_items (tenant_id, id, kind, ref_id) VALUES ($1::uuid, 'ct-review-1', 'void_offline', 'ct-sale-1')`,
      [TENANT],
    );
    await admin.query(
      `INSERT INTO categories (tenant_id, name, position) VALUES ($1::uuid, 'ct-category', 1), ($1::uuid, 'อื่นๆ', 0)`,
      [TENANT],
    );

    const token = accessToken({
      tenantId: TENANT,
      userId: f.userId,
      deviceId: f.posDeviceId,
      deviceRole: 'pos',
    });
    const post = async (path: string, body: object) => {
      const res = await request(app.getHttpServer())
        .post(path)
        .set('Authorization', `Bearer ${token}`)
        .set('Idempotency-Key', randomUUID())
        .send(body);
      if (res.status >= 300) {
        throw new Error(`world setup ${path} → ${res.status} ${JSON.stringify(res.body)}`);
      }
      return res.body.data;
    };

    // Rows whose id the server mints: created through the API, the sentinel swapped for it.
    const swaps = new Map<string, string>();
    await post('/api/v1/sales', {
      id: 'ct-sale-1',
      subtotal: '200.00',
      discount: '0.00',
      total: '200.00',
      paymentMethod: 'เงินสด',
      items: [{ lineNo: 1, productId: 'ct-product-1', name: 'Contract part', qty: 2, price: '100.00' }],
    });
    const quote = await post('/api/v1/quotes', {
      subtotal: '100.00',
      discount: '0.00',
      total: '100.00',
      items: [{ productId: 'ct-product-1', name: 'Contract part', qty: 1, price: '100.00' }],
    });
    swaps.set('ct-quote-1', quote.id);
    const po = await post('/api/v1/purchase-orders', {
      supplier: 'Contract supplier',
      items: [{ partNo: 'CT-001', name: 'Contract part', qty: 2, cost: '60.00' }],
    });
    swaps.set('ct-po-1', po.id);
    const device = await post('/api/v1/devices', { label: 'เครื่องสัญญา', role: 'backoffice' });
    swaps.set('ct-device-1', device.device.id);
    // `AuthRepository.enrolDevice` upper-cases what was typed.
    swaps.set('CT0DE001', device.enrolCode);
    swaps.set(
      'ct-refresh-token',
      refreshToken({ tenantId: TENANT, userId: f.userId, deviceId: f.posDeviceId, deviceRole: 'pos' }),
    );
    return { f, token, swaps };
  }

  /** A real `typ:'pwchange'` token: what login answers for an owner on a temporary password. */
  async function pwchangeToken(f: TenantFixture): Promise<string> {
    await admin.query(
      `UPDATE users SET must_change_password = TRUE, temp_password_expires_at = now() + interval '1 hour'
        WHERE tenant_id = $1::uuid AND id = $2::uuid`,
      [TENANT, f.userId],
    );
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/token')
      .set('X-Forwarded-For', nextIp())
      .send({ username: USERNAME, password: PASSWORD });
    if (typeof res.body?.data?.passwordChangeToken !== 'string') {
      throw new Error(`could not obtain a pwchange token: ${res.status} ${JSON.stringify(res.body)}`);
    }
    return res.body.data.passwordChangeToken as string;
  }

  function swap<T>(value: T, swaps: Map<string, string>): T {
    let text = JSON.stringify(value);
    for (const [from, to] of swaps) text = text.split(from).join(to);
    return JSON.parse(text) as T;
  }

  it.each(fixtureFiles)('%s is accepted (no 400, no missing route, no 5xx)', async (file) => {
    const fixture = load(file);
    expect(fixture.requests.length).toBeGreaterThan(0);
    const { f, token, swaps } = await world();
    // `custom` = a token the caller passed itself; the only one is the pwchange token.
    if (fixture.requests.some((r) => r.authorization === 'custom')) {
      swaps.set('ct-pwchange-token', await pwchangeToken(f));
    }

    for (const raw of fixture.requests) {
      const r = swap(raw, swaps);
      let req = request(app.getHttpServer())
        [r.method.toLowerCase() as 'post' | 'patch' | 'put' | 'delete' | 'get'](r.path)
        .set('X-Forwarded-For', nextIp())
        // ApiClient sends this on every request, body or not.
        .set('Content-Type', 'application/json');
      if (r.authorization === 'bearer') req = req.set('Authorization', `Bearer ${token}`);
      if (r.authorization === 'custom') req = req.set('Authorization', `Bearer ${swaps.get('ct-pwchange-token')}`);
      if (r.idempotencyKey) req = req.set('Idempotency-Key', randomUUID());
      // `null` = the client sent no body at all — exactly what the 2026-10-03 convert bug did.
      const res = r.body === null ? await req : await req.send(r.body as object);

      const where = `${fixture.caller}: ${r.method} ${raw.path} → ${res.status} ${JSON.stringify(res.body)}`;
      const code: unknown = res.body?.error?.code;
      const message = String(res.body?.error?.message ?? '');
      expect(res.status, `server refused the request's shape — ${where}`).not.toBe(400);
      expect(res.status >= 500, `server error — ${where}`).toBe(false);
      expect(
        res.status === 404 && /^Cannot (GET|POST|PATCH|PUT|DELETE) /.test(message),
        `the server has no such route — ${where}`,
      ).toBe(false);
      // Every fixture is replayed with a credential that is valid for it (the auth routes
      // included: real password, minted refresh token, real enrol code, real pwchange
      // token), so a 401 means the harness — or the route's auth — no longer matches.
      expect(res.status, `credential refused — ${where}`).not.toBe(401);
      // Recorded so a reviewer can see what each replay actually exercised.
      console.info(`[client-contract] ${fixture.name}: ${raw.route} → ${res.status}${code ? ` ${code} ${message}` : ''}`);
    }
  });
});
