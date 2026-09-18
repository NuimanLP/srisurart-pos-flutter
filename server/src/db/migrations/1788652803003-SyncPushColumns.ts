import type { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Slice 8-s (#283 `sync.push-server`, 08_PHASE2_SPEC §8, §10, 09_PHASE2_LANES §3 line 81):
 *
 * Adds columns needed by sync push processing:
 *  - `devices.unsynced_ops`: count of outbox operations remaining on device
 *  - `devices.unsynced_reported_at`: timestamp when the device reported outboxRemaining
 *  - `sales.sold_offline`: true when bill was committed offline and pushed to server
 */
const APP_ROLE = process.env.POS_APP_USER ?? 'pos_app';

export class SyncPushColumns1788652803003 implements MigrationInterface {
  name = 'SyncPushColumns1788652803003';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`
      ALTER TABLE devices
        ADD COLUMN unsynced_ops INT NOT NULL DEFAULT 0,
        ADD COLUMN unsynced_reported_at TIMESTAMPTZ;
    `);

    await q.query(`
      ALTER TABLE sales
        ADD COLUMN sold_offline BOOLEAN NOT NULL DEFAULT FALSE,
        ADD COLUMN void_reason TEXT;
    `);

    await q.query(`
      CREATE OR REPLACE FUNCTION auth_lookup_device_and_active_user(p_token_hash TEXT)
      RETURNS TABLE (
        tenant_id UUID,
        id TEXT,
        role TEXT,
        retired_at TIMESTAMPTZ,
        tenant_status TEXT,
        active_user_id UUID
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
          u.id AS active_user_id
        FROM devices d
        JOIN tenants t ON t.id = d.tenant_id
        LEFT JOIN users u ON u.tenant_id = d.tenant_id AND u.is_active = TRUE
        WHERE d.token_hash = p_token_hash;
      $$;
    `);

    await q.query(
      `GRANT EXECUTE ON FUNCTION auth_lookup_device_and_active_user(TEXT) TO ${APP_ROLE};`,
    );
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`DROP FUNCTION IF EXISTS auth_lookup_device_and_active_user(TEXT);`);

    await q.query(`
      ALTER TABLE sales
        DROP COLUMN IF EXISTS void_reason,
        DROP COLUMN IF EXISTS sold_offline;
    `);

    await q.query(`
      ALTER TABLE devices
        DROP COLUMN IF EXISTS unsynced_reported_at,
        DROP COLUMN IF EXISTS unsynced_ops;
    `);
  }
}
