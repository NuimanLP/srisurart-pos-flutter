import type { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * #277 — keyset pagination on customers and mechanics sync endpoints.
 *
 * Accelerates `(updated_at, id) > ($ts, $afterId)` keyset sync queries
 * partitioned by tenant.
 */
export class CustomersMechanicsSyncIndex1788652804000 implements MigrationInterface {
  name = 'CustomersMechanicsSyncIndex1788652804000';

  async up(q: QueryRunner): Promise<void> {
    await q.query(
      `CREATE INDEX idx_customers_sync ON customers (tenant_id, updated_at ASC, id ASC)`,
    );
    await q.query(
      `CREATE INDEX idx_mechanics_sync ON mechanics (tenant_id, updated_at ASC, id ASC)`,
    );
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`DROP INDEX idx_customers_sync`);
    await q.query(`DROP INDEX idx_mechanics_sync`);
  }
}
