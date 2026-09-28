import type { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * #443 (owner decision 2026-09-28): a platform admin's password changed through
 * `PLATFORM_ADMINS` (or `bootstrap-admin --force`) must kill the admin's older platform tokens.
 * Same column and rule as `users.password_changed_at` (ADR-0009 addendum 2026-09-26):
 * `PlatformAuthGuard` refuses a token whose `iat < floor(epoch(password_changed_at))`.
 *
 * Every admin that already exists when this migration runs is backfilled to `now()`, not left
 * NULL — deploying this fix must log every pre-deploy platform token out once (no `iat` counts
 * as older than any cutoff, so a token minted before #443's fix round would otherwise pass
 * forever). An admin created after this migration starts with NULL, same as `users`.
 */
export class PlatformAdminPasswordChangedAt1788652804600 implements MigrationInterface {
  name = 'PlatformAdminPasswordChangedAt1788652804600';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`ALTER TABLE platform_admins ADD COLUMN password_changed_at TIMESTAMPTZ`);
    await q.query(`UPDATE platform_admins SET password_changed_at = now()`);
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`ALTER TABLE platform_admins DROP COLUMN password_changed_at`);
  }
}
