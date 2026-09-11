import type { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * #23 — `'void'` joins the `movements.type` enum.
 *
 * A void restores stock, but it is not a return: with no value of its own the row
 * had to be written as `'return'` with a `void:`-prefixed `ref_id` (to stay out of
 * the `uq_movements_ref` slot a credit note wants), and every report grouping by
 * type counted voids as returns. With its own type the bare sale id is free again.
 *
 * Nothing else changes: RLS and the `pos_app` grants are per table (SELECT/INSERT
 * on this ledger) and an `ALTER TABLE … CONSTRAINT` does not disturb them.
 */
export class MovementsVoidType1788652800003 implements MigrationInterface {
  name = 'MovementsVoidType1788652800003';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`
      ALTER TABLE movements DROP CONSTRAINT movements_type_check;
      ALTER TABLE movements ADD CONSTRAINT movements_type_check
        CHECK (type IN ('sale','return','void','receive','adjustment-in','adjustment-out'));
    `);
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`
      ALTER TABLE movements DROP CONSTRAINT movements_type_check;
      ALTER TABLE movements ADD CONSTRAINT movements_type_check
        CHECK (type IN ('sale','return','receive','adjustment-in','adjustment-out'));
    `);
  }
}
