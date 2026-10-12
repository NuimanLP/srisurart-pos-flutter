import type { MigrationInterface, QueryRunner } from 'typeorm';
import { APP_ROLE } from './1788652800001-RowLevelSecurity.js';

/**
 * Sale photo evidence (owner request 2026-10-12, `10_SALE_PHOTO_EVIDENCE.md` §5.1): up to five
 * photos per bill, taken after payment, proving the goods left the shop new and undamaged.
 *
 * - **No FK to `sales`** (owner decision C): a replace-import deletes and re-inserts `sales`,
 *   and the photos must survive it — a bill the file brings back under the same id finds its
 *   photos again. `sale_id` is checked at insert time instead, under the bill's `FOR UPDATE`
 *   lock (`SalePhotosService`). `uploaded_by`/`device_id` carry no FK for the same reason.
 * - `image_key` names the files in the `sale-photos` volume (content-addressed, 32 hex of
 *   sha256(preview)); `source_sha256` is the sha256 of the bytes the client sent and decides a
 *   `photoId` replay — never `image_key`, which a libvips upgrade could change for the same input.
 * - Append-only for `pos_app` (`SELECT, INSERT`), like `audit_log` (#399): v1 has no delete.
 * - The five-per-bill limit is the service's, under the `sales` row lock — not a constraint.
 *
 * RLS is created here with the same `NULLIF(…, '')` policy every other tenant table has —
 * `RowLevelSecurity1788652800001`'s `TENANT_SCOPED_TABLES` is not edited (a shipped migration
 * is never edited), as `PaymentAccounts1788652805000` did.
 */
export class SalePhotos1788652805200 implements MigrationInterface {
  name = 'SalePhotos1788652805200';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`
      CREATE TABLE sale_photos (
        tenant_id      UUID NOT NULL REFERENCES tenants(id),
        id             UUID NOT NULL,
        sale_id        UUID NOT NULL,
        image_key      TEXT NOT NULL,
        source_sha256  TEXT NOT NULL,
        width          INT  NOT NULL,
        height         INT  NOT NULL,
        sort_order     SMALLINT NOT NULL,
        taken_at       TIMESTAMPTZ NOT NULL,
        created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
        uploaded_by    UUID NOT NULL,
        device_id      UUID NOT NULL,
        CONSTRAINT pk_sale_photos PRIMARY KEY (tenant_id, id),
        CONSTRAINT ck_sale_photos_image_key CHECK (image_key ~ '^[0-9a-f]{32}$'),
        CONSTRAINT ck_sale_photos_source CHECK (source_sha256 ~ '^[0-9a-f]{64}$'),
        CONSTRAINT ck_sale_photos_sort CHECK (sort_order BETWEEN 0 AND 4)
      )`);
    // `GET /sales/:saleId/photos` and the per-bill count under the lock.
    await q.query(`CREATE INDEX idx_sale_photos_sale ON sale_photos (tenant_id, sale_id, sort_order, created_at)`);
    // The after-commit "is this file still referenced?" check.
    await q.query(`CREATE INDEX idx_sale_photos_key ON sale_photos (tenant_id, image_key)`);

    await q.query(`ALTER TABLE sale_photos ENABLE ROW LEVEL SECURITY`);
    await q.query(`ALTER TABLE sale_photos FORCE ROW LEVEL SECURITY`);
    await q.query(`
      CREATE POLICY tenant_isolation ON sale_photos
        USING      (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
        WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)`);
    await q.query(`GRANT SELECT, INSERT ON sale_photos TO ${APP_ROLE}`);
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`DROP TABLE sale_photos`);
  }
}
