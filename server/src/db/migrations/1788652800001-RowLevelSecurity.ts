import type { MigrationInterface, QueryRunner } from 'typeorm';

/** Every table that carries tenant_id — RLS is enabled AND forced on each one. */
export const TENANT_SCOPED_TABLES = [
  'users',
  'devices',
  'idempotency_keys',
  'doc_counters',
  'audit_log',
  'tenant_meta',
  'categories',
  'products',
  'suppliers',
  'movements',
  'customers',
  'mechanics',
  'credit_payments',
  'sales',
  'sale_items',
  'returns',
  'return_items',
  'purchase_orders',
  'po_items',
  'quotes',
  'quote_items',
  'parked_sales',
  'shifts',
  'drawer_entries',
  'settings',
] as const;

/** Tables without tenant_id: platform-wide, read by every tenant request (status) or by /platform/*. */
export const GLOBAL_TABLES = ['tenants', 'platform_admins'] as const;

export const ALL_TABLES = [...GLOBAL_TABLES, ...TENANT_SCOPED_TABLES];

/** The role the api / worker connect as (created by docker/postgres/init/01-app-role.sh). */
export const APP_ROLE = 'pos_app';

/**
 * #15 `p2` — tenancy as the last net (#2 rule 3, 01_DATABASE §8):
 *
 *  - RLS ENABLE + FORCE on every tenant-scoped table, one fail-closed policy each.
 *    `current_setting('app.tenant_id', true)` with the GUC unset yields NULL → the
 *    predicate is NULL → zero rows, never an error. TenantGuard (#4) does
 *    `SET LOCAL app.tenant_id` inside the request transaction.
 *  - Grants to `pos_app`, which is neither superuser nor table owner (the owner is the
 *    role that runs migrations). `movements` is a ledger: INSERT/SELECT only.
 *
 * Later migrations that add tables must append them to TENANT_SCOPED_TABLES here
 * (the schema test asserts every table has RLS + grants, so forgetting fails the suite).
 */
export class RowLevelSecurity1788652800001 implements MigrationInterface {
  name = 'RowLevelSecurity1788652800001';

  async up(q: QueryRunner): Promise<void> {
    for (const t of TENANT_SCOPED_TABLES) {
      await q.query(`ALTER TABLE ${t} ENABLE ROW LEVEL SECURITY`);
      await q.query(`ALTER TABLE ${t} FORCE ROW LEVEL SECURITY`);
      await q.query(`
        CREATE POLICY tenant_isolation ON ${t}
          USING      (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
          WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)`);
    }

    await q.query(
      `DO $$ BEGIN EXECUTE format('GRANT CONNECT ON DATABASE %I TO ${APP_ROLE}', current_database()); END $$`,
    );
    await q.query(`GRANT USAGE ON SCHEMA public TO ${APP_ROLE}`);
    for (const t of ALL_TABLES) {
      const dml =
        t === 'movements' ? 'SELECT, INSERT' : 'SELECT, INSERT, UPDATE, DELETE';
      await q.query(`GRANT ${dml} ON ${t} TO ${APP_ROLE}`);
    }
    await q.query(
      `GRANT USAGE, SELECT ON SEQUENCE audit_log_id_seq TO ${APP_ROLE}`,
    );
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`REVOKE ALL ON SEQUENCE audit_log_id_seq FROM ${APP_ROLE}`);
    for (const t of ALL_TABLES) {
      await q.query(`REVOKE ALL ON ${t} FROM ${APP_ROLE}`);
    }
    for (const t of TENANT_SCOPED_TABLES) {
      await q.query(`DROP POLICY IF EXISTS tenant_isolation ON ${t}`);
      await q.query(`ALTER TABLE ${t} NO FORCE ROW LEVEL SECURITY`);
      await q.query(`ALTER TABLE ${t} DISABLE ROW LEVEL SECURITY`);
    }
  }
}
