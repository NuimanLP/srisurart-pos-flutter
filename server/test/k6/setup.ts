import * as fs from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { Redis } from 'ioredis';
import jwtPkg from 'jsonwebtoken';

const jwt = (jwtPkg as any).default || jwtPkg;
import { hashPassword } from '../../src/common/password.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const TENANT_ID = '00000000-0000-4000-8000-000000000001';
const POS_DEVICE_ID = 'pos-loadtest';
const BO_DEVICE_ID = 'bo-loadtest';
const MANAGER_USER_ID = '00000000-0000-4000-8000-000000000020';
const SHIFT_ID = 'sh-loadtest-1';

const DB_URL =
  process.env.DATABASE_ADMIN_URL ??
  process.env.DATABASE_URL ??
  'postgres://postgres:dev-only-postgres@127.0.0.1:5432/pos';

const REDIS_URL =
  process.env.REDIS_CACHE_URL ?? 'redis://:dev-only-redis@127.0.0.1:6379';

const BASE_URL = process.env.BASE_URL ?? 'http://127.0.0.1:3000';
const P12_STOCK = Number(process.env.P12_STOCK ?? 50);

// Load RSA private key from .env or fallback
function getPrivateKey(): string {
  if (process.env.JWT_PRIVATE_KEY) {
    return process.env.JWT_PRIVATE_KEY.replace(/\\n/g, '\n');
  }
  const envPath = path.resolve(__dirname, '../../.env');
  if (fs.existsSync(envPath)) {
    const content = fs.readFileSync(envPath, 'utf8');
    const match = content.match(/JWT_PRIVATE_KEY="([^"]+)"/s);
    if (match) {
      return match[1].replace(/\\n/g, '\n');
    }
  }
  throw new Error('JWT_PRIVATE_KEY not found in environment or .env');
}

