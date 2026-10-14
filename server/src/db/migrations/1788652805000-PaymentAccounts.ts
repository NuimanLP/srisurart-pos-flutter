import type { MigrationInterface, QueryRunner } from 'typeorm';
import { APP_ROLE } from './1788652800001-RowLevelSecurity.js';

/**
 * QR payment accounts (owner request 2026-10-10, contract `qr-accounts-contract.md` §1).
 *
 * `payment_accounts`: the shop's QR accounts — PromptPay (the QR carries the amount) or an
 * uploaded static QR image. At most one default per tenant (partial unique index); at most 5
 * active per tenant, enforced by `PaymentAccountsService` under a per-tenant lock, not here.
 * Rows are only ever soft-deleted (`deleted_at`), so an old bill's reference and the account's
 * nickname stay reportable.
 *
 * `sales.payment_account_id`: which account a `โอน/QR` bill was paid into. The FK has **no**
 * ON DELETE action on purpose: rows are never hard-deleted by the app, and an
 * `ON DELETE SET NULL` without a column list would null the NOT NULL `tenant_id` too (the
 * `OwnerReviewItems` bug, fixed by …4200).
 *
 * RLS is created here, with the same `NULLIF(…, '')` policy every other tenant table has
 * (`RowLevelSecurity1788652800001`) — that migration's `TENANT_SCOPED_TABLES` is not edited,
 * because a shipped migration is never edited.
 */
export class PaymentAccounts1788652805000 implements MigrationInterface {
  name = 'PaymentAccounts1788652805000';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`
      CREATE TABLE payment_accounts (
        tenant_id     UUID NOT NULL REFERENCES tenants(id),
        id            UUID NOT NULL,
        nickname      TEXT NOT NULL,
        bank_code     TEXT NOT NULL,
        kind          TEXT NOT NULL,
        promptpay_id  TEXT,
        image         BYTEA,
        image_mime    TEXT,
        is_default    BOOLEAN NOT NULL DEFAULT false,
        sort_order    INT NOT NULL DEFAULT 0,
        created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
        deleted_at    TIMESTAMPTZ,
        CONSTRAINT pk_payment_accounts PRIMARY KEY (tenant_id, id),
        CONSTRAINT ck_payment_accounts_kind CHECK (kind IN ('promptpay', 'image')),
        CONSTRAINT ck_payment_accounts_promptpay CHECK (
          kind <> 'promptpay' OR (promptpay_id IS NOT NULL AND image IS NULL)),
        CONSTRAINT ck_payment_accounts_image CHECK (
          kind <> 'image' OR (image IS NOT NULL AND image_mime IS NOT NULL AND promptpay_id IS NULL)),
        CONSTRAINT ck_payment_accounts_promptpay_digits CHECK (
          promptpay_id IS NULL OR promptpay_id ~ '^[0-9]+$'),
        CONSTRAINT ck_payment_accounts_image_mime CHECK (
          image_mime IS NULL OR image_mime IN ('image/png', 'image/jpeg'))
      )`);

    await q.query(`
      CREATE UNIQUE INDEX uq_payment_accounts_default
        ON payment_accounts (tenant_id)
        WHERE is_default AND deleted_at IS NULL`);
    // `GET /payment-accounts`: the tenant's active rows in display order.
    await q.query(`
      CREATE INDEX idx_payment_accounts_active
        ON payment_accounts (tenant_id, sort_order, created_at)
        WHERE deleted_at IS NULL`);

    await q.query(`ALTER TABLE payment_accounts ENABLE ROW LEVEL SECURITY`);
    await q.query(`ALTER TABLE payment_accounts FORCE ROW LEVEL SECURITY`);
    await q.query(`
      CREATE POLICY tenant_isolation ON payment_accounts
        USING      (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
        WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)`);
    await q.query(`GRANT SELECT, INSERT, UPDATE, DELETE ON payment_accounts TO ${APP_ROLE}`);

    await q.query(`ALTER TABLE sales ADD COLUMN payment_account_id UUID`);
    await q.query(`
      ALTER TABLE sales
        ADD CONSTRAINT fk_sales_payment_account
        FOREIGN KEY (tenant_id, payment_account_id) REFERENCES payment_accounts (tenant_id, id)`);
    await q.query(`
      ALTER TABLE sales
        ADD CONSTRAINT ck_sales_payment_account_qr
        CHECK (payment_account_id IS NULL OR payment_method = 'โอน/QR')`);
  }

  async down(q: QueryRunner): Promise<void> {
    await q.query(`ALTER TABLE sales DROP CONSTRAINT ck_sales_payment_account_qr`);
    await q.query(`ALTER TABLE sales DROP CONSTRAINT fk_sales_payment_account`);
    await q.query(`ALTER TABLE sales DROP COLUMN payment_account_id`);
    await q.query(`DROP TABLE payment_accounts`);
  }
}
