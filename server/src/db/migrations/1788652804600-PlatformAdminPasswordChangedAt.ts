import type { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * #443 (owner decision 2026-09-28): a platform admin's password changed through
 * `PLATFORM_ADMINS` (or `bootstrap-admin --force`) must kill the admin's older platform tokens.
 * Same column and rule as `users.password_changed_at` (ADR-0009 addendum 2026-09-26):
 * `PlatformAuthGuard` refuses a token whose `iat < floor(epoch(password_changed_at))`.
 * Existing admins get NULL: nothing changes for them until their password next changes.
 */
export class PlatformAdminPasswordChangedAt1788652804600 implements MigrationInterface {
  name = 'PlatformAdminPasswordChangedAt1788652804600';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`ALTER TABLE platform_admins ADD COLUMN password_changed_at TIMESTAMPTZ`);
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`ALTER TABLE platform_admins DROP COLUMN password_changed_at`);
  }
}
