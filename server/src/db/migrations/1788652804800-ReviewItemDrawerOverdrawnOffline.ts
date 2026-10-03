import type { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Owner 2026-10-03 (follow-up to PR #580): an eighth review kind,
 * `drawer_overdrawn_offline`. A cash-out larger than the drawer's expected cash is
 * refused online (`409 DRAWER_INSUFFICIENT_CASH`), but a `/sync/push` `drawer.entry`
 * replay is always accepted — the cash already left the drawer while the till was
 * offline. When such a replay takes the shift's expected cash below zero, the owner
 * gets this item, as with `quote_conflict`.
 *
 * The partial unique index keeps it to one item per drawer entry
 * (`ON CONFLICT DO NOTHING`), as `uq_owner_review_items_quote_conflict` does per bill.
 */
export class ReviewItemDrawerOverdrawnOffline1788652804800 implements MigrationInterface {
  name = 'ReviewItemDrawerOverdrawnOffline1788652804800';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`ALTER TABLE owner_review_items DROP CONSTRAINT ck_owner_review_items_kind`);
    await q.query(`
      ALTER TABLE owner_review_items
        ADD CONSTRAINT ck_owner_review_items_kind CHECK (kind IN (
          'void_offline',
          'credit_override',
          'shift_uncounted',
          'date_flag',
          'device_force_retired',
          'receipt_renumbered',
          'quote_conflict',
          'drawer_overdrawn_offline'
        ))`);
    await q.query(`
      CREATE UNIQUE INDEX uq_owner_review_items_drawer_overdrawn_offline
        ON owner_review_items (tenant_id, ref_id)
        WHERE kind = 'drawer_overdrawn_offline'`);
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`DROP INDEX uq_owner_review_items_drawer_overdrawn_offline`);
    // The 7-kind CHECK cannot be restored over rows of the eighth kind.
    await q.query(`DELETE FROM owner_review_items WHERE kind = 'drawer_overdrawn_offline'`);
    await q.query(`ALTER TABLE owner_review_items DROP CONSTRAINT ck_owner_review_items_kind`);
    await q.query(`
      ALTER TABLE owner_review_items
        ADD CONSTRAINT ck_owner_review_items_kind CHECK (kind IN (
          'void_offline',
          'credit_override',
          'shift_uncounted',
          'date_flag',
          'device_force_retired',
          'receipt_renumbered',
          'quote_conflict'
        ))`);
  }
}
