import type { INestApplication } from '@nestjs/common';
import type { Redis } from 'ioredis';
import type { DataSource } from 'typeorm';
import { TENANT_SCOPED_TABLES } from '../src/db/migrations/1788652800001-RowLevelSecurity.js';
import {
  asTenant,
  createTestApp,
  resetTenant,
  type TenantFixture,
} from './support/fixture.js';

// Unique tenant UUIDs for Issue #292 isolation sweep
const TENANT_A = '29229229-2920-4292-8292-292292292292';
const TENANT_B = '29229229-2921-4292-8292-292292292292';

type TenantScopedTable = (typeof TENANT_SCOPED_TABLES)[number];

/**
 * Insertion order respecting foreign keys: reverse of TENANT_TABLES_DEPTH_FIRST
 * (with products preceding suppliers to satisfy the foreign key dependency).
 */
const INSERT_ORDER: readonly TenantScopedTable[] = [
  'settings',
  'users',
  'devices',
  'tenant_meta',
  'audit_log',
  'idempotency_keys',
  'doc_counters',
  'mechanics',
  'customers',
  'categories',
  'products',
  'suppliers',
  'purchase_orders',
  'po_items',
  'quotes',
  'quote_items',
  'parked_sales',
  'movements',
  'credit_payments',
  'sales',
  'sale_items',
  'returns',
  'return_items',
  'shifts',
  'drawer_entries',
] as const;

