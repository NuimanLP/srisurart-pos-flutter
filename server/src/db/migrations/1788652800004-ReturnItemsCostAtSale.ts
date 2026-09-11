import type { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * #22 — `return_items.cost_at_sale`, the twin of `sale_items.cost_at_sale` (ADR-0008).
 *
 * A credit note has to carry the cost the goods left the shop at, copied from the
 * parent sale line. Re-reading `products.cost` at refund time would be wrong for
 * every historical bill, because a weighted-average PO receive rewrites that column
 * whenever new stock is bought in — profit-after-returns would then drift with the
 * purchase price long after the customer walked out.
 *
 * Nullable on purpose: rows written before this migration have no cost to backfill,
 * and neither does a line whose parent `sale_items.cost_at_sale` is itself NULL
 * (bills imported from the old app, which never stored one).
 *
 * Nothing else changes: RLS and the `pos_app` grants are per table, not per column,
 * so an added column inherits both.
 */
export class ReturnItemsCostAtSale1788652800004 implements MigrationInterface {
  name = 'ReturnItemsCostAtSale1788652800004';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`ALTER TABLE return_items ADD COLUMN cost_at_sale NUMERIC(12,2)`);
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`ALTER TABLE return_items DROP COLUMN cost_at_sale`);
  }
}
