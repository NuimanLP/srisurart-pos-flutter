import { generateKeyPairSync, randomUUID } from 'node:crypto';
import type { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import * as jwt from 'jsonwebtoken';
import { pino } from 'pino';
import type { Redis } from 'ioredis';
import { DataSource } from 'typeorm';
import { AppModule } from '../../src/app.module.js';
import { configureApp } from '../../src/app.setup.js';
import { loadConfig } from '../../src/config/config.js';
import { ADMIN_DATA_SOURCE } from '../../src/infra/db.module.js';
import { REDIS_CACHE } from '../../src/infra/redis.module.js';
import { hashPassword } from '../../src/common/password.js';

/**
 * One RSA key pair for the whole run: the suites mint their own access tokens
 * rather than logging in, because what they are testing is what happens *after*
 * the guard, and a password round trip in every test buys nothing.
 */
const { privateKey, publicKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  publicKeyEncoding: { type: 'spki', format: 'pem' },
});

export interface TokenClaims {
  tenantId: string;
  userId?: string;
  role?: 'owner' | 'manager' | 'cashier';
  deviceId?: string;
  deviceRole?: 'pos' | 'backoffice';
}

/** An access token exactly as `/auth/token` would have issued it. */
export function accessToken(claims: TokenClaims): string {
  return jwt.sign(
    {
      iss: 'srisurart-pos',
      aud: 'tenant',
      sub: claims.userId ?? randomUUID(),
      jti: randomUUID(),
      typ: 'access',
      tid: claims.tenantId,
      role: claims.role ?? 'cashier',
      did: claims.deviceId,
      drole: claims.deviceRole,
    },
    privateKey,
    { algorithm: 'RS256', keyid: 'key-1', expiresIn: '15m' },
  );
}

/**
 * A refresh token exactly as `/auth/token` would have issued it. `exp` is a Unix
 * second, because ADR-0009 pins the refresh expiry to 04:00 of the tenant's day and
 * a reissue has to carry that same instant forward — a suite proving that needs to
 * choose the number itself.
 */
export function refreshToken(claims: TokenClaims & { exp?: number }): string {
  return jwt.sign(
    {
      iss: 'srisurart-pos',
      aud: 'tenant',
      sub: claims.userId ?? randomUUID(),
      jti: randomUUID(),
      typ: 'refresh',
      tid: claims.tenantId,
      role: claims.role ?? 'cashier',
      did: claims.deviceId,
      drole: claims.deviceRole,
      exp: claims.exp ?? Math.floor(Date.now() / 1000) + 8 * 3600,
    },
    privateKey,
    { algorithm: 'RS256', keyid: 'key-1' },
  );
}

export interface TestApp {
  app: INestApplication;
  /** Connects as `pos_app`: RLS enabled and forced, exactly as production does. */
  ds: DataSource;
  /** Connects as the superuser, for fixture setup and assertions RLS would hide. */
  admin: DataSource;
  /** The guard's status cache — a suite that resets a tenant must reset this too. */
  cache: Redis;
}

/**
 * Boots the real application against the compose Postgres and Redis. `extraModules`
 * is how a suite mounts a controller that does not exist in `src/` yet — a route that
 * a later ticket will own, exercised now rather than shipped untested.
 */
export async function createTestApp(
  extraModules: unknown[] = [],
): Promise<TestApp> {
  const config = loadConfig({
    DATABASE_URL: 'postgres://pos_app:dev-only-pos-app@127.0.0.1:5432/pos',
    // Enough in-flight transactions for the concurrency suites to contend for real,
    // and no more: `fileParallelism: false` runs every suite in ONE worker process, so
    // each app's two pools (app + admin) accumulate against the compose Postgres's
    // `max_connections = 100` for the length of the run. At 20 the run occasionally
    // died as "worker exited unexpectedly" — a crash with no failing assertion behind
    // it, which is the worst kind of red build to inherit.
    DB_POOL_SIZE: '8',
    REDIS_CACHE_URL: 'redis://:dev-only-redis@127.0.0.1:6379',
    REDIS_QUEUE_URL: 'redis://:dev-only-redis@127.0.0.1:6380',
    ...process.env,
    // After the spread on purpose: CI may point DATABASE_URL and the Redis URLs
    // elsewhere, but a JWT_* left over in the environment would not verify the
    // tokens this file mints.
    JWT_PRIVATE_KEY: privateKey,
    JWT_PUBLIC_KEYS: publicKey,
  });
  // Silent unless a run asks otherwise: `TEST_LOG_LEVEL=error pnpm test:e2e` is how
  // you see why a suite is getting a 500.
  const logger = pino({ level: process.env.TEST_LOG_LEVEL ?? 'silent' });
  const moduleRef = await Test.createTestingModule({
    imports: [AppModule.forRoot(config, logger), ...(extraModules as never[])],
  }).compile();
  const app = moduleRef.createNestApplication();
  const ds = app.get(DataSource);
  const admin = app.get<DataSource>(ADMIN_DATA_SOURCE);
  const cache = app.get<Redis>(REDIS_CACHE);
  await configureApp(app, logger);
  // Listen once, on an ephemeral port. Without this supertest starts and closes a
  // server per request, which the 200-request case turns into 200 listen/close cycles
  // — and a keep-alive socket pointing at a server that has already gone.
  await app.listen(0);
  return { app, ds, admin, cache };
}

