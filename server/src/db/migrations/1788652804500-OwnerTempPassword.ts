import type { MigrationInterface, QueryRunner } from 'typeorm';
import { APP_ROLE } from './1788652800001-RowLevelSecurity.js';

/**
 * #443 PR3 — owner password lifecycle v2 (server-generated temporary password + forced change).
 *
 * `users` gets three columns:
 * - `must_change_password` — the current password is a temporary one a platform admin was
 *   handed; login yields only a `typ:'pwchange'` token until the owner sets their own.
 * - `temp_password_expires_at` — 7 days from `POST /platform/tenants`, 24 h from a reset. The
 *   CHECK ties it to the flag so the two can never disagree.
 * - `password_changed_at` — set by a reset and by a successful change; `/auth/refresh` refuses
 *   a refresh token whose `iat` is older (ADR-0009 addendum 2026-09-26).
 *
 * Existing owners get `false` / NULL / NULL: nothing changes for them.
 *
 * Two SECURITY DEFINER functions gain return columns. `CREATE OR REPLACE` cannot change a
 * `RETURNS TABLE`, so each is dropped and re-created, then re-granted to `pos_app` exactly as
 * `1788652800002` / `1788652803003` did. (A login landing inside this migration's own
 * transaction fails for that instant — accepted; migrations run before the new api starts.)
 */
export class OwnerTempPassword1788652804500 implements MigrationInterface {
  name = 'OwnerTempPassword1788652804500';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`
      ALTER TABLE users
        ADD COLUMN must_change_password BOOLEAN NOT NULL DEFAULT FALSE,
        ADD COLUMN temp_password_expires_at TIMESTAMPTZ,
        ADD COLUMN password_changed_at TIMESTAMPTZ`);
    await q.query(`
      ALTER TABLE users
        ADD CONSTRAINT ck_users_temp_password_expiry
        CHECK (must_change_password = (temp_password_expires_at IS NOT NULL))`);

    await q.query(`DROP FUNCTION auth_lookup_user_for_login(TEXT, UUID)`);
    await q.query(`
      CREATE FUNCTION auth_lookup_user_for_login(p_username TEXT, p_tenant_id UUID DEFAULT NULL)
      RETURNS TABLE (
        id UUID,
        tenant_id UUID,
        username TEXT,
        password_hash TEXT,
        role TEXT,
        display_name TEXT,
        is_active BOOLEAN,
        tenant_status TEXT,
        timezone TEXT,
        must_change_password BOOLEAN,
        temp_password_expires_at TIMESTAMPTZ,
        password_changed_at TIMESTAMPTZ
      )
      LANGUAGE sql
      SECURITY DEFINER
      SET search_path = public
      AS $$
        SELECT
          u.id,
          u.tenant_id,
          u.username,
          u.password_hash,
          u.role,
          u.display_name,
          u.is_active,
          t.status AS tenant_status,
          t.timezone,
          u.must_change_password,
          u.temp_password_expires_at,
          u.password_changed_at
        FROM users u
        JOIN tenants t ON u.tenant_id = t.id
        WHERE u.username = p_username
          AND (p_tenant_id IS NULL OR u.tenant_id = p_tenant_id);
      $$`);
    await q.query(
      `GRANT EXECUTE ON FUNCTION auth_lookup_user_for_login(TEXT, UUID) TO ${APP_ROLE}`,
    );

    // Owner decision 2026-09-27 (#443 Q1): an owner still on a temporary password cannot act
    // through `X-Device-Token` (DeviceTokenGuard, `/sync/push`) — otherwise an enrolCode alone
    // would let a device act as the owner before the owner ever chose a password.
    await q.query(`DROP FUNCTION auth_lookup_device_and_active_user(TEXT)`);
    await q.query(`
      CREATE FUNCTION auth_lookup_device_and_active_user(p_token_hash TEXT)
      RETURNS TABLE (
        tenant_id UUID,
        id TEXT,
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

  async down(q: QueryRunner): Promise<void> {
    await q.query(`DROP FUNCTION auth_lookup_device_and_active_user(TEXT)`);
    await q.query(`
      CREATE FUNCTION auth_lookup_device_and_active_user(p_token_hash TEXT)
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
      $$`);
    await q.query(
      `GRANT EXECUTE ON FUNCTION auth_lookup_device_and_active_user(TEXT) TO ${APP_ROLE}`,
    );

    await q.query(`DROP FUNCTION auth_lookup_user_for_login(TEXT, UUID)`);
    await q.query(`
      CREATE FUNCTION auth_lookup_user_for_login(p_username TEXT, p_tenant_id UUID DEFAULT NULL)
      RETURNS TABLE (
        id UUID,
        tenant_id UUID,
        username TEXT,
        password_hash TEXT,
        role TEXT,
        display_name TEXT,
        is_active BOOLEAN,
        tenant_status TEXT,
        timezone TEXT
      )
      LANGUAGE sql
      SECURITY DEFINER
      SET search_path = public
      AS $$
        SELECT
          u.id,
          u.tenant_id,
          u.username,
          u.password_hash,
          u.role,
          u.display_name,
          u.is_active,
          t.status AS tenant_status,
          t.timezone
        FROM users u
        JOIN tenants t ON u.tenant_id = t.id
        WHERE u.username = p_username
          AND (p_tenant_id IS NULL OR u.tenant_id = p_tenant_id);
      $$`);
    await q.query(
      `GRANT EXECUTE ON FUNCTION auth_lookup_user_for_login(TEXT, UUID) TO ${APP_ROLE}`,
    );

    await q.query(`ALTER TABLE users DROP CONSTRAINT ck_users_temp_password_expiry`);
    await q.query(`
      ALTER TABLE users
        DROP COLUMN password_changed_at,
        DROP COLUMN temp_password_expires_at,
        DROP COLUMN must_change_password`);
  }
}