const TABLES_DEPTH_FIRST = [
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

export async function setupLoadTest(options: {
  p12Stock?: number;
  tokens?: { posToken: string; boToken: string };
  privateKey?: string;
} = {}) {
  const p12Stock = options.p12Stock ?? P12_STOCK;
  console.log('🚀 Setting up k6 load test environment...');
  console.log(`   Tenant ID: ${TENANT_ID}`);
  console.log(`   Target URL: ${BASE_URL}`);
  console.log(`   Contention Product p12 Initial Stock: ${p12Stock}`);

  // 1. Connect to Postgres
  const pool = new pg.Pool({ connectionString: DB_URL });
  const client = await pool.connect();

  // 2. Connect to Redis
  const redis = new Redis(REDIS_URL, { maxRetriesPerRequest: 1 });

  try {
    // 3. Clear Redis Cache for Tenant
    const keys = await redis.keys(`t:${TENANT_ID}:*`);
    if (keys.length > 0) {
      await redis.del(...keys);
      console.log(`   Cleaned ${keys.length} Redis cache keys.`);
    }

    // 4. Wipe Tenant Tables
    for (const table of TABLES_DEPTH_FIRST) {
      await client.query(`DELETE FROM ${table} WHERE tenant_id = $1::uuid`, [
        TENANT_ID,
      ]);
    }
    await client.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT_ID]);

    // 5. Seed Tenant with plan = 'loadtest' (bypasses rate limiter per ADR-0006)
    await client.query(
      `INSERT INTO tenants (id, code, shop_name, shop_name_en, plan, status, timezone)
       VALUES ($1::uuid, 'loadtest-tenant', 'ร้านศรีสุราษฎร์ Load Test', 'Srisurart Load Test Shop', 'loadtest', 'active', 'Asia/Bangkok')`,
      [TENANT_ID],
    );

    // 6. Seed Users (single owner per tenant)
    const passwordHash = await hashPassword('password123');
    await client.query(
      `INSERT INTO users (tenant_id, id, username, password_hash, display_name, role)
       VALUES ($1::uuid, $2::uuid, 'owner_k6', $3, 'Owner K6', 'owner')`,
      [TENANT_ID, MANAGER_USER_ID, passwordHash],
    );

    // 7. Seed Devices (ADR-0004: exactly one active POS device per tenant)
    await client.query(
      `INSERT INTO devices (tenant_id, id, label, device_no, role)
       VALUES ($1::uuid, $2, 'เครื่องขาย K6', 1, 'pos'),
              ($1::uuid, $3, 'คอมหลังร้าน K6', 51, 'backoffice')`,
      [TENANT_ID, POS_DEVICE_ID, BO_DEVICE_ID],
    );

    // 8. Seed Open Shift (so POST /sales does not 409 NO_OPEN_SHIFT)
    await client.query(
      `INSERT INTO shifts (tenant_id, id, date_str, starting_cash, opened_at, is_active, device_id, opened_by)
       VALUES ($1::uuid, $2, to_char(now() AT TIME ZONE 'Asia/Bangkok', 'YYYY-MM-DD'), 1000, now(), TRUE, $3, $4::uuid)`,
      [TENANT_ID, SHIFT_ID, POS_DEVICE_ID, MANAGER_USER_ID],
    );

    // 9. Seed Categories
    await client.query(
      `INSERT INTO categories (tenant_id, name, position)
       VALUES ($1::uuid, 'เบรก', 0),
              ($1::uuid, 'น้ำมัน', 1),
              ($1::uuid, 'เครื่องยนต์', 2),
              ($1::uuid, 'ช่วงล่าง', 3),
              ($1::uuid, 'อื่นๆ', 4)`,
      [TENANT_ID],
    );

    // 10. Seed Contention Product p12
    await client.query(
      `INSERT INTO products (tenant_id, id, part_no, name, name_th, category, brand, price, cost, stock, min_stock)
       VALUES ($1::uuid, 'p12', 'BP-P12', 'Brake Pad Special P12', 'ผ้าเบรกพิเศษ P12', 'เบรก', 'SRISURART', 100.00, 60.00, $2, 5)`,
      [TENANT_ID, p12Stock],
    );

    // 11. Seed 50 Catalogue Products for Read/Mixed Tests (5,000 units stock each)
    const productIds: string[] = ['p12'];
    for (let i = 1; i <= 50; i++) {
      const pid = `p_${i}`;
      productIds.push(pid);
      const cat = ['เบรก', 'น้ำมัน', 'เครื่องยนต์', 'ช่วงล่าง', 'อื่นๆ'][i % 5];
      const price = 50 + i * 20;
      const cost = Math.floor(price * 0.7);
      await client.query(
        `INSERT INTO products (tenant_id, id, part_no, name, name_th, category, brand, price, cost, stock, min_stock)
         VALUES ($1::uuid, $2, $3, $4, $5, $6, 'SRISURART', $7, $8, 5000, 10)`,
        [
          TENANT_ID,
          pid,
          `PART-${i}`,
          `Auto Part Item ${i}`,
          `อะไหล่ชิ้นที่ ${i}`,
          cat,
          price,
          cost,
        ],
      );
    }

    console.log(
      `   Seeded 51 products (including contention target p12 with ${p12Stock} units).`,
    );

    // 12. RS256 JWT Tokens
    let posToken = options.tokens?.posToken;
    let boToken = options.tokens?.boToken;

    if (!posToken) {
      const privateKey = options.privateKey ?? getPrivateKey();
      posToken = jwt.sign(
        {
          iss: 'srisurart-pos',
          aud: 'tenant',
          sub: MANAGER_USER_ID,
          jti: 'jti-pos-loadtest',
          typ: 'access',
          tid: TENANT_ID,
          role: 'owner',
          did: POS_DEVICE_ID,
          drole: 'pos',
        },
        privateKey,
        { algorithm: 'RS256', keyid: 'key-1', expiresIn: '24h' },
      );
    }

    if (!boToken) {
      const privateKey = options.privateKey ?? getPrivateKey();
      boToken = jwt.sign(
        {
          iss: 'srisurart-pos',
          aud: 'tenant',
          sub: MANAGER_USER_ID,
          jti: 'jti-bo-loadtest',
          typ: 'access',
          tid: TENANT_ID,
          role: 'owner',
          did: BO_DEVICE_ID,
          drole: 'backoffice',
        },
        privateKey,
        { algorithm: 'RS256', keyid: 'key-1', expiresIn: '24h' },
      );
    }

    // 13. Write k6-env.json
    const envData = {
      baseUrl: BASE_URL,
      tenantId: TENANT_ID,
      posToken,
      boToken,
      posDeviceId: POS_DEVICE_ID,
      productId: 'p12',
      initialStock: p12Stock,
      productPrice: 100.0,
      products: productIds,
    };

    const outPath = path.resolve(__dirname, 'k6-env.json');
    fs.writeFileSync(outPath, JSON.stringify(envData, null, 2), 'utf8');
    console.log(`✅ k6 environment written to: ${outPath}`);
    return envData;
  } finally {
    client.release();
    await pool.end();
    await redis.quit();
  }
}

// Allow direct CLI execution: node dist/test/k6/setup.js or tsx setup.ts
if (process.argv[1] && process.argv[1].endsWith('setup.ts')) {
  setupLoadTest()
    .then(() => process.exit(0))
    .catch((err) => {
      console.error('❌ Setup failed:', err);
      process.exit(1);
    });
}
