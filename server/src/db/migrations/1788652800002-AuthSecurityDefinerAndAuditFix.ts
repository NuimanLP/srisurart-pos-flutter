import type { MigrationInterface, QueryRunner } from 'typeorm';
import { APP_ROLE } from './1788652800001-RowLevelSecurity.js';

export class AuthSecurityDefinerAndAuditFix1788652800002
  implements MigrationInterface
{
  name = 'AuthSecurityDefinerAndAuditFix1788652800002';

  async up(q: QueryRunner): Promise<void> {
    // 1. Function to lookup device by token hash (across tenants, bypassing RLS safely)
    await q.query(`
      CREATE OR REPLACE FUNCTION auth_lookup_device_by_token(p_token_hash TEXT)
      RETURNS TABLE (
        tenant_id UUID,
        id TEXT,
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
      $$;
    `);

    // 2. Function to lookup user by username (optionally scoped to a tenant if known from device)
    await q.query(`
      CREATE OR REPLACE FUNCTION auth_lookup_user_for_login(p_username TEXT, p_tenant_id UUID DEFAULT NULL)
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
      $$;
    `);

    // 3. Function to atomically enrol a device via one-time enrolment code
    await q.query(`
      CREATE OR REPLACE FUNCTION auth_enrol_device(p_code_hash TEXT, p_token_hash TEXT)
      RETURNS TABLE (
        tenant_id UUID,
        id TEXT
      )
      LANGUAGE plpgsql
      SECURITY DEFINER
      SET search_path = public
      AS $$
      DECLARE
        v_tenant_id UUID;
        v_id TEXT;
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
      $$;
    `);

    // 4. Update audit_log check constraint to accommodate non-user events (device.enrol, auth events)
    await q.query(`
      ALTER TABLE audit_log DROP CONSTRAINT audit_log_check;
      ALTER TABLE audit_log ADD CONSTRAINT audit_log_check
        CHECK (
          user_id IS NOT NULL 
          OR platform_admin_id IS NOT NULL 
          OR action LIKE 'system.%' 
          OR action LIKE 'device.%' 
          OR action LIKE 'auth.%'
        );
    `);

    // 5. Grant EXECUTE permissions to pos_app
    await q.query(
      `GRANT EXECUTE ON FUNCTION auth_lookup_device_by_token(TEXT) TO ${APP_ROLE};`,
    );
    await q.query(
      `GRANT EXECUTE ON FUNCTION auth_lookup_user_for_login(TEXT, UUID) TO ${APP_ROLE};`,
    );
    await q.query(
      `GRANT EXECUTE ON FUNCTION auth_enrol_device(TEXT, TEXT) TO ${APP_ROLE};`,
    );
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(
      `REVOKE EXECUTE ON FUNCTION auth_enrol_device(TEXT, TEXT) FROM ${APP_ROLE};`,
    );
    await q.query(
      `REVOKE EXECUTE ON FUNCTION auth_lookup_user_for_login(TEXT, UUID) FROM ${APP_ROLE};`,
    );
    await q.query(
      `REVOKE EXECUTE ON FUNCTION auth_lookup_device_by_token(TEXT) FROM ${APP_ROLE};`,
    );

    await q.query(`DROP FUNCTION IF EXISTS auth_enrol_device(TEXT, TEXT);`);
    await q.query(
      `DROP FUNCTION IF EXISTS auth_lookup_user_for_login(TEXT, UUID);`,
    );
    await q.query(
      `DROP FUNCTION IF EXISTS auth_lookup_device_by_token(TEXT);`,
    );

    await q.query(`
      ALTER TABLE audit_log DROP CONSTRAINT audit_log_check;
      ALTER TABLE audit_log ADD CONSTRAINT audit_log_check
        CHECK (user_id IS NOT NULL OR platform_admin_id IS NOT NULL OR action LIKE 'system.%');
    `);
  }
}
