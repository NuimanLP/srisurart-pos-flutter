import type { MigrationInterface, QueryRunner } from 'typeorm';
import { APP_ROLE } from './1788652800001-RowLevelSecurity.js';

/**
 * Refresh-token rotation with reuse detection (security review 2026-10-21; ADR-0009 addendum
 * 2026-10-22). One row per login's chain of refresh tokens ("family"):
 *
 * - `id` is the jti of the chain's first refresh token — the one `/auth/token` or
 *   `/auth/change-password` issued, which carries no `fid` claim. The row is created by that
 *   token's first refresh, so login itself writes nothing; every token reissued after it carries
 *   `fid` = this id.
 * - `current_jti` is the one token that may rotate next; `previous_jti` the one it replaced,
 *   accepted again only within the grace window (`refresh-rotation.ts`). Any other jti of the
 *   chain is a reuse and sets `revoked_at`, which refuses every token of the chain.
 * - Session state, not business data: not exported, not imported, and `ON DELETE CASCADE` from
 *   `tenants` — a closed tenant never has to clear it first. `user_id`/`device_id` carry no FK
 *   (the `/auth/refresh` checks of `users`/`devices` already run before this row is read).
 * - Rows past `expires_at` (the token's own 04:00 expiry) are pruned by `/auth/refresh` when it
 *   starts a new chain for the same tenant.
 *
 * RLS with the same `NULLIF(…, '')` policy every other tenant table has —
 * `RowLevelSecurity1788652800001`'s `TENANT_SCOPED_TABLES` is not edited (a shipped migration
 * is never edited), as `SalePhotos1788652805200` did.
 */
export class RefreshFamilies1788652805300 implements MigrationInterface {
  name = 'RefreshFamilies1788652805300';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`
      CREATE TABLE refresh_families (
        tenant_id    UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
        id           UUID NOT NULL,
        user_id      UUID NOT NULL,
        device_id    UUID,
        current_jti  UUID NOT NULL,
        previous_jti UUID,
        rotated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
        revoked_at   TIMESTAMPTZ,
        expires_at   TIMESTAMPTZ NOT NULL,
        created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
        CONSTRAINT pk_refresh_families PRIMARY KEY (tenant_id, id)
      )`);
    // The prune of expired chains.
    await q.query(`CREATE INDEX idx_refresh_families_expiry ON refresh_families (tenant_id, expires_at)`);

    await q.query(`ALTER TABLE refresh_families ENABLE ROW LEVEL SECURITY`);
    await q.query(`ALTER TABLE refresh_families FORCE ROW LEVEL SECURITY`);
    await q.query(`
      CREATE POLICY tenant_isolation ON refresh_families
        USING      (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
        WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)`);
    await q.query(`GRANT SELECT, INSERT, UPDATE, DELETE ON refresh_families TO ${APP_ROLE}`);
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`DROP TABLE refresh_families`);
  }
}
