import type { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Product images (owner request 2026-10-10, contract `product-images-contract.md` §1).
 *
 * `products.image_key`: the first 32 hex characters of the sha256 of the stored preview file
 * (`<tenantId>/<imageKey>_p.webp` in the `product-images` volume) — the file is addressed by
 * its content, so a new image is a new key and a new, immutable URL. NULL = no image. The
 * bytes themselves never enter Postgres.
 *
 * `idx_products_image_key`: the orphan check after a replace/delete ("does any product of
 * this tenant still reference this key?") is an index probe instead of a scan of the tenant's
 * catalogue. Partial: most products have no image.
 *
 * Additive only. RLS already covers `products`; no policy changes.
 */
export class ProductImageKey1788652805100 implements MigrationInterface {
  name = 'ProductImageKey1788652805100';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`ALTER TABLE products ADD COLUMN image_key TEXT`);
    await q.query(`
      ALTER TABLE products ADD CONSTRAINT ck_products_image_key
        CHECK (image_key IS NULL OR image_key ~ '^[0-9a-f]{32}$')`);
    await q.query(`
      CREATE INDEX idx_products_image_key ON products (tenant_id, image_key)
        WHERE image_key IS NOT NULL`);
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`DROP INDEX idx_products_image_key`);
    await q.query(`ALTER TABLE products DROP COLUMN image_key`);
  }
}
