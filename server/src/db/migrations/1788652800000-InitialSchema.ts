import type { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * #15 `p2` — the full phase-1 schema: 27 tables, transcribed from
 * docs/Backend_design/01_DATABASE.md §5. `change_log` (the 28th) is phase 2
 * and is deliberately absent (#15: BIGSERIAL cursor gap bug).
 *
 * Deviations from the doc's DDL, each on purpose:
 * - audit_log PK is (tenant_id, id), not id alone — #2 tenancy rule 2 says every
 *   tenant-scoped table carries tenant_id in its primary key.
 * - movements.type has a CHECK enum and the unique replay guard is PARTIAL
 *   (`WHERE ref_id IS NOT NULL`) so imported legacy adjustments load (#15).
 * - drawer_entries.type has a CHECK ('in','out') the doc only describes in a comment;
 *   likewise tenants.plan CHECK ('basic','demo','loadtest') (#2) and devices.device_no
 *   CHECK 1..99 (ADR-0007: two-digit zero-padded prefix).
 *
 * Access (RLS, grants to pos_app) is the next migration.
 */
export class InitialSchema1788652800000 implements MigrationInterface {
  name = 'InitialSchema1788652800000';

  async up(q: QueryRunner): Promise<void> {
    await q.query(`CREATE EXTENSION IF NOT EXISTS pg_trgm`);

    // ---- system tables (01_DATABASE §5.1) ----------------------------------
    await q.query(`
      CREATE TABLE tenants (
        id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        code          TEXT NOT NULL UNIQUE,
        shop_name     TEXT NOT NULL,
        shop_name_en  TEXT NOT NULL DEFAULT '',
        plan          TEXT NOT NULL DEFAULT 'basic'
                      CHECK (plan IN ('basic','demo','loadtest')),
        status        TEXT NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active','suspended','closed')),
        timezone      TEXT NOT NULL DEFAULT 'Asia/Bangkok',
        created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
      )`);

    await q.query(`
      CREATE TABLE platform_admins (
        id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        username      TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        display_name  TEXT NOT NULL,
        is_active     BOOLEAN NOT NULL DEFAULT TRUE,
        created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
      )`);

    await q.query(`
      CREATE TABLE users (
        tenant_id     UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
        id            UUID NOT NULL DEFAULT gen_random_uuid(),
        username      TEXT NOT NULL,
        password_hash TEXT NOT NULL,
        display_name  TEXT NOT NULL,
        role          TEXT NOT NULL CHECK (role IN ('owner','manager','cashier')),
        pin_hash      TEXT,
        is_active     BOOLEAN NOT NULL DEFAULT TRUE,
        created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (tenant_id, id),
        UNIQUE (tenant_id, username)
      )`);

    await q.query(`
      CREATE TABLE devices (
        tenant_id        UUID NOT NULL,
        id               TEXT NOT NULL,
        label            TEXT NOT NULL,
        device_no        SMALLINT NOT NULL CHECK (device_no BETWEEN 1 AND 99),
        role             TEXT NOT NULL DEFAULT 'backoffice'
                         CHECK (role IN ('pos','backoffice')),
        retired_at       TIMESTAMPTZ,
        enrol_code_hash  TEXT,
        enrol_expires_at TIMESTAMPTZ,
        token_hash       TEXT,
        last_pull_seq    BIGINT NOT NULL DEFAULT 0,
        last_seen_at     TIMESTAMPTZ,
        PRIMARY KEY (tenant_id, id),
        UNIQUE (tenant_id, device_no),
        UNIQUE (token_hash)
      )`);
    await q.query(`
      CREATE UNIQUE INDEX one_pos_per_tenant ON devices (tenant_id)
        WHERE role = 'pos' AND retired_at IS NULL`);

    await q.query(`
      CREATE TABLE idempotency_keys (
        tenant_id     UUID NOT NULL,
        key           TEXT NOT NULL,
        endpoint      TEXT NOT NULL,
        request_hash  TEXT NOT NULL,
        status        TEXT NOT NULL CHECK (status IN ('in_progress','done','failed')),
        response_code INT,
        response_body JSONB,
        created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (tenant_id, key)
      )`);
    await q.query(
      `CREATE INDEX idx_idem_created ON idempotency_keys (created_at)`,
    );

    await q.query(`
      CREATE TABLE doc_counters (
        tenant_id     UUID NOT NULL,
        device_id     TEXT NOT NULL,
        doc_type      TEXT NOT NULL CHECK (doc_type IN ('receipt','po','quote','cn','cp')),
        period        TEXT NOT NULL,
        last_no       INT  NOT NULL DEFAULT 0 CHECK (last_no <= 9999),
        PRIMARY KEY (tenant_id, device_id, doc_type, period)
      )`);

    await q.query(`
      CREATE TABLE audit_log (
        tenant_id         UUID NOT NULL,
        id                BIGSERIAL,
        user_id           UUID,
        platform_admin_id UUID REFERENCES platform_admins (id),
        device_id         TEXT,
        action            TEXT NOT NULL,
        entity            TEXT,
        entity_id         TEXT,
        before            JSONB,
        after             JSONB,
        ip                INET,
        created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (tenant_id, id),
        CHECK (user_id IS NOT NULL OR platform_admin_id IS NOT NULL OR action LIKE 'system.%')
      )`);
    await q.query(
      `CREATE INDEX idx_audit_tenant_time ON audit_log (tenant_id, created_at DESC)`,
    );

    await q.query(`
      CREATE TABLE tenant_meta (
        tenant_id UUID NOT NULL,
        key       TEXT NOT NULL,
        value     TEXT NOT NULL,
        PRIMARY KEY (tenant_id, key)
      )`);

    // ---- catalog & stock (§5.2) --------------------------------------------
    await q.query(`
      CREATE TABLE categories (
        tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
        name      TEXT NOT NULL,
        position  INT  NOT NULL,
        PRIMARY KEY (tenant_id, name)
      )`);

    // No FK products.category → categories: orphaned names are legacy behaviour (§10).
    await q.query(`
      CREATE TABLE products (
        tenant_id  UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
        id         TEXT NOT NULL,
        part_no    TEXT NOT NULL,
        name       TEXT NOT NULL,
        name_th    TEXT NOT NULL,
        category   TEXT NOT NULL,
        brand      TEXT NOT NULL,
        price      NUMERIC(12,2) NOT NULL CHECK (price >= 0),
        cost       NUMERIC(12,2) NOT NULL CHECK (cost  >= 0),
        stock      INT  NOT NULL CHECK (stock >= 0),
        min_stock  INT  NOT NULL DEFAULT 0,
        compat     TEXT,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        deleted_at TIMESTAMPTZ,
        PRIMARY KEY (tenant_id, id)
      )`);
    await q.query(`
      CREATE UNIQUE INDEX uq_products_partno ON products (tenant_id, part_no)
        WHERE deleted_at IS NULL`);
    await q.query(`
      CREATE INDEX idx_products_cat ON products (tenant_id, category) WHERE deleted_at IS NULL`);
    await q.query(`
      CREATE INDEX idx_products_low ON products (tenant_id)
        WHERE stock <= min_stock AND deleted_at IS NULL`);
    await q.query(
      `CREATE INDEX idx_products_updat ON products (tenant_id, updated_at)`,
    );
    // Thai has no word boundaries, so to_tsvector cannot find "เบรก" inside
    // "ผ้าเบรกหน้า". Trigram + ILIKE '%…%' is the only search that matches today's app.
    await q.query(`
      CREATE INDEX idx_products_search ON products USING GIN (
        lower(part_no || ' ' || name || ' ' || name_th || ' ' || COALESCE(compat, '')) gin_trgm_ops
      )`);

    await q.query(`
      CREATE TABLE suppliers (
        tenant_id  UUID NOT NULL,
        id         TEXT NOT NULL,
        product_id TEXT NOT NULL,
        name       TEXT NOT NULL,
        unit_cost  NUMERIC(12,2) NOT NULL,
        freight    NUMERIC(12,2) NOT NULL DEFAULT 0,
        PRIMARY KEY (tenant_id, id),
        FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id) ON DELETE CASCADE
      )`);
    await q.query(
      `CREATE INDEX idx_suppliers_product ON suppliers (tenant_id, product_id)`,
    );

    // Append-only ledger. Written by the server only; ref_id points at the document
    // that caused the row (NULL for imported legacy adjustments).
    await q.query(`
      CREATE TABLE movements (
        tenant_id   UUID NOT NULL,
        id          TEXT NOT NULL,
        product_id  TEXT NOT NULL,
        part_no     TEXT NOT NULL,
        name        TEXT NOT NULL,
        delta       INT  NOT NULL,
        type        TEXT NOT NULL
                    CHECK (type IN ('sale','return','receive','adjustment-in','adjustment-out')),
        note        TEXT,
        stock_after INT  NOT NULL,
        ref_id      TEXT,
        date        TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (tenant_id, id),
        FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id)
      )`);
    await q.query(`
      CREATE INDEX idx_movements_product ON movements (tenant_id, product_id, date DESC)`);
    await q.query(`
      CREATE UNIQUE INDEX uq_movements_ref ON movements (tenant_id, type, ref_id, product_id)
        WHERE ref_id IS NOT NULL`);

    // ---- people & credit (§5.3) --------------------------------------------
    await q.query(`
      CREATE TABLE customers (
        tenant_id   UUID NOT NULL,
        id          TEXT NOT NULL,
        code        TEXT NOT NULL,
        name        TEXT NOT NULL,
        name_th     TEXT NOT NULL,
        phone       TEXT,
        address     TEXT,
        points      INT NOT NULL DEFAULT 0 CHECK (points >= 0),
        total_spend NUMERIC(14,2) NOT NULL DEFAULT 0,
        created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
        deleted_at  TIMESTAMPTZ,
        PRIMARY KEY (tenant_id, id),
        UNIQUE (tenant_id, code)
      )`);
    await q.query(
      `CREATE INDEX idx_customers_phone ON customers (tenant_id, phone)`,
    );

    await q.query(`
      CREATE TABLE mechanics (
        tenant_id      UUID NOT NULL,
        id             TEXT NOT NULL,
        code           TEXT NOT NULL,
        name           TEXT NOT NULL,
        name_th        TEXT,
        nickname       TEXT,
        shop_name      TEXT,
        phone          TEXT,
        note           TEXT,
        credit_limit   NUMERIC(14,2) NOT NULL DEFAULT 0,
        credit_balance NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (credit_balance >= 0),
        total_sales    NUMERIC(14,2) NOT NULL DEFAULT 0,
        total_credit   NUMERIC(14,2) NOT NULL DEFAULT 0,
        total_discount NUMERIC(14,2) NOT NULL DEFAULT 0,
        total_markup   NUMERIC(14,2) NOT NULL DEFAULT 0,
        created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
        deleted_at     TIMESTAMPTZ,
        PRIMARY KEY (tenant_id, id),
        UNIQUE (tenant_id, code)
      )`);

    await q.query(`
      CREATE TABLE credit_payments (
        tenant_id   UUID NOT NULL,
        id          TEXT NOT NULL,
        receipt_no  TEXT NOT NULL,
        mechanic_id TEXT NOT NULL,
        amount      NUMERIC(14,2) NOT NULL CHECK (amount > 0),
        note        TEXT,
        date        TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (tenant_id, id),
        FOREIGN KEY (tenant_id, mechanic_id) REFERENCES mechanics (tenant_id, id),
        UNIQUE (tenant_id, receipt_no)
      )`);
    await q.query(`
      CREATE INDEX idx_creditpay_mech ON credit_payments (tenant_id, mechanic_id, date DESC)`);

    // ---- sales & returns (§5.4) --------------------------------------------
    await q.query(`
      CREATE TABLE sales (
        tenant_id      UUID NOT NULL,
        id             TEXT NOT NULL,
        receipt_no     TEXT NOT NULL,
        subtotal       NUMERIC(12,2) NOT NULL,
        discount       NUMERIC(12,2) NOT NULL DEFAULT 0,
        total          NUMERIC(12,2) NOT NULL,
        payment_method TEXT NOT NULL,
        customer_id    TEXT,
        customer_name  TEXT,
        mechanic_id    TEXT,
        mechanic_name  TEXT,
        mechanic_delta NUMERIC(12,2),
        points_granted INT NOT NULL DEFAULT 0,
        date           TIMESTAMPTZ NOT NULL DEFAULT now(),
        voided         BOOLEAN NOT NULL DEFAULT FALSE,
        voided_at      TIMESTAMPTZ,
        shift_id       TEXT,
        user_id        UUID,
        device_id      TEXT,
        PRIMARY KEY (tenant_id, id),
        UNIQUE (tenant_id, receipt_no),
        FOREIGN KEY (tenant_id, customer_id) REFERENCES customers (tenant_id, id),
        FOREIGN KEY (tenant_id, mechanic_id) REFERENCES mechanics (tenant_id, id)
      )`);
    await q.query(
      `CREATE INDEX idx_sales_date     ON sales (tenant_id, date DESC)`,
    );
    await q.query(
      `CREATE INDEX idx_sales_customer ON sales (tenant_id, customer_id, date DESC)`,
    );
    await q.query(
      `CREATE INDEX idx_sales_mechanic ON sales (tenant_id, mechanic_id, date DESC)`,
    );
    await q.query(
      `CREATE INDEX idx_sales_shift    ON sales (tenant_id, shift_id)`,
    );

    await q.query(`
      CREATE TABLE sale_items (
        tenant_id    UUID NOT NULL,
        sale_id      TEXT NOT NULL,
        line_no      INT  NOT NULL,
        product_id   TEXT NOT NULL,
        part_no      TEXT,
        name         TEXT NOT NULL,
        name_th      TEXT,
        qty          INT  NOT NULL CHECK (qty > 0),
        price        NUMERIC(12,2) NOT NULL,
        cost_at_sale NUMERIC(12,2),
        PRIMARY KEY (tenant_id, sale_id, line_no),
        FOREIGN KEY (tenant_id, sale_id) REFERENCES sales (tenant_id, id) ON DELETE CASCADE
      )`);
    await q.query(
      `CREATE INDEX idx_saleitems_product ON sale_items (tenant_id, product_id)`,
    );

    await q.query(`
      CREATE TABLE returns (
        tenant_id       UUID NOT NULL,
        id              TEXT NOT NULL,
        cn_no           TEXT NOT NULL,
        sale_id         TEXT NOT NULL,
        receipt_no      TEXT NOT NULL,
        refund_subtotal NUMERIC(12,2) NOT NULL,
        refund_discount NUMERIC(12,2) NOT NULL,
        refund_total    NUMERIC(12,2) NOT NULL,
        refund_method   TEXT NOT NULL,
        reason          TEXT NOT NULL DEFAULT '',
        customer_id     TEXT,
        mechanic_id     TEXT,
        mechanic_name   TEXT,
        date            TIMESTAMPTZ NOT NULL DEFAULT now(),
        shift_id        TEXT,
        PRIMARY KEY (tenant_id, id),
        UNIQUE (tenant_id, cn_no),
        FOREIGN KEY (tenant_id, sale_id) REFERENCES sales (tenant_id, id)
      )`);
    await q.query(
      `CREATE INDEX idx_returns_sale ON returns (tenant_id, sale_id)`,
    );
    await q.query(
      `CREATE INDEX idx_returns_date ON returns (tenant_id, date DESC)`,
    );

    await q.query(`
      CREATE TABLE return_items (
        tenant_id    UUID NOT NULL,
        return_id    TEXT NOT NULL,
        line_no      INT  NOT NULL,
        product_id   TEXT NOT NULL,
        name         TEXT NOT NULL,
        qty          INT  NOT NULL CHECK (qty > 0),
        price        NUMERIC(12,2) NOT NULL,
        original_qty INT,
        PRIMARY KEY (tenant_id, return_id, line_no),
        FOREIGN KEY (tenant_id, return_id) REFERENCES returns (tenant_id, id) ON DELETE CASCADE
      )`);

    // ---- purchasing, quotes, parked (§5.5) ---------------------------------
    await q.query(`
      CREATE TABLE purchase_orders (
        tenant_id    UUID NOT NULL,
        id           TEXT NOT NULL,
        po_no        TEXT NOT NULL,
        supplier     TEXT NOT NULL,
        status       TEXT NOT NULL DEFAULT 'open'
                     CHECK (status IN ('open','received','cancelled')),
        created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
        received_at  TIMESTAMPTZ,
        cancelled_at TIMESTAMPTZ,
        PRIMARY KEY (tenant_id, id),
        UNIQUE (tenant_id, po_no)
      )`);
    await q.query(`
      CREATE INDEX idx_po_status ON purchase_orders (tenant_id, status, created_at DESC)`);

    await q.query(`
      CREATE TABLE po_items (
        tenant_id UUID NOT NULL,
        po_id     TEXT NOT NULL,
        line_no   INT  NOT NULL,
        part_no   TEXT NOT NULL,
        name      TEXT NOT NULL,
        qty       INT  NOT NULL CHECK (qty > 0),
        cost      NUMERIC(12,2) NOT NULL CHECK (cost >= 0),
        PRIMARY KEY (tenant_id, po_id, line_no),
        FOREIGN KEY (tenant_id, po_id) REFERENCES purchase_orders (tenant_id, id) ON DELETE CASCADE
      )`);

    await q.query(`
      CREATE TABLE quotes (
        tenant_id         UUID NOT NULL,
        id                TEXT NOT NULL,
        quote_no          TEXT NOT NULL,
        status            TEXT NOT NULL DEFAULT 'open'
                          CHECK (status IN ('open','converted','expired','cancelled')),
        date              TIMESTAMPTZ NOT NULL DEFAULT now(),
        valid_until       TIMESTAMPTZ NOT NULL,
        converted_at      TIMESTAMPTZ,
        converted_sale_id TEXT,
        subtotal          NUMERIC(12,2),
        discount          NUMERIC(12,2),
        total             NUMERIC(12,2),
        customer_name     TEXT,
        customer_phone    TEXT,
        notes             TEXT,
        valid_days        INT,
        PRIMARY KEY (tenant_id, id),
        UNIQUE (tenant_id, quote_no)
      )`);
    await q.query(
      `CREATE INDEX idx_quotes_status ON quotes (tenant_id, status, date DESC)`,
    );

    await q.query(`
      CREATE TABLE quote_items (
        tenant_id  UUID NOT NULL,
        quote_id   TEXT NOT NULL,
        line_no    INT  NOT NULL,
        product_id TEXT,
        name       TEXT NOT NULL,
        qty        INT  NOT NULL CHECK (qty > 0),
        price      NUMERIC(12,2) NOT NULL,
        PRIMARY KEY (tenant_id, quote_id, line_no),
        FOREIGN KEY (tenant_id, quote_id) REFERENCES quotes (tenant_id, id) ON DELETE CASCADE
      )`);

    await q.query(`
      CREATE TABLE parked_sales (
        tenant_id UUID NOT NULL,
        id        TEXT NOT NULL,
        parked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        device_id TEXT,
        payload   JSONB NOT NULL,
        PRIMARY KEY (tenant_id, id)
      )`);

    // ---- cash / shift (§5.6) -----------------------------------------------
    // is_active means "this device's current drawer", not "open" — see the doc.
    await q.query(`
      CREATE TABLE shifts (
        tenant_id     UUID NOT NULL,
        id            TEXT NOT NULL,
        date_str      TEXT NOT NULL,
        starting_cash NUMERIC(12,2) NOT NULL,
        opened_at     TIMESTAMPTZ NOT NULL,
        closed_at     TIMESTAMPTZ,
        physical_cash NUMERIC(12,2),
        is_active     BOOLEAN NOT NULL DEFAULT FALSE,
        auto_archived BOOLEAN NOT NULL DEFAULT FALSE,
        archived_at   TIMESTAMPTZ,
        opened_by     UUID,
        device_id     TEXT,
        PRIMARY KEY (tenant_id, id)
      )`);
    await q.query(`
      CREATE UNIQUE INDEX uq_shift_active ON shifts (tenant_id, device_id) WHERE is_active`);
    await q.query(
      `CREATE INDEX idx_shifts_hist ON shifts (tenant_id, opened_at DESC)`,
    );

    await q.query(`
      CREATE TABLE drawer_entries (
        tenant_id  UUID NOT NULL,
        id         TEXT NOT NULL,
        shift_id   TEXT NOT NULL,
        type       TEXT NOT NULL CHECK (type IN ('in','out')),
        amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
        note       TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        created_by UUID,
        PRIMARY KEY (tenant_id, id),
        FOREIGN KEY (tenant_id, shift_id) REFERENCES shifts (tenant_id, id) ON DELETE CASCADE
      )`);
    await q.query(`
      CREATE INDEX idx_drawer_shift ON drawer_entries (tenant_id, shift_id, created_at DESC)`);

    // ---- settings (§5.7): one row per tenant -------------------------------
    await q.query(`
      CREATE TABLE settings (
        tenant_id        UUID PRIMARY KEY REFERENCES tenants(id) ON DELETE CASCADE,
        shop_name        TEXT NOT NULL,
        shop_name_en     TEXT NOT NULL,
        tax_rate         NUMERIC(5,2) NOT NULL DEFAULT 7,
        quote_valid_days INT NOT NULL DEFAULT 30,
        address          TEXT,
        phone            TEXT,
        cashier_name     TEXT,
        tax_id           TEXT,
        branch_no        TEXT,
        updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
      )`);
  }

  async down(q: QueryRunner): Promise<void> {
    // Reverse dependency order; CASCADE covers the composite FKs.
    for (const t of [
      'settings',
      'drawer_entries',
      'shifts',
      'parked_sales',
      'quote_items',
      'quotes',
      'po_items',
      'purchase_orders',
      'return_items',
      'returns',
      'sale_items',
      'sales',
      'credit_payments',
      'mechanics',
      'customers',
      'movements',
      'suppliers',
      'products',
      'categories',
      'tenant_meta',
      'audit_log',
      'doc_counters',
      'idempotency_keys',
      'devices',
      'users',
      'platform_admins',
      'tenants',
    ]) {
      await q.query(`DROP TABLE IF EXISTS ${t} CASCADE`);
    }
    await q.query(`DROP EXTENSION IF EXISTS pg_trgm`);
  }
}
