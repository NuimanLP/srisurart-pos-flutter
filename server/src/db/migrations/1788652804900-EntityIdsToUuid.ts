import type { MigrationInterface, QueryRunner } from 'typeorm';
import { APP_ROLE } from './1788652800001-RowLevelSecurity.js';

/**
 * #616: every TEXT entity id, and every column that points at one, becomes `UUID` —
 * `tenants`/`users`/`platform_admins` already were. Ids are lowercase UUIDv7 minted by the
 * app (server and offline client); Postgres never mints one, so no column gets a default.
 *
 * Targets a FRESH database only (owner decision): legacy `prefix+base36` ids cannot be cast,
 * so `up()` refuses on the first business table that holds a row instead of half-failing on
 * a 22P02 midway. No migration inserts into these tables, so a clean `db:migrate` passes.
 *
 * Order: drop the 11 composite FKs → retype the 44 columns → re-add the FKs under the same
 * names and actions → re-create the three SECURITY DEFINER auth functions whose
 * `RETURNS TABLE` carries a device id. `ALTER COLUMN … TYPE` does not track SQL function
 * bodies, so without that last step login/device auth would fail at call time with a
 * return-type mismatch. The bodies are the latest ones (`…0002` for the two device
 * functions' original shape, `…4500` for `auth_lookup_device_and_active_user`); only the id
 * type changes. `auth_enrol_device` mints nothing — it returns the id of the existing
 * `devices` row whose enrol code matched.
 *
 * Not ids, so left TEXT: `idempotency_keys.key`, `tenants.code`, `settings.tax_id`, the
 * document numbers, `categories.name` / `products.category`.
 */

/** The 22 business tables. Each must be empty before the cast. */
const GUARDED_TABLES = [
  'devices',
  'doc_counters',
  'audit_log',
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
  'import_jobs',
  'owner_review_items',
] as const;

/** The 44 columns, one ALTER TABLE per table. */
export const UUID_ID_COLUMNS: Readonly<Record<(typeof GUARDED_TABLES)[number], readonly string[]>> = {
  devices: ['id'],
  doc_counters: ['device_id'],
  audit_log: ['device_id', 'entity_id'],
  products: ['id'],
  suppliers: ['id', 'product_id'],
  movements: ['id', 'product_id', 'ref_id'],
  customers: ['id'],
  mechanics: ['id'],
  credit_payments: ['id', 'mechanic_id', 'shift_id'],
  sales: ['id', 'customer_id', 'mechanic_id', 'shift_id', 'device_id'],
  sale_items: ['sale_id', 'product_id'],
  returns: ['id', 'sale_id', 'customer_id', 'mechanic_id', 'shift_id'],
  return_items: ['return_id', 'product_id'],
  purchase_orders: ['id'],
  po_items: ['po_id'],
  quotes: ['id', 'converted_sale_id'],
  quote_items: ['quote_id', 'product_id'],
  parked_sales: ['id', 'device_id'],
  shifts: ['id', 'device_id'],
  drawer_entries: ['id', 'shift_id'],
  import_jobs: ['id'],
  owner_review_items: ['id', 'ref_id'],
};

/**
 * The 11 composite FKs, under the names Postgres generated for them in `InitialSchema`
 * (`<table>_<columns>_fkey`) and with their original ON DELETE actions.
 */
export const ENTITY_FKS = [
  { name: 'suppliers_tenant_id_product_id_fkey', table: 'suppliers', column: 'product_id', parent: 'products', onDelete: 'CASCADE' },
  { name: 'movements_tenant_id_product_id_fkey', table: 'movements', column: 'product_id', parent: 'products', onDelete: '' },
  { name: 'credit_payments_tenant_id_mechanic_id_fkey', table: 'credit_payments', column: 'mechanic_id', parent: 'mechanics', onDelete: '' },
  { name: 'sales_tenant_id_customer_id_fkey', table: 'sales', column: 'customer_id', parent: 'customers', onDelete: '' },
  { name: 'sales_tenant_id_mechanic_id_fkey', table: 'sales', column: 'mechanic_id', parent: 'mechanics', onDelete: '' },
  { name: 'sale_items_tenant_id_sale_id_fkey', table: 'sale_items', column: 'sale_id', parent: 'sales', onDelete: 'CASCADE' },
  { name: 'returns_tenant_id_sale_id_fkey', table: 'returns', column: 'sale_id', parent: 'sales', onDelete: '' },
  { name: 'return_items_tenant_id_return_id_fkey', table: 'return_items', column: 'return_id', parent: 'returns', onDelete: 'CASCADE' },
  { name: 'po_items_tenant_id_po_id_fkey', table: 'po_items', column: 'po_id', parent: 'purchase_orders', onDelete: 'CASCADE' },
  { name: 'quote_items_tenant_id_quote_id_fkey', table: 'quote_items', column: 'quote_id', parent: 'quotes', onDelete: 'CASCADE' },
  { name: 'drawer_entries_tenant_id_shift_id_fkey', table: 'drawer_entries', column: 'shift_id', parent: 'shifts', onDelete: 'CASCADE' },
] as const;

type IdType = 'UUID' | 'TEXT';

async function dropFks(q: QueryRunner): Promise<void> {
  for (const fk of ENTITY_FKS) {
    await q.query(`ALTER TABLE ${fk.table} DROP CONSTRAINT ${fk.name}`);
  }
}

