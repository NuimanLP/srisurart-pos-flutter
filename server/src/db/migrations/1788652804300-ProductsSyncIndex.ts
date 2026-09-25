import type { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * #417 — products get the same keyset sync index customers and mechanics got in
 * `1788652804000-CustomersMechanicsSyncIndex`.
 *
 * `GET /products?updatedSince=&afterId=` filters `(updated_at, id) > ($ts, $afterId)` and
 * orders by `updated_at, id`. `idx_products_updat (tenant_id, updated_at)` has no `id`, so
 * a page cut inside a tie (one sale or import stamps many rows with one `now()`) re-sorts
 * the tie. The new index's key starts with the old one's, so the old one is dropped.
 *
 * Not `CONCURRENTLY`: each migration runs in its own transaction
 * (`migrationsTransactionMode: 'each'`), same as `1788652804000`.
 */
export class ProductsSyncIndex1788652804300 implements MigrationInterface {
  name = 'ProductsSyncIndex1788652804300';

  async up(q: QueryRunner): Promise<void> {
    await q.query(
      `CREATE INDEX idx_products_sync ON products (tenant_id, updated_at ASC, id ASC)`,
    );
    await q.query(`DROP INDEX idx_products_updat`);
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(
      `CREATE INDEX idx_products_updat ON products (tenant_id, updated_at)`,
    );
    await q.query(`DROP INDEX idx_products_sync`);
  }
}