/** Every tenant-scoped table, in an order that respects the foreign keys. */
const TENANT_TABLES_DEPTH_FIRST = [
  'drawer_entries',
  'shifts',
  'return_items',
  'returns',
  'sale_items',
  'sales',
  'credit_payments',
  'movements',
  'parked_sales',
  'quote_items',
  'quotes',
  'po_items',
  'purchase_orders',
  'products',
  'categories',
  'suppliers',
  'customers',
  'mechanics',
  'doc_counters',
  'idempotency_keys',
  'audit_log',
  'tenant_meta',
  'devices',
  'users',
  'settings',
];

export interface TenantFixture {
  tenantId: string;
  userId: string;
  /**
   * The manager's login name — derived from the tenant id, never a shared literal.
   * `POST /auth/token` without a device token resolves a username across EVERY tenant
   * (ADR-0004: the shop is named by the device token, not by the form), so two fixture
   * tenants sharing one name make that name ambiguous and every login with it a 401.
   * When the name was the constant `'tester'`, a single tenant left behind by a crashed
   * or interrupted run poisoned every later suite — an ordering-dependent red build with
   * no relation to the change under test. Derive it, and a leftover cannot collide.
   */
  username: string;
  posDeviceId: string;
  backofficeDeviceId: string;
  posDeviceNo: number;
  /** The manager PIN, when the suite asked for one. */
  pin: string | null;
}

/**
 * Wipes and re-creates one tenant with a `pos` device, a `backoffice` device and a
 * manager. Runs as the superuser: `movements` is a ledger and `pos_app` has no
 * DELETE on it, which is the point of the grant.
 */
export async function resetTenant(
  admin: DataSource,
  tenantId: string,
  opts: { posDeviceNo?: number; pin?: string; cache?: Redis } = {},
): Promise<TenantFixture> {
  const posDeviceNo = opts.posDeviceNo ?? 1;
  // Postgres is not the only state a tenant has. `TenantGuard` caches
  // `t:{tid}:status` for five minutes, and the idempotency service caches responses
  // under `t:{tid}:idem:*` for a day — both outlive a run. A suite that wipes the
  // tables and not these is testing against a tenant that is half reset: a suspended
  // shop still reads `active`, and a re-used key replays a bill that no longer exists.
  if (opts.cache) await clearTenantCache(opts.cache, tenantId);
  for (const table of TENANT_TABLES_DEPTH_FIRST) {
    await admin.query(`DELETE FROM ${table} WHERE tenant_id = $1::uuid`, [tenantId]);
  }
  await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [tenantId]);
  await admin.query(
    `INSERT INTO tenants (id, code, shop_name, shop_name_en, plan, status, timezone)
          VALUES ($1::uuid, $2, 'ร้านทดสอบ', 'Test Shop', 'demo', 'active', 'Asia/Bangkok')`,
    // The whole uuid, for the reason spelled out for `username` below: `tenants.code`
    // is globally unique, and `sales`, `sales-ledger` and `returns` all begin
    // `eeeeeeee`. On a prefix they collide as `duplicate key … tenants_code_key` in
    // whichever suite happens to reset second, which is a scheduling accident and
    // reads as a failure of whatever was last changed.
    [tenantId, `test-${tenantId}`],
  );
  const userId = randomUUID();
  // Unique per tenant, on purpose — see `TenantFixture.username`. The whole uuid, not a
  // prefix of it: suites pick their tenant ids by hand and two of them could easily
  // share the first eight characters.
  const username = `tester-${tenantId}`;
  await admin.query(
    `INSERT INTO users (tenant_id, id, username, password_hash, display_name, role, pin_hash)
          VALUES ($1::uuid, $2::uuid, $3, 'x', 'Tester', 'manager', $4)`,
    [tenantId, userId, username, opts.pin ? await hashPassword(opts.pin) : null],
  );
  const posDeviceId = `pos-${tenantId.slice(0, 8)}`;
  const backofficeDeviceId = `bo-${tenantId.slice(0, 8)}`;
  await admin.query(
    `INSERT INTO devices (tenant_id, id, label, device_no, role)
          VALUES ($1::uuid, $2, 'เครื่องขาย', $3, 'pos'),
                 ($1::uuid, $4, 'หลังร้าน', $5, 'backoffice')`,
    [tenantId, posDeviceId, posDeviceNo, backofficeDeviceId, posDeviceNo + 50],
  );
  return {
    tenantId,
    userId,
    username,
    posDeviceId,
    backofficeDeviceId,
    posDeviceNo,
    pin: opts.pin ?? null,
  };
}