async function addFks(q: QueryRunner): Promise<void> {
  for (const fk of ENTITY_FKS) {
    const onDelete = fk.onDelete ? ` ON DELETE ${fk.onDelete}` : '';
    await q.query(`
      ALTER TABLE ${fk.table} ADD CONSTRAINT ${fk.name}
        FOREIGN KEY (tenant_id, ${fk.column}) REFERENCES ${fk.parent} (tenant_id, id)${onDelete}`);
  }
}

async function retype(q: QueryRunner, to: IdType): Promise<void> {
  const cast = to === 'UUID' ? 'uuid' : 'text';
  for (const [table, cols] of Object.entries(UUID_ID_COLUMNS)) {
    const alters = cols
      .map((c) => `ALTER COLUMN ${c} TYPE ${to} USING ${c}::${cast}`)
      .join(',\n        ');
    await q.query(`ALTER TABLE ${table}\n        ${alters}`);
  }
}

/** Drop + re-create the three functions with `id <idType>` (`CREATE OR REPLACE` cannot change a RETURNS TABLE). */
async function recreateAuthFunctions(q: QueryRunner, idType: IdType): Promise<void> {
  await q.query(`DROP FUNCTION auth_lookup_device_by_token(TEXT)`);
  await q.query(`
    CREATE FUNCTION auth_lookup_device_by_token(p_token_hash TEXT)
    RETURNS TABLE (
      tenant_id UUID,
      id ${idType},
      role TEXT,
      retired_at TIMESTAMPTZ
    )
    LANGUAGE sql
    SECURITY DEFINER
    SET search_path = public
    AS $$
      SELECT d.tenant_id, d.id, d.role, d.retired_at
      FROM devices d
      WHERE d.token_hash = p_token_hash;
    $$`);
  await q.query(
    `GRANT EXECUTE ON FUNCTION auth_lookup_device_by_token(TEXT) TO ${APP_ROLE}`,
  );

  await q.query(`DROP FUNCTION auth_enrol_device(TEXT, TEXT)`);
  await q.query(`
    CREATE FUNCTION auth_enrol_device(p_code_hash TEXT, p_token_hash TEXT)
    RETURNS TABLE (
      tenant_id UUID,
      id ${idType}
    )
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public
    AS $$
    DECLARE
      v_tenant_id UUID;
      v_id ${idType};
    BEGIN
      SELECT d.tenant_id, d.id INTO v_tenant_id, v_id
      FROM devices d
      WHERE d.enrol_code_hash = p_code_hash
        AND d.enrol_expires_at > now()
        AND d.retired_at IS NULL
      FOR UPDATE;

      IF NOT FOUND THEN
        RETURN;
      END IF;

      UPDATE devices
      SET enrol_code_hash = NULL,
          enrol_expires_at = NULL,
          token_hash = p_token_hash
      WHERE devices.tenant_id = v_tenant_id
        AND devices.id = v_id;

      tenant_id := v_tenant_id;
      id := v_id;
      RETURN NEXT;
    END;
    $$`);
  await q.query(
    `GRANT EXECUTE ON FUNCTION auth_enrol_device(TEXT, TEXT) TO ${APP_ROLE}`,
  );

  await q.query(`DROP FUNCTION auth_lookup_device_and_active_user(TEXT)`);
  await q.query(`
    CREATE FUNCTION auth_lookup_device_and_active_user(p_token_hash TEXT)
    RETURNS TABLE (
      tenant_id UUID,
      id ${idType},
      role TEXT,
      retired_at TIMESTAMPTZ,
      tenant_status TEXT,
      active_user_id UUID,
      active_user_must_change_password BOOLEAN
    )
    LANGUAGE sql
    SECURITY DEFINER
    SET search_path = public
    AS $$
      SELECT
        d.tenant_id,
        d.id,
        d.role,
        d.retired_at,
        t.status AS tenant_status,
        u.id AS active_user_id,
        u.must_change_password AS active_user_must_change_password
      FROM devices d
      JOIN tenants t ON t.id = d.tenant_id
      LEFT JOIN users u ON u.tenant_id = d.tenant_id AND u.is_active = TRUE
      WHERE d.token_hash = p_token_hash;
    $$`);
  await q.query(
    `GRANT EXECUTE ON FUNCTION auth_lookup_device_and_active_user(TEXT) TO ${APP_ROLE}`,
  );
}

export class EntityIdsToUuid1788652804900 implements MigrationInterface {
  name = 'EntityIdsToUuid1788652804900';

  async up(q: QueryRunner): Promise<void> {
    // Most of these tables FORCE row level security. The migration role is the superuser,
    // which bypasses RLS anyway; `row_security = off` makes a non-superuser owner fail
    // loudly instead of counting zero rows through a tenant policy and passing the guard.
    await q.query(`SET LOCAL row_security = off`);
    await q.query(`
      DO $$
      DECLARE
        t TEXT;
        has_rows BOOLEAN;
      BEGIN
        FOREACH t IN ARRAY ARRAY['${GUARDED_TABLES.join("','")}'] LOOP
          EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I)', t) INTO has_rows;
          IF has_rows THEN
            RAISE EXCEPTION 'EntityIdsToUuid needs an empty database (table %)', t;
          END IF;
        END LOOP;
      END
      $$`);

    await dropFks(q);
    await retype(q, 'UUID');
    await addFks(q);
    await recreateAuthFunctions(q, 'UUID');
  }

  async down(q: QueryRunner): Promise<void> {
    await dropFks(q);
    await retype(q, 'TEXT');
    await addFks(q);
    await recreateAuthFunctions(q, 'TEXT');
  }
}