async function seedTenantB(
  admin: DataSource,
  tenantId: string,
  fixture: TenantFixture,
): Promise<void> {
  for (const table of INSERT_ORDER) {
    if ((table as string) === 'import_jobs') continue;

    switch (table) {
      case 'settings':
        await admin.query(
          `INSERT INTO settings (tenant_id, shop_name, shop_name_en, tax_rate, quote_valid_days)
           VALUES ($1::uuid, 'Shop B', 'Shop B', 7, 30)
           ON CONFLICT (tenant_id) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'users':
        // resetTenant already seeded a manager user for TENANT_B.
        break;

      case 'devices':
        // resetTenant already seeded POS and backoffice devices for TENANT_B.
        break;

      case 'tenant_meta':
        await admin.query(
          `INSERT INTO tenant_meta (tenant_id, key, value)
           VALUES ($1::uuid, 'meta_k1', 'meta_v1')
           ON CONFLICT (tenant_id, key) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'audit_log':
        await admin.query(
          `INSERT INTO audit_log (tenant_id, user_id, action)
           VALUES ($1::uuid, $2::uuid, 'system.sweep')`,
          [tenantId, fixture.userId],
        );
        break;

      case 'idempotency_keys':
        await admin.query(
          `INSERT INTO idempotency_keys (tenant_id, key, endpoint, request_hash, status)
           VALUES ($1::uuid, 'idem-sweep-b', '/api/v1/sweep', 'reqhash', 'done')
           ON CONFLICT (tenant_id, key) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'doc_counters':
        await admin.query(
          `INSERT INTO doc_counters (tenant_id, device_id, doc_type, period, last_no)
           VALUES ($1::uuid, $2, 'receipt', '202609', 1)
           ON CONFLICT (tenant_id, device_id, doc_type, period) DO NOTHING`,
          [tenantId, fixture.posDeviceId],
        );
        break;

      case 'mechanics':
        await admin.query(
          `INSERT INTO mechanics (tenant_id, id, code, name)
           VALUES ($1::uuid, 'mech-sweep-b', 'M-SWEEP-B', 'Mechanic B')
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'customers':
        await admin.query(
          `INSERT INTO customers (tenant_id, id, code, name, name_th)
           VALUES ($1::uuid, 'cust-sweep-b', 'C-SWEEP-B', 'Customer B', 'ลูกค้า B')
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'categories':
        await admin.query(
          `INSERT INTO categories (tenant_id, name, position)
           VALUES ($1::uuid, 'Cat Sweep B', 1)
           ON CONFLICT (tenant_id, name) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'products':
        await admin.query(
          `INSERT INTO products (tenant_id, id, part_no, name, name_th, category, brand, price, cost, stock)
           VALUES ($1::uuid, 'prod-sweep-b', 'PART-SWEEP-B', 'Product B', 'สินค้า B', 'Cat Sweep B', 'Brand B', 100, 50, 10)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'suppliers':
        await admin.query(
          `INSERT INTO suppliers (tenant_id, id, product_id, name, unit_cost)
           VALUES ($1::uuid, 'sup-sweep-b', 'prod-sweep-b', 'Supplier B', 50)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'purchase_orders':
        await admin.query(
          `INSERT INTO purchase_orders (tenant_id, id, po_no, supplier, status)
           VALUES ($1::uuid, 'po-sweep-b', 'PO-SWEEP-B', 'Supplier B', 'open')
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'po_items':
        await admin.query(
          `INSERT INTO po_items (tenant_id, po_id, line_no, part_no, name, qty, cost)
           VALUES ($1::uuid, 'po-sweep-b', 1, 'PART-SWEEP-B', 'Product B', 1, 50)
           ON CONFLICT (tenant_id, po_id, line_no) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'quotes':
        await admin.query(
          `INSERT INTO quotes (tenant_id, id, quote_no, status, valid_until)
           VALUES ($1::uuid, 'qt-sweep-b', 'QT-SWEEP-B', 'open', now() + interval '30 days')
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'quote_items':
        await admin.query(
          `INSERT INTO quote_items (tenant_id, quote_id, line_no, product_id, name, qty, price)
           VALUES ($1::uuid, 'qt-sweep-b', 1, 'prod-sweep-b', 'Product B', 1, 100)
           ON CONFLICT (tenant_id, quote_id, line_no) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'parked_sales':
        await admin.query(
          `INSERT INTO parked_sales (tenant_id, id, payload)
           VALUES ($1::uuid, 'parked-sweep-b', '{"items":[]}'::jsonb)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'movements':
        await admin.query(
          `INSERT INTO movements (tenant_id, id, product_id, part_no, name, delta, type, stock_after)
           VALUES ($1::uuid, 'mov-sweep-b', 'prod-sweep-b', 'PART-SWEEP-B', 'Product B', 10, 'receive', 10)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'credit_payments':
        await admin.query(
          `INSERT INTO credit_payments (tenant_id, id, receipt_no, mechanic_id, amount)
           VALUES ($1::uuid, 'cp-sweep-b', 'CP-SWEEP-B', 'mech-sweep-b', 100)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'sales':
        await admin.query(
          `INSERT INTO sales (tenant_id, id, receipt_no, subtotal, discount, total, payment_method, customer_id, mechanic_id)
           VALUES ($1::uuid, 'sale-sweep-b', 'RC-SWEEP-B', 100, 0, 100, 'เงินสด', 'cust-sweep-b', 'mech-sweep-b')
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'sale_items':
        await admin.query(
          `INSERT INTO sale_items (tenant_id, sale_id, line_no, product_id, part_no, name, qty, price, cost_at_sale)
           VALUES ($1::uuid, 'sale-sweep-b', 1, 'prod-sweep-b', 'PART-SWEEP-B', 'Product B', 1, 100, 50)
           ON CONFLICT (tenant_id, sale_id, line_no) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'returns':
        await admin.query(
          `INSERT INTO returns (tenant_id, id, cn_no, sale_id, receipt_no, refund_subtotal, refund_discount, refund_total, refund_method)
           VALUES ($1::uuid, 'ret-sweep-b', 'CN-SWEEP-B', 'sale-sweep-b', 'RC-SWEEP-B', 100, 0, 100, 'เงินสด')
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'return_items':
        await admin.query(
          `INSERT INTO return_items (tenant_id, return_id, line_no, product_id, name, qty, price)
           VALUES ($1::uuid, 'ret-sweep-b', 1, 'prod-sweep-b', 'Product B', 1, 100)
           ON CONFLICT (tenant_id, return_id, line_no) DO NOTHING`,
          [tenantId],
        );
        break;

      case 'shifts':
        await admin.query(
          `INSERT INTO shifts (tenant_id, id, date_str, starting_cash, opened_at, is_active, device_id)
           VALUES ($1::uuid, 'shift-sweep-b', '2026-09-17', 1000, now(), true, $2)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId, fixture.posDeviceId],
        );
        break;

      case 'drawer_entries':
        await admin.query(
          `INSERT INTO drawer_entries (tenant_id, id, shift_id, type, amount, note)
           VALUES ($1::uuid, 'de-sweep-b', 'shift-sweep-b', 'in', 100, 'sweep drawer entry')
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId],
        );
        break;

      default: {
        const _exhaustiveCheck: never = table;
        throw new Error(`Unhandled table in seedTenantB: ${_exhaustiveCheck}`);
      }
    }
  }
}

describe('tenant-isolation-sweep (Issue #292)', () => {
  let app: INestApplication;
  let ds: DataSource;
  let admin: DataSource;
  let cache: Redis;
  let fixtureB: TenantFixture;

  beforeAll(async () => {
    ({ app, ds, admin, cache } = await createTestApp());
    await resetTenant(admin, TENANT_A, { cache });
    fixtureB = await resetTenant(admin, TENANT_B, { cache });
    await seedTenantB(admin, TENANT_B, fixtureB);
  });

  afterAll(async () => {
    if (admin) {
      await resetTenant(admin, TENANT_A, { cache });
      await resetTenant(admin, TENANT_B, { cache });
      await admin.query(
        `DELETE FROM tenants WHERE id IN ($1::uuid, $2::uuid)`,
        [TENANT_A, TENANT_B],
      );
    }
    if (app) {
      await app.close();
    }
  });

  it('non-vacuity guard: every tenant-scoped table has at least one row for TENANT_B', async () => {
    await asTenant(ds, TENANT_B, async (query) => {
      for (const table of TENANT_SCOPED_TABLES) {
        const rows = (await query(
          `SELECT count(*)::int AS n FROM ${table} WHERE tenant_id = $1::uuid`,
          [TENANT_B],
        )) as { n: number }[];
        const count = rows[0]?.n ?? 0;
        if (count < 1) {
          throw new Error(
            `Non-vacuity guard failed: table '${table}' has ${count} rows for TENANT_B (expected >= 1)`,
          );
        }
        expect(
          count,
          `Table ${table} must have at least one row for TENANT_B`,
        ).toBeGreaterThanOrEqual(1);
      }
    });
  });

  it('cross-tenant read: TENANT_A context sees 0 rows when querying for TENANT_B', async () => {
    await asTenant(ds, TENANT_A, async (query) => {
      for (const table of TENANT_SCOPED_TABLES) {
        const rows = (await query(
          `SELECT count(*)::int AS n FROM ${table} WHERE tenant_id = $1::uuid`,
          [TENANT_B],
        )) as { n: number }[];
        const count = rows[0]?.n ?? 0;
        expect(
          count,
          `Cross-tenant read leak: TENANT_A saw ${count} rows from ${table} for TENANT_B`,
        ).toBe(0);
      }
    });
  });

  it('cross-tenant update/delete: affects 0 rows under TENANT_A (movements denied with 42501)', async () => {
    class RollbackSentinel extends Error {
      constructor() {
        super('ROLLBACK_SENTINEL');
      }
    }

    // 1. movements table: pos_app has no UPDATE or DELETE privilege
    for (const op of ['UPDATE', 'DELETE'] as const) {
      let caughtErr: any = null;
      try {
        await asTenant(ds, TENANT_A, async (query) => {
          if (op === 'UPDATE') {
            await query(
              `UPDATE movements SET tenant_id = tenant_id WHERE tenant_id = $1::uuid`,
              [TENANT_B],
            );
          } else {
            await query(
              `DELETE FROM movements WHERE tenant_id = $1::uuid`,
              [TENANT_B],
            );
          }
        });
      } catch (err) {
        caughtErr = err;
      }
      expect(caughtErr, `${op} on movements should be rejected`).toBeDefined();
      expect(caughtErr.code, `SQLSTATE for ${op} on movements`).toBe('42501');
      expect(caughtErr.message, `Error message for ${op} on movements`).toMatch(
        /permission denied/,
      );
    }

    // 2. all other tenant-scoped tables: UPDATE and DELETE affect 0 rows
    for (const table of TENANT_SCOPED_TABLES) {
      if (table === 'movements') continue;

      let sentinelThrown = false;
      try {
        await asTenant(ds, TENANT_A, async (query) => {
          const updateRes = await query(
            `UPDATE ${table} SET tenant_id = tenant_id WHERE tenant_id = $1::uuid`,
            [TENANT_B],
          );
          const affectedUpdate = Array.isArray(updateRes) ? updateRes[1] : 0;
          expect(
            affectedUpdate,
            `Cross-tenant UPDATE on ${table} affected ${affectedUpdate} rows (expected 0)`,
          ).toBe(0);

          const deleteRes = await query(
            `DELETE FROM ${table} WHERE tenant_id = $1::uuid`,
            [TENANT_B],
          );
          const affectedDelete = Array.isArray(deleteRes) ? deleteRes[1] : 0;
          expect(
            affectedDelete,
            `Cross-tenant DELETE on ${table} affected ${affectedDelete} rows (expected 0)`,
          ).toBe(0);

          sentinelThrown = true;
          throw new RollbackSentinel();
        });
      } catch (err) {
        if (err instanceof RollbackSentinel) {
          // Expected rollback sentinel
        } else {
          throw err;
        }
      }
      expect(
        sentinelThrown,
        `Rollback sentinel was not thrown for table ${table}`,
      ).toBe(true);
    }
  });

  it('cross-tenant insert refusal: inserting TENANT_B under TENANT_A context is rejected by RLS', async () => {
    for (const table of TENANT_SCOPED_TABLES) {
      let caughtErr: any = null;
      try {
        await asTenant(ds, TENANT_A, async (query) => {
          await query(
            `INSERT INTO ${table} (tenant_id) VALUES ($1::uuid)`,
            [TENANT_B],
          );
        });
      } catch (err) {
        caughtErr = err;
      }
      expect(
        caughtErr,
        `INSERT into ${table} with tenant_id=${TENANT_B} under TENANT_A context must be rejected`,
      ).toBeDefined();
      expect(caughtErr.code, `SQLSTATE for ${table}`).toBe('42501');
      expect(caughtErr.message, `Error message for ${table}`).toMatch(
        /row-level security/,
      );
    }
  });
});
