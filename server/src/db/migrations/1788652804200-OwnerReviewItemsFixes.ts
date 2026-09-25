import type { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Fixes two bugs in `OwnerReviewItems1788652803002` (01_DATABASE.md §11). That
 * migration has already run, so it is left untouched and corrected here.
 *
 * 1. Its RLS policy cast `current_setting('app.tenant_id', true)::uuid` with no
 *    `NULLIF(…, '')`. On a pooled connection that once ran `SET LOCAL app.tenant_id`,
 *    the setting reads back as `''` after COMMIT, so `''::uuid` raised 22P02 (HTTP 500)
 *    instead of failing closed with 0 rows. The policy is recreated exactly like every
 *    other tenant table's (`RowLevelSecurity1788652800001`), name included.
 * 2. `FOREIGN KEY (tenant_id, reviewed_by) … ON DELETE SET NULL` nulled both columns,
 *    and `tenant_id` is NOT NULL, so deleting a user who had reviewed an item failed.
 *    `ON DELETE SET NULL (reviewed_by)` (Postgres 15+; compose pins 16) nulls only the
 *    reviewer.
 */
export class OwnerReviewItemsFixes1788652804200 implements MigrationInterface {
  name = 'OwnerReviewItemsFixes1788652804200';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`DROP POLICY tenant_isolation_policy ON owner_review_items`);
    await q.query(`
      CREATE POLICY tenant_isolation ON owner_review_items
        USING      (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
        WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)`);

    await q.query(
      `ALTER TABLE owner_review_items DROP CONSTRAINT owner_review_items_tenant_id_reviewed_by_fkey`,
    );
    await q.query(`
      ALTER TABLE owner_review_items
        ADD CONSTRAINT owner_review_items_tenant_id_reviewed_by_fkey
        FOREIGN KEY (tenant_id, reviewed_by) REFERENCES users (tenant_id, id)
        ON DELETE SET NULL (reviewed_by)`);
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(
      `ALTER TABLE owner_review_items DROP CONSTRAINT owner_review_items_tenant_id_reviewed_by_fkey`,
    );
    await q.query(`
      ALTER TABLE owner_review_items
        ADD CONSTRAINT owner_review_items_tenant_id_reviewed_by_fkey
        FOREIGN KEY (tenant_id, reviewed_by) REFERENCES users (tenant_id, id)
        ON DELETE SET NULL`);

    await q.query(`DROP POLICY tenant_isolation ON owner_review_items`);
    await q.query(`
      CREATE POLICY tenant_isolation_policy ON owner_review_items
        FOR ALL
        USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
        WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid)`);
  }
}
