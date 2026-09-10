import { generateKeyPairSync, randomUUID } from 'node:crypto';
import type { INestApplication } from '@nestjs/common';
import { Test, type TestingModuleBuilder } from '@nestjs/testing';
import * as jwt from 'jsonwebtoken';
import { pino } from 'pino';
import { DataSource } from 'typeorm';
import { AppModule } from '../../src/app.module.js';
import { configureApp } from '../../src/app.setup.js';
import { loadConfig } from '../../src/config/config.js';
import { ADMIN_DATA_SOURCE } from '../../src/infra/db.module.js';

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

export interface TestApp {
  app: INestApplication;
  /** Connects as `pos_app`: RLS enabled and forced, exactly as production does. */
  ds: DataSource;
  /** Connects as the superuser, for fixture setup and assertions RLS would hide. */
  admin: DataSource;
}

/**
 * Boots the real application against the compose Postgres and Redis. Extra test
 * modules can be added through `extend`, which is how a suite mounts a controller
 * that does not exist in `src/` yet.
 */
export async function createTestApp(
  extend?: (builder: TestingModuleBuilder) => TestingModuleBuilder,
): Promise<TestApp> {
  const config = loadConfig({
    DATABASE_URL: 'postgres://pos_app:dev-only-pos-app@127.0.0.1:5432/pos',
    // The concurrency suites need many in-flight transactions at once; with a small
    // pool they would queue and prove nothing about locking.
    DB_POOL_SIZE: '20',
    REDIS_CACHE_URL: 'redis://:dev-only-redis@127.0.0.1:6379',
    REDIS_QUEUE_URL: 'redis://:dev-only-redis@127.0.0.1:6380',
    ...process.env,
    // After the spread on purpose: CI may point DATABASE_URL and the Redis URLs
    // elsewhere, but a JWT_* left over in the environment would not verify the
    // tokens this file mints.
    JWT_PRIVATE_KEY: privateKey,
    JWT_PUBLIC_KEYS: publicKey,
  });
  const logger = pino({ level: 'silent' });
  let builder = Test.createTestingModule({
    imports: [AppModule.forRoot(config, logger)],
  });
  if (extend) builder = extend(builder);
  const moduleRef = await builder.compile();
  const app = moduleRef.createNestApplication();
  const ds = app.get(DataSource);
  const admin = app.get<DataSource>(ADMIN_DATA_SOURCE);
  await configureApp(app, logger);
  return { app, ds, admin };
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
  posDeviceId: string;
  backofficeDeviceId: string;
  posDeviceNo: number;
}

/**
 * Wipes and re-creates one tenant with a `pos` device, a `backoffice` device and a
 * manager. Runs as the superuser: `movements` is a ledger and `pos_app` has no
 * DELETE on it, which is the point of the grant.
 */
export async function resetTenant(
  admin: DataSource,
  tenantId: string,
  opts: { posDeviceNo?: number } = {},
): Promise<TenantFixture> {
  const posDeviceNo = opts.posDeviceNo ?? 1;
  for (const table of TENANT_TABLES_DEPTH_FIRST) {
    await admin.query(`DELETE FROM ${table} WHERE tenant_id = $1::uuid`, [tenantId]);
  }
  await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [tenantId]);
  await admin.query(
    `INSERT INTO tenants (id, code, shop_name, shop_name_en, plan, status, timezone)
          VALUES ($1::uuid, $2, 'ร้านทดสอบ', 'Test Shop', 'demo', 'active', 'Asia/Bangkok')`,
    [tenantId, `test-${tenantId.slice(0, 8)}`],
  );
  const userId = randomUUID();
  await admin.query(
    `INSERT INTO users (tenant_id, id, username, password_hash, display_name, role)
          VALUES ($1::uuid, $2::uuid, 'tester', 'x', 'Tester', 'manager')`,
    [tenantId, userId],
  );
  const posDeviceId = `pos-${tenantId.slice(0, 8)}`;
  const backofficeDeviceId = `bo-${tenantId.slice(0, 8)}`;
  await admin.query(
    `INSERT INTO devices (tenant_id, id, label, device_no, role)
          VALUES ($1::uuid, $2, 'เครื่องขาย', $3, 'pos'),
                 ($1::uuid, $4, 'หลังร้าน', $5, 'backoffice')`,
    [tenantId, posDeviceId, posDeviceNo, backofficeDeviceId, posDeviceNo + 50],
  );
  return { tenantId, userId, posDeviceId, backofficeDeviceId, posDeviceNo };
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
