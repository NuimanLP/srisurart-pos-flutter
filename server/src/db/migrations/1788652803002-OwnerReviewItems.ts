import type { MigrationInterface, QueryRunner } from 'typeorm';
import { APP_ROLE } from './1788652800001-RowLevelSecurity.js';

/**
 * Slice 6 (#281 `review.1`, 08_PHASE2_SPEC §14, §2 C6, 09_PHASE2_LANES §3 line 79):
 *
 * Owner review items table:
 *  - Stores actions/events that require the shop owner's attention / review.
 *  - Tenant-scoped with RLS enabled and forced, fail-closed policy.
 *  - Granted to `pos_app` (SELECT, INSERT, UPDATE, DELETE).
 *  - 5 kinds: 'void_offline', 'credit_override', 'shift_uncounted', 'date_flag', 'device_force_retired'.
 */
export class OwnerReviewItems1788652803002 implements MigrationInterface {
  name = 'OwnerReviewItems1788652803002';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`
      CREATE TABLE owner_review_items (
        tenant_id    UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
        id           TEXT NOT NULL,
        kind         TEXT NOT NULL CHECK (kind IN (
                       'void_offline',
                       'credit_override',
                       'shift_uncounted',
                       'date_flag',
                       'device_force_retired'
                     )),
        ref_id       TEXT NOT NULL,
        details      JSONB NOT NULL DEFAULT '{}',
        created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
        reviewed_at  TIMESTAMPTZ,
        reviewed_by  UUID,
        CONSTRAINT pk_owner_review_items PRIMARY KEY (tenant_id, id),
        FOREIGN KEY (tenant_id, reviewed_by) REFERENCES users (tenant_id, id) ON DELETE SET NULL
      )
    `);

    await q.query(`
      CREATE INDEX idx_owner_review_items_created
        ON owner_review_items (tenant_id, created_at DESC)
    `);

    await q.query(`
      CREATE INDEX idx_owner_review_items_pending
        ON owner_review_items (tenant_id, created_at DESC)
        WHERE reviewed_at IS NULL
    `);

    await q.query(`ALTER TABLE owner_review_items ENABLE ROW LEVEL SECURITY`);
    await q.query(`ALTER TABLE owner_review_items FORCE ROW LEVEL SECURITY`);

    await q.query(`
      CREATE POLICY tenant_isolation_policy ON owner_review_items
        FOR ALL
        USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
        WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid)
    `);

    await q.query(
      `GRANT SELECT, INSERT, UPDATE, DELETE ON owner_review_items TO ${APP_ROLE}`,
    );
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`DROP TABLE IF EXISTS owner_review_items CASCADE`);
  }
}
