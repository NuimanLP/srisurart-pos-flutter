import type { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Owner 2026-10-03 (#27 follow-up, 08 §6.1): a seventh review kind, `quote_conflict`.
 * `/sync/push` accepts an offline bill sold from a quote cart even when the quote was
 * converted meanwhile, has expired, or is gone — the customer has paid — and leaves
 * the quote untouched; the owner gets this item instead.
 *
 * The partial unique index keeps it to one item per bill (`ON CONFLICT DO NOTHING`),
 * as `uq_owner_review_items_renumbered` does for `receipt_renumbered`.
 */
export class ReviewItemQuoteConflict1788652804700 implements MigrationInterface {
  name = 'ReviewItemQuoteConflict1788652804700';

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
          'quote_conflict'
        ))`);
    await q.query(`
      CREATE UNIQUE INDEX uq_owner_review_items_quote_conflict
        ON owner_review_items (tenant_id, ref_id)
        WHERE kind = 'quote_conflict'`);
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`DROP INDEX uq_owner_review_items_quote_conflict`);
    // The 6-kind CHECK cannot be restored over rows of the seventh kind.
    await q.query(`DELETE FROM owner_review_items WHERE kind = 'quote_conflict'`);
    await q.query(`ALTER TABLE owner_review_items DROP CONSTRAINT ck_owner_review_items_kind`);
    await q.query(`
      ALTER TABLE owner_review_items
        ADD CONSTRAINT ck_owner_review_items_kind CHECK (kind IN (
          'void_offline',
          'credit_override',
          'shift_uncounted',
          'date_flag',
          'device_force_retired',
          'receipt_renumbered'
        ))`);
  }
}
