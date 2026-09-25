import type { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Owner 2026-09-25: a sixth review kind, `receipt_renumbered`. `/sync/push` records it
 * when it replays a bill (or credit note) already committed online under a different
 * number than the one printed offline on the device, so a customer holding the offline
 * paper can be traced (08 §10 / §14).
 *
 * `OwnerReviewItems1788652803002` has already run, so its inline (unnamed) CHECK is
 * replaced here; the replacement is named. The partial unique index makes the insert
 * idempotent: the #409 key fall-through replays the same bill on every re-push, and
 * `INSERT … ON CONFLICT DO NOTHING` needs an index to conflict on.
 */
export class ReviewItemReceiptRenumbered1788652804400 implements MigrationInterface {
  name = 'ReviewItemReceiptRenumbered1788652804400';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`ALTER TABLE owner_review_items DROP CONSTRAINT owner_review_items_kind_check`);
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
    await q.query(`
      CREATE UNIQUE INDEX uq_owner_review_items_renumbered
        ON owner_review_items (tenant_id, ref_id)
        WHERE kind = 'receipt_renumbered'`);
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`DROP INDEX uq_owner_review_items_renumbered`);
    // The 5-kind CHECK cannot be restored over rows of the sixth kind.
    await q.query(`DELETE FROM owner_review_items WHERE kind = 'receipt_renumbered'`);
    await q.query(`ALTER TABLE owner_review_items DROP CONSTRAINT ck_owner_review_items_kind`);
    await q.query(`
      ALTER TABLE owner_review_items
        ADD CONSTRAINT owner_review_items_kind_check CHECK (kind IN (
          'void_offline',
          'credit_override',
          'shift_uncounted',
          'date_flag',
          'device_force_retired'
        ))`);
  }
}