/** Drops every Redis key belonging to a tenant. */
export async function clearTenantCache(cache: Redis, tenantId: string): Promise<void> {
  const keys = await cache.keys(`t:${tenantId}:*`);
  if (keys.length > 0) await cache.del(...keys);
}

/** Inserts a product. Returns its id. */
export async function seedProduct(
  admin: DataSource,
  tenantId: string,
  p: {
    id: string;
    partNo: string;
    name: string;
    nameTH?: string;
    price: number;
    cost: number;
    stock: number;
    category?: string;
  },
): Promise<string> {
  await admin.query(
    `INSERT INTO products (tenant_id, id, part_no, name, name_th, category, brand, price, cost, stock)
          VALUES ($1::uuid, $2, $3, $4, $5, $6, 'TEST', $7, $8, $9)`,
    [
      tenantId,
      p.id,
      p.partNo,
      p.name,
      p.nameTH ?? p.name,
      p.category ?? 'อื่นๆ',
      p.price,
      p.cost,
      p.stock,
    ],
  );
  return p.id;
}

/** Inserts a customer. Returns its id. */
export async function seedCustomer(
  admin: DataSource,
  tenantId: string,
  c: {
    id: string;
    code: string;
    name: string;
    nameTH?: string;
    points?: number;
    totalSpend?: number;
  },
): Promise<string> {
  await admin.query(
    `INSERT INTO customers (tenant_id, id, code, name, name_th, points, total_spend)
          VALUES ($1::uuid, $2, $3, $4, $5, $6, $7)`,
    [
      tenantId,
      c.id,
      c.code,
      c.name,
      c.nameTH ?? c.name,
      c.points ?? 0,
      c.totalSpend ?? 0,
    ],
  );
  return c.id;
}

/** Inserts a mechanic. Returns its id. */
export async function seedMechanic(
  admin: DataSource,
  tenantId: string,
  m: {
    id: string;
    code: string;
    name: string;
    creditLimit?: number;
    creditBalance?: number;
    totalSales?: number;
    totalCredit?: number;
    totalDiscount?: number;
    totalMarkup?: number;
  },
): Promise<string> {
  await admin.query(
    `INSERT INTO mechanics (tenant_id, id, code, name, credit_limit, credit_balance,
                            total_sales, total_credit, total_discount, total_markup)
          VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
    [
      tenantId,
      m.id,
      m.code,
      m.name,
      m.creditLimit ?? 0,
      m.creditBalance ?? 0,
      m.totalSales ?? 0,
      m.totalCredit ?? 0,
      m.totalDiscount ?? 0,
      m.totalMarkup ?? 0,
    ],
  );
  return m.id;
}

/** Runs `fn` with `app.tenant_id` set, the way a request does. */
export async function asTenant<T>(
  ds: DataSource,
  tenantId: string,
  fn: (query: (sql: string, params?: unknown[]) => Promise<any>) => Promise<T>,
): Promise<T> {
  const qr = ds.createQueryRunner();
  await qr.connect();
  await qr.startTransaction();
  try {
    await qr.query(`SELECT set_config('app.tenant_id', $1, true)`, [tenantId]);
    const out = await fn((sql, params) => qr.query(sql, params as any[]));
    await qr.commitTransaction();
    return out;
  } catch (err) {
    await qr.rollbackTransaction();
    throw err;
  } finally {
    await qr.release();
  }
}
