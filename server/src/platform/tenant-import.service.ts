import {
  BadRequestException,
  ConflictException,
  Inject,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { InjectQueue } from '@nestjs/bullmq';
import { Queue } from 'bullmq';
import { DataSource } from 'typeorm';
import { ADMIN_DATA_SOURCE } from '../infra/db.module.js';
import { TenantCache } from '../infra/tenant-cache.service.js';
import { newId } from '../common/ids.js';
import {
  DEFAULT_JOB_OPTIONS,
  JOB_TENANT_IMPORT,
  QUEUE_TENANT_IMPORT,
  type TenantImportJobPayload,
} from '../queue/queue.constants.js';
import { AuditService } from './audit.service.js';
import { snapshotProductCategory } from './snapshot-category.js';
import {
  describeBadDate,
  describeClamp,
  describeDuplicate,
  planClampViolations,
  planDuplicateDocNumbers,
  planUnparseableDates,
} from './snapshot-preflight.js';
import { countTombstones, fieldId, planTombstones, TombstonePlan, TOMBSTONE_MARK } from './snapshot-tombstones.js';

/**
 * The shop's backup file: the store keys `SnapshotRepository.exportSnapshot()` (a port of
 * db.js) writes and `BackupProcessor` exports — the only shape a real file has. #185 found
 * this class had been written against invented keys (`sa_purchase_orders`, `sa_shifts`,
 * `sa_parked_sales`, category objects), so a real file lost every PO, shift, drawer entry
 * and parked bill and renamed every category to `Cat-<n>` while answering 201.
 */
export class SnapshotPayload {
  sa_products?: Array<Record<string, unknown>>;
  /** An array of names ordered by position; `{ name, position }` objects are tolerated. */
  sa_categories?: Array<string | Record<string, unknown>>;
  sa_customers?: Array<Record<string, unknown>>;
  sa_mechanics?: Array<Record<string, unknown>>;
  sa_sales?: Array<Record<string, unknown>>;
  sa_returns?: Array<Record<string, unknown>>;
  sa_pos?: Array<Record<string, unknown>>;
  sa_quotes?: Array<Record<string, unknown>>;
  sa_movements?: Array<Record<string, unknown>>;
  sa_suppliers?: Array<Record<string, unknown>>;
  sa_credit_payments?: Array<Record<string, unknown>>;
  /** The one active shift (with nested `entries`), or null. JS shifts carry no `id`. */
  sa_cash_drawer?: Record<string, unknown> | null;
  sa_shift_history?: Array<Record<string, unknown>>;
  /** Parked bills: each element is the cart blob itself. */
  sa_parked?: Array<Record<string, unknown>>;
  sa_settings?: Record<string, unknown>;
  __meta?: Record<string, unknown>;
  [key: string]: unknown;
}

export type ImportJobState = 'queued' | 'running' | 'succeeded' | 'failed';

export interface ImportJobResult {
  tombstones: { products: number; customers: number; mechanics: number };
  droppedSuppliers: number;
}

export interface ImportJobStatus extends Partial<ImportJobResult> {
  jobId: string;
  status: ImportJobState;
  error?: string;
}

interface Preflight {
  tombstones: TombstonePlan;
  tombstoneCounts: { products: number; customers: number; mechanics: number };
  droppedSuppliers: number;
}

/**
 * Only ever reached on a value pre-flight (`planClampViolations`'s `finite`/`nonNegMoney`/
 * `positiveMoney` checks) has already accepted — `null`/`undefined` still default to 0 (the
 * same "absent" semantics pre-flight itself uses), but a *present* value that does not parse
 * now throws instead of silently becoming 0 (#239 review). This is defence in depth: getting
 * here on bad data means pre-flight's money coverage missed a field, and #22's lesson is that
 * a clamp on unvalidated input is exactly how that kind of gap stays invisible.
 */
function round2(v: unknown): number {
  if (v == null) return 0;
  const num = typeof v === 'number' ? v : parseFloat(String(v));
  if (isNaN(num)) {
    throw new Error(`round2: unparseable money value ${JSON.stringify(v)} reached the write path — pre-flight should have refused it`);
  }
  return Math.round(num * 100) / 100;
}

/** Only reached once pre-flight has already refused an unparseable value — never a fallback. */
function parseDate(v: unknown): Date {
  if (!v) return new Date();
  if (v instanceof Date) return v;
  const d = new Date(String(v));
  return isNaN(d.getTime()) ? new Date() : d;
}

/** Postgres unique-violation (23505) on the named constraint. */
function isUniqueViolationOn(err: unknown, constraint: string): boolean {
  const e = err as { code?: string; constraint?: string } | null;
  return e?.code === '23505' && e?.constraint === constraint;
}

/**
 * #239 review: a worker crash or a BullMQ-detected stall can leave `import_jobs.status`
 * stuck at `'queued'`/`'running'` forever — nothing ever transitions it, and
 * `uq_import_jobs_active` then refuses every future import for that tenant. `createJob`
 * treats an in-flight row older than this as abandoned before it tries to insert a new one.
 *
 * 30 minutes against a measured worst case of well under two: 6.4 s/2 MiB locally, so a
 * 10 MiB file (`IMPORT_BODY_LIMIT`) is ≈32 s; `DEFAULT_JOB_OPTIONS` retries up to 3 times
 * with exponential-jitter backoff (≤ 1 + 2 + 4 s between attempts), so a job that is
 * genuinely still working — including through two retries — finishes in ≈100 s. 30 minutes
 * is deliberately far past that: it should only ever fire for a worker that is truly gone,
 * never for one that is merely slow.
 */
const STALE_JOB_CEILING_MINUTES = 30;

@Injectable()
export class TenantImportService {
  constructor(
    @Inject(ADMIN_DATA_SOURCE) private readonly adminDs: DataSource,
    private readonly auditService: AuditService,
    private readonly cache: TenantCache,
    @InjectQueue(QUEUE_TENANT_IMPORT) private readonly importQueue: Queue,
  ) {}

  // ── §9 step 2: pre-flight — reads the snapshot (+ one existence check), writes nothing ──
  private async preflight(tenantId: string, snapshot: SnapshotPayload): Promise<Preflight> {
    if (!snapshot.__meta) {
      throw new BadRequestException('ไฟล์สำรองไม่ถูกต้อง — ไม่พบข้อมูล __meta');
    }

    // 1. Verify tenant already has no transactional rows
    const checkTables = ['sales', 'returns', 'purchase_orders', 'credit_payments', 'quotes', 'shifts'];
    for (const table of checkTables) {
      const res = await this.adminDs.query(`SELECT count(*)::int AS n FROM ${table} WHERE tenant_id = $1`, [tenantId]);
      if (res[0].n > 0) {
        throw new ConflictException(`Tenant already has transaction data in table '${table}' — import rejected`);
      }
    }

    // 2. Pre-flight scan
    const products = snapshot.sa_products || [];
    for (const p of products) {
      const stock = Number(p.stock ?? 0);
      if (stock < 0) {
        throw new BadRequestException(`Pre-flight failed: product '${p.name || p.id}' has negative stock (${stock})`);
      }
    }
    // Every imported product is written live, and `uq_products_partno_ci` (#16) refuses
    // two live part numbers that differ only by case. Drift has no such constraint, so a
    // real backup can hold them; without this the import dies mid-transaction as a 500.
    // The part number is derived exactly as the insert below derives it, and a repeated
    // id is not a clash (the insert keeps the first and skips the rest).
    const idsByPartNo = new Map<string, Set<string>>();
    for (const p of products) {
      const id = String(p.id);
      const key = String(p.partNo || p.part_no || id).toLowerCase();
      idsByPartNo.set(key, (idsByPartNo.get(key) ?? new Set()).add(id));
    }
    for (const [partNo, ids] of idsByPartNo) {
      if (ids.size > 1) {
        throw new BadRequestException(
          `Pre-flight failed: products ${[...ids].map((id) => `'${id}'`).join(', ')} share part number '${partNo}' (case-insensitive)`,
        );
      }
    }

    const categories = snapshot.sa_categories || [];
    for (let i = 0; i < categories.length; i++) {
      const cat = categories[i];
      if (cat && typeof cat === 'object' && cat.position != null && !Number.isFinite(Number(cat.position))) {
        throw new BadRequestException(
          `Pre-flight failed: category '${String(cat.name)}' has a non-numeric position (${String(cat.position)})`,
        );
      }
    }

    // #239 item 1: a document number two different rows share raises the DB's own
    // `UNIQUE (tenant_id, …)` mid-transaction as an unnamed 23505 — refuse here instead,
    // naming every id that collides.
    const duplicateNumbers = planDuplicateDocNumbers(snapshot);
    if (duplicateNumbers.length > 0) {
      throw new BadRequestException(`Pre-flight failed: duplicate document numbers — ${duplicateNumbers.map(describeDuplicate).join('; ')}`);
    }

    // #239 item 2: `parseDate()` used to fall back to `new Date()` on anything it could not
    // read, moving a bill into *import time* with no error — refuse here instead.
    const badDates = planUnparseableDates(snapshot);
    if (badDates.length > 0) {
      throw new BadRequestException(`Pre-flight failed: unparseable dates — ${badDates.map(describeBadDate).join('; ')}`);
    }

    // #239 item 3 (the #22 lesson applied to import): a negative balance/points/`minStock`,
    // a sale/return/PO/quote line's `qty` of zero, negative, non-integer or missing, or a
    // money field (`round2()` used to turn a NaN one into 0 for every price/cost/total in
    // the file — review round after the first cut of this fix) — all used to clamp or
    // silently default with no error. Refuse before the importer's own clamp/round ever runs.
    const clampViolations = planClampViolations(snapshot);
    if (clampViolations.length > 0) {
      throw new BadRequestException(`Pre-flight failed: values needing a clamp are refused instead — ${clampViolations.map(describeClamp).join('; ')}`);
    }

    // #238: references to rows the shop hard-deleted become soft-deleted tombstones. A
    // reference no tombstone can be named for — or a credit note with no bill — is refused
    // here, with the ids, instead of dying on a foreign key mid-transaction as a 500.
    const tombstones = planTombstones(snapshot);
    // #252 review: a row missing its own required reference id entirely (never `String(undefined)`).
    if (tombstones.missingRefs.length > 0) {
      throw new BadRequestException(`Pre-flight failed: rows are missing a required reference id: ${tombstones.missingRefs.join(', ')}`);
    }
    if (tombstones.unnamed.length > 0) {
      throw new BadRequestException(`Pre-flight failed: history references rows missing from the file with no name to keep: ${tombstones.unnamed.join(', ')}`);
    }
    if (tombstones.returnsWithoutSale.length > 0) {
      throw new BadRequestException(`Pre-flight failed: credit notes reference bills missing from the file: ${tombstones.returnsWithoutSale.join(', ')}`);
    }

    return {
      tombstones,
      tombstoneCounts: countTombstones(tombstones),
      droppedSuppliers: tombstones.droppedSuppliers.length,
    };
  }

  // ── §9 steps 3-4: the single-transaction import ──────────────────────────────────────
  /**
   * `jobId`, when given, is `processJob`'s — the row's `status = 'succeeded'` (+ `result`,
   * cleared `payload`) is written as the transaction's own last statement (#239 review),
   * atomically with the business data, via `manager` (never `this.adminDs`). A crash between
   * this `COMMIT` and some separate follow-up write can therefore never happen — there is no
   * separate write: either both commit or neither does. `importSnapshot()` (the synchronous,
   * no-job convenience wrapper) calls this with no `jobId` and skips the update entirely —
   * there is no `import_jobs` row for it to touch.
   */
  private async writeSnapshot(
    tenantId: string,
    snapshot: SnapshotPayload,
    adminId: string,
    ip: string | undefined,
    plan: Preflight,
    jobId?: string,
  ): Promise<ImportJobResult> {
    const { tombstones, tombstoneCounts, droppedSuppliers } = plan;
    const droppedSupplierIds = new Set(tombstones.droppedSuppliers);
    const products = snapshot.sa_products || [];
    const categories = snapshot.sa_categories || [];
    const result: ImportJobResult = { tombstones: tombstoneCounts, droppedSuppliers };

    await this.adminDs.transaction(async (manager) => {
      // 3.1 Categories
      const categoryNames = new Set<string>();
      for (let i = 0; i < categories.length; i++) {
        const cat = categories[i];
        const entry = typeof cat === 'string' ? { name: cat } : (cat ?? {});
        if (entry.name == null) continue;
        const name = String(entry.name);
        const pos = Number(entry.position ?? i);
        categoryNames.add(name);
        await manager.query(
          `INSERT INTO categories (tenant_id, name, position)
           VALUES ($1, $2, $3)
           ON CONFLICT (tenant_id, name) DO UPDATE SET position = EXCLUDED.position`,
          [tenantId, name, pos],
        );
      }
      // 01 §9: a category products still name but the list lost is created (after the
      // listed ones), never left as an orphan — Drift's deleteCategory never touched products.
      let nextPosition = categories.length;
      for (const name of new Set(products.map(snapshotProductCategory))) {
        if (categoryNames.has(name)) continue;
        await manager.query(
          `INSERT INTO categories (tenant_id, name, position)
           VALUES ($1, $2, $3)
           ON CONFLICT (tenant_id, name) DO NOTHING`,
          [tenantId, name, nextPosition++],
        );
      }

      // 3.2 Products. Pre-flight already refused a negative `stock`/`minStock`, so `Math.floor`
      // here rounds off float noise only — it is not a clamp on unvalidated input (#239 item 3).
      for (const p of products) {
        const id = String(p.id);
        const partNo = String(p.partNo || p.part_no || id);
        const name = String(p.name || '');
        const nameTh = String(p.nameTH || p.name_th || name);
        const category = snapshotProductCategory(p);
        const brand = String(p.brand || 'ทั่วไป');
        const price = round2(p.price);
        const cost = round2(p.cost);
        const stock = Math.floor(Number(p.stock ?? 0));
        const minStock = Math.floor(Number(p.minStock ?? p.min_stock ?? 0));
        const compat = p.compat ? String(p.compat) : null;
        // #239 item 4: honoured defensively — no real export carries this field today (products
        // have no `deletedAt` client-side, #55), but a file that ever does must import
        // soft-deleted, not live. Pre-flight already refused an unparseable value.
        const deletedAtRaw = p.deletedAt ?? p.deleted_at;
        const deletedAt = deletedAtRaw != null ? parseDate(deletedAtRaw) : null;

        await manager.query(
          `INSERT INTO products (tenant_id, id, part_no, name, name_th, category, brand, price, cost, stock, min_stock, compat, updated_at, deleted_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, clock_timestamp(), $13)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId, id, partNo, name, nameTh, category, brand, price, cost, stock, minStock, compat, deletedAt],
        );
      }

      // 3.2b Product tombstones (#238): soft-deleted, so `uq_products_partno(_ci)` — both
      // partial on `deleted_at IS NULL` — never compare them with a live part number.
      // #252 review: no `ON CONFLICT DO NOTHING` — the plan guarantees a tombstone id is
      // never a live product id, so a conflict here means the plan is wrong and must fail
      // loudly, not silently keep whichever row got there first.
      for (const t of tombstones.products) {
        await manager.query(
          `INSERT INTO products (tenant_id, id, part_no, name, name_th, category, brand, price, cost, stock, min_stock, updated_at, deleted_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, 0, 0, 0, 0, clock_timestamp(), clock_timestamp())`,
          [tenantId, t.id, t.partNo, t.name, t.nameTh, snapshotProductCategory({}), TOMBSTONE_MARK],
        );
      }

      // 3.3 Suppliers. #252 (owner, 2026-09-15): a row whose product is gone and not
      // otherwise tombstoned (`tombstones.droppedSuppliers`) is skipped, not inserted — see
      // snapshot-tombstones.ts.
      const suppliers = snapshot.sa_suppliers || [];
      for (const sup of suppliers) {
        const id = String(sup.id);
        if (droppedSupplierIds.has(id)) continue;
        const productId = fieldId(sup, 'productId', 'product_id')!;
        const name = String(sup.name || '');
        const unitCost = round2(sup.unitCost || sup.unit_cost);
        const freight = round2(sup.freight);
        await manager.query(
          `INSERT INTO suppliers (tenant_id, id, product_id, name, unit_cost, freight)
           VALUES ($1, $2, $3, $4, $5, $6)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId, id, productId, name, unitCost, freight],
        );
      }

      // 3.4 Customers. #239 item 4: a customer the shop soft-deleted in Drift (schema v2's
      // `deletedAt`) but is still present in the file imports soft-deleted, not live — the
      // ledger values (points/spend) are the real ones, only `deleted_at` differs from a
      // tombstone (which invents zeroed placeholder rows for ids absent from the file).
      const customers = snapshot.sa_customers || [];
      for (const c of customers) {
        const id = String(c.id);
        const code = String(c.code || `CUS-${id}`);
        const name = String(c.name || '');
        const nameTh = String(c.nameTH || c.name_th || name);
        const phone = c.phone ? String(c.phone) : null;
        const address = c.address ? String(c.address) : null;
        const points = Math.floor(Number(c.points ?? 0));
        const totalSpend = round2(c.totalSpend || c.total_spend);
        const createdAt = parseDate(c.createdAt || c.created_at);
        const deletedAtRaw = c.deletedAt ?? c.deleted_at;
        const deletedAt = deletedAtRaw != null ? parseDate(deletedAtRaw) : null;

        await manager.query(
          `INSERT INTO customers (tenant_id, id, code, name, name_th, phone, address, points, total_spend, created_at, deleted_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId, id, code, name, nameTh, phone, address, points, totalSpend, createdAt, deletedAt],
        );
      }

      // 3.4b Customer tombstones (#238): zero points/spend, code `import-tombstone:<id>`.
      // #252 review: no `ON CONFLICT DO NOTHING` — see the product tombstone note above.
      for (const t of tombstones.customers) {
        await manager.query(
          `INSERT INTO customers (tenant_id, id, code, name, name_th, points, total_spend, deleted_at)
           VALUES ($1, $2, $3, $4, $4, 0, 0, clock_timestamp())`,
          [tenantId, t.id, t.code, t.name],
        );
      }

      // 3.5 Mechanics. #239 item 4: same rule as customers above.
      const mechanics = snapshot.sa_mechanics || [];
      for (const m of mechanics) {
        const id = String(m.id);
        const code = String(m.code || `M-${id}`);
        const name = String(m.name || '');
        const nameTh = m.nameTH || m.name_th ? String(m.nameTH || m.name_th) : null;
        const nickname = m.nickname ? String(m.nickname) : null;
        const shopName = m.shopName || m.shop_name ? String(m.shopName || m.shop_name) : null;
        const phone = m.phone ? String(m.phone) : null;
        const note = m.note ? String(m.note) : null;
        const creditLimit = round2(m.creditLimit || m.credit_limit);
        const creditBalance = round2(m.creditBalance || m.credit_balance);
        const totalSales = round2(m.totalSales || m.total_sales);
        const totalCredit = round2(m.totalCredit || m.total_credit);
        const totalDiscount = round2(m.totalDiscount || m.total_discount);
        const totalMarkup = round2(m.totalMarkup || m.total_markup);
        const createdAt = parseDate(m.createdAt || m.created_at);
        const deletedAtRaw = m.deletedAt ?? m.deleted_at;
        const deletedAt = deletedAtRaw != null ? parseDate(deletedAtRaw) : null;

        await manager.query(
          `INSERT INTO mechanics (tenant_id, id, code, name, name_th, nickname, shop_name, phone, note, credit_limit, credit_balance, total_sales, total_credit, total_discount, total_markup, created_at, deleted_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [
            tenantId, id, code, name, nameTh, nickname, shopName, phone, note,
            creditLimit, creditBalance, totalSales, totalCredit, totalDiscount, totalMarkup, createdAt, deletedAt,
          ],
        );
      }

      // 3.5b Mechanic tombstones (#238): zero balance and totals, code `import-tombstone:<id>`,
      // written explicitly (like the customer tombstone above) rather than left to the
      // column defaults. #252 review: no `ON CONFLICT DO NOTHING` — see the product note above.
      for (const t of tombstones.mechanics) {
        await manager.query(
          `INSERT INTO mechanics (tenant_id, id, code, name, credit_limit, credit_balance, total_sales, total_credit, total_discount, total_markup, deleted_at)
           VALUES ($1, $2, $3, $4, 0, 0, 0, 0, 0, 0, clock_timestamp())`,
          [tenantId, t.id, t.code, t.name],
        );
      }

      // 3.6 Sales & SaleItems. Pre-flight already refused a negative `pointsGranted` and any
      // line `qty` that was not a positive whole number (#239 item 3).
      const sales = snapshot.sa_sales || [];
      for (const s of sales) {
        const id = String(s.id);
        const receiptNo = String(s.receiptNo || s.receipt_no || `RC-${id}`);
        const subtotal = round2(s.subtotal);
        const discount = round2(s.discount);
        const total = round2(s.total);
        const paymentMethod = String(s.paymentMethod || s.payment_method || 'เงินสด');
        const customerId = fieldId(s, 'customerId', 'customer_id');
        const customerName = s.customerName || s.customer_name ? String(s.customerName || s.customer_name) : null;
        const mechanicId = fieldId(s, 'mechanicId', 'mechanic_id');
        const mechanicName = s.mechanicName || s.mechanic_name ? String(s.mechanicName || s.mechanic_name) : null;
        const mechanicDelta = s.mechanicDelta != null ? round2(s.mechanicDelta) : null;
        const pointsGranted = Math.floor(Number(s.pointsGranted ?? s.points_granted ?? 0));
        const date = parseDate(s.date);
        const voided = Boolean(s.voided);
        const voidedAt = s.voidedAt ? parseDate(s.voidedAt) : null;

        await manager.query(
          `INSERT INTO sales (tenant_id, id, receipt_no, subtotal, discount, total, payment_method, customer_id, customer_name, mechanic_id, mechanic_name, mechanic_delta, points_granted, date, voided, voided_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [
            tenantId, id, receiptNo, subtotal, discount, total, paymentMethod,
            customerId, customerName, mechanicId, mechanicName, mechanicDelta,
            pointsGranted, date, voided, voidedAt,
          ],
        );

        const items = (s.items as Array<Record<string, unknown>>) || [];
        for (let i = 0; i < items.length; i++) {
          const item = items[i];
          const lineNo = i + 1;
          const productId = String(item.productId || item.product_id || `p_${i}`);
          const partNo = item.partNo || item.part_no ? String(item.partNo || item.part_no) : null;
          const name = String(item.name || '');
          const nameTh = item.nameTH || item.name_th ? String(item.nameTH || item.name_th) : null;
          const qty = Math.floor(Number(item.qty));
          const price = round2(item.price);
          // The file carries the cost at sale as `cost` (exportSnapshot, ADR-0008).
          const costRaw = item.costAtSale ?? item.cost;
          const costAtSale = costRaw != null ? round2(costRaw) : null;

          await manager.query(
            `INSERT INTO sale_items (tenant_id, sale_id, line_no, product_id, part_no, name, name_th, qty, price, cost_at_sale)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
             ON CONFLICT (tenant_id, sale_id, line_no) DO NOTHING`,
            [tenantId, id, lineNo, productId, partNo, name, nameTh, qty, price, costAtSale],
          );
        }
      }

      // 3.7 Returns & ReturnItems
      const returns = snapshot.sa_returns || [];
      for (const r of returns) {
        const id = String(r.id);
        const cnNo = String(r.cnNo || r.cn_no || `CN-${id}`);
        // Non-null: every return whose sale is absent or unnamed is in `returnsWithoutSale`,
        // refused in pre-flight above.
        const saleId = fieldId(r, 'saleId', 'sale_id')!;
        const receiptNo = String(r.receiptNo || r.receipt_no || '');
        const refundSubtotal = round2(r.refundSubtotal || r.refund_subtotal);
        const refundDiscount = round2(r.refundDiscount || r.refund_discount);
        const refundTotal = round2(r.refundTotal || r.refund_total);
        const refundMethod = String(r.refundMethod || r.refund_method || 'เงินสด');
        const reason = String(r.reason || '');
        const customerId = fieldId(r, 'customerId', 'customer_id');
        const mechanicId = fieldId(r, 'mechanicId', 'mechanic_id');
        const mechanicName = r.mechanicName || r.mechanic_name ? String(r.mechanicName || r.mechanic_name) : null;
        const date = parseDate(r.date);

        await manager.query(
          `INSERT INTO returns (tenant_id, id, cn_no, sale_id, receipt_no, refund_subtotal, refund_discount, refund_total, refund_method, reason, customer_id, mechanic_id, mechanic_name, date)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [
            tenantId, id, cnNo, saleId, receiptNo, refundSubtotal, refundDiscount,
            refundTotal, refundMethod, reason, customerId, mechanicId, mechanicName, date,
          ],
        );

        const items = (r.items as Array<Record<string, unknown>>) || [];
        for (let i = 0; i < items.length; i++) {
          const item = items[i];
          const lineNo = i + 1;
          const productId = String(item.productId || item.product_id);
          const name = String(item.name || '');
          const qty = Math.floor(Number(item.qty));
          const price = round2(item.price);
          const originalQty = item.originalQty != null ? Number(item.originalQty) : null;

          await manager.query(
            `INSERT INTO return_items (tenant_id, return_id, line_no, product_id, name, qty, price, original_qty)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
             ON CONFLICT (tenant_id, return_id, line_no) DO NOTHING`,
            [tenantId, id, lineNo, productId, name, qty, price, originalQty],
          );
        }
      }

      // 3.8 CreditPayments
      const creditPayments = snapshot.sa_credit_payments || [];
      for (const cp of creditPayments) {
        const id = String(cp.id);
        const receiptNo = String(cp.receiptNo || cp.receipt_no || `CP-${id}`);
        // Non-null: a row with no mechanic id at all is in `missingRefs`, refused above.
        const mechanicId = fieldId(cp, 'mechanicId', 'mechanic_id')!;
        const amount = round2(cp.amount);
        const note = cp.note ? String(cp.note) : null;
        const date = parseDate(cp.date);
        // The JS app stored the method on the payment and its drawer summed
        // `p.method === 'เงินสด'`; the Drift port has no such column, so a snapshot
        // from either one may or may not carry it. Left NULL when it does not —
        // #24's migration explains why that is not defaulted to cash.
        const paymentMethod = cp.method ? String(cp.method) : null;

        await manager.query(
          `INSERT INTO credit_payments (tenant_id, id, receipt_no, mechanic_id, amount, payment_method, note, date)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId, id, receiptNo, mechanicId, amount, paymentMethod, note, date],
        );
      }

      // 3.9 PurchaseOrders & PoItems
      const pos = snapshot.sa_pos || [];
      for (const po of pos) {
        const id = String(po.id);
        const poNo = String(po.poNo || po.po_no || `PO-${id}`);
        const supplier = String(po.supplier || '');
        const status = String(po.status || 'open');
        const createdAt = parseDate(po.createdAt || po.created_at);
        const receivedAt = po.receivedAt || po.received_at ? parseDate(po.receivedAt || po.received_at) : null;
        const cancelledAt = po.cancelledAt || po.cancelled_at ? parseDate(po.cancelledAt || po.cancelled_at) : null;

        await manager.query(
          `INSERT INTO purchase_orders (tenant_id, id, po_no, supplier, status, created_at, received_at, cancelled_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId, id, poNo, supplier, status, createdAt, receivedAt, cancelledAt],
        );

        const items = (po.items as Array<Record<string, unknown>>) || [];
        for (let i = 0; i < items.length; i++) {
          const item = items[i];
          const lineNo = i + 1;
          const partNo = String(item.partNo || item.part_no || '');
          const name = String(item.name || '');
          const qty = Math.floor(Number(item.qty));
          const cost = round2(item.cost);

          await manager.query(
            `INSERT INTO po_items (tenant_id, po_id, line_no, part_no, name, qty, cost)
             VALUES ($1, $2, $3, $4, $5, $6, $7)
             ON CONFLICT (tenant_id, po_id, line_no) DO NOTHING`,
            [tenantId, id, lineNo, partNo, name, qty, cost],
          );
        }
      }

      // 3.10 Quotes & QuoteItems
      const quotes = snapshot.sa_quotes || [];
      for (const q of quotes) {
        const id = String(q.id);
        const quoteNo = String(q.quoteNo || q.quote_no || `QT-${id}`);
        const status = String(q.status || 'open');
        const date = parseDate(q.date);
        const validUntil = parseDate(q.validUntil || q.valid_until || new Date(date.getTime() + 30 * 86400 * 1000));
        const convertedAt = q.convertedAt || q.converted_at ? parseDate(q.convertedAt || q.converted_at) : null;
        const convertedSaleId = q.convertedSaleId || q.converted_sale_id ? String(q.convertedSaleId || q.converted_sale_id) : null;
        const subtotal = q.subtotal != null ? round2(q.subtotal) : null;
        const discount = q.discount != null ? round2(q.discount) : null;
        const total = q.total != null ? round2(q.total) : null;
        const customerName = q.customerName || q.customer_name ? String(q.customerName || q.customer_name) : null;
        const customerPhone = q.customerPhone || q.customer_phone ? String(q.customerPhone || q.customer_phone) : null;
        const notes = q.notes ? String(q.notes) : null;
        const validDays = q.validDays != null ? Number(q.validDays) : null;

        await manager.query(
          `INSERT INTO quotes (tenant_id, id, quote_no, status, date, valid_until, converted_at, converted_sale_id, subtotal, discount, total, customer_name, customer_phone, notes, valid_days)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [
            tenantId, id, quoteNo, status, date, validUntil, convertedAt, convertedSaleId,
            subtotal, discount, total, customerName, customerPhone, notes, validDays,
          ],
        );

        const items = (q.items as Array<Record<string, unknown>>) || [];
        for (let i = 0; i < items.length; i++) {
          const item = items[i];
          const lineNo = i + 1;
          const productId = item.productId || item.product_id ? String(item.productId || item.product_id) : null;
          const name = String(item.name || '');
          const qty = Math.floor(Number(item.qty));
          const price = round2(item.price);

          await manager.query(
            `INSERT INTO quote_items (tenant_id, quote_id, line_no, product_id, name, qty, price)
             VALUES ($1, $2, $3, $4, $5, $6, $7)
             ON CONFLICT (tenant_id, quote_id, line_no) DO NOTHING`,
            [tenantId, id, lineNo, productId, name, qty, price],
          );
        }
      }

      // 3.11 Movements
      const movements = snapshot.sa_movements || [];
      for (const m of movements) {
        const id = String(m.id);
        // Non-null: a movement with no product id at all is in `missingRefs`, refused above.
        const productId = fieldId(m, 'productId', 'product_id')!;
        const partNo = String(m.partNo || m.part_no || '');
        const name = String(m.name || '');
        const delta = Math.floor(Number(m.delta ?? 0));
        const type = String(m.type || 'adjustment-in');
        const note = m.note ? String(m.note) : null;
        const stockAfter = Math.floor(Number(m.stockAfter ?? m.stock_after ?? 0));
        const refId = m.refId || m.ref_id ? String(m.refId || m.ref_id) : null;
        const date = parseDate(m.date);

        await manager.query(
          `INSERT INTO movements (tenant_id, id, product_id, part_no, name, delta, type, note, stock_after, ref_id, date)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId, id, productId, partNo, name, delta, type, note, stockAfter, refId, date],
        );
      }

      // 3.12 Shifts & nested drawer entries: sa_cash_drawer (the active shift) + sa_shift_history.
      // A JS/Drift shift carries no id (01 §9), so one is issued as sh_{date}_{n}; a server
      // export (BackupProcessor) keeps its own.
      //
      // 🔴 Every imported shift is archived (`is_active = false`), the file's drawer included.
      // An active drawer belongs to a device (`device_id`), and every close/entry/archive path
      // filters by it, so an imported `is_active = true, device_id = NULL` row could never be
      // closed: `GET /shifts/current` (tenant-wide) showed it until a device opened a drawer,
      // then it and that day's entries fell out of both current and history for good. The
      // file's drawer is archived the way `openShift` archives yesterday's: auto-archived when
      // it was never closed, stamped now.
      const drawer = snapshot.sa_cash_drawer;
      const shifts: Array<{ sh: Record<string, unknown>; fromDrawer: boolean }> = [
        ...(drawer && typeof drawer === 'object' ? [{ sh: drawer, fromDrawer: true }] : []),
        ...(snapshot.sa_shift_history || []).map((sh) => ({ sh, fromDrawer: false })),
      ];
      const shiftsPerDate = new Map<string, number>();
      for (const { sh, fromDrawer } of shifts) {
        const openedAt = parseDate(sh.openedAt || sh.opened_at);
        const dateStr = String(sh.date || sh.dateStr || sh.date_str || openedAt.toISOString().slice(0, 10));
        const n = (shiftsPerDate.get(dateStr) ?? 0) + 1;
        shiftsPerDate.set(dateStr, n);
        const shiftId = String(sh.id || `sh_${dateStr}_${n}`);
        const startingCash = round2(sh.startingCash || sh.starting_cash);
        const closedAt = sh.closedAt || sh.closed_at ? parseDate(sh.closedAt || sh.closed_at) : null;
        const physicalCash = sh.physicalCash != null || sh.physical_cash != null ? round2(sh.physicalCash ?? sh.physical_cash) : null;
        const autoArchived = fromDrawer ? closedAt == null : Boolean(sh.autoArchived ?? sh.auto_archived);
        const archivedAt = sh.archivedAt || sh.archived_at ? parseDate(sh.archivedAt || sh.archived_at) : null;

        await manager.query(
          `INSERT INTO shifts (tenant_id, id, date_str, starting_cash, opened_at, closed_at, physical_cash, is_active, auto_archived, archived_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, FALSE, $8, CASE WHEN $9 THEN clock_timestamp() ELSE $10::timestamptz END)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId, shiftId, dateStr, startingCash, openedAt, closedAt, physicalCash, autoArchived, fromDrawer, archivedAt],
        );

        const entries = (sh.entries as Array<Record<string, unknown>>) || [];
        for (let j = 0; j < entries.length; j++) {
          const entry = entries[j];
          const entryId = String(entry.id || `de_${shiftId}_${j + 1}`);
          const type = String(entry.type || 'in');
          const amount = round2(entry.amount);
          // exportSnapshot() writes `note ?? ''`: an empty note stays empty, only absent is null.
          const note = entry.note != null ? String(entry.note) : null;
          const createdAt = parseDate(entry.createdAt || entry.created_at);

          await manager.query(
            `INSERT INTO drawer_entries (tenant_id, id, shift_id, type, amount, note, created_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7)
             ON CONFLICT (tenant_id, id) DO NOTHING`,
            [tenantId, entryId, shiftId, type, amount, note, createdAt],
          );
        }
      }

      // 3.13 Parked Sales (sa_parked: each element is the cart blob, carrying id + parkedAt)
      const parked = snapshot.sa_parked || [];
      for (let i = 0; i < parked.length; i++) {
        const ps = parked[i];
        const id = String(ps.id || `pk_import_${i + 1}`);
        const parkedAt = parseDate(ps.parkedAt || ps.parked_at);
        const payload = ps.payload ? (typeof ps.payload === 'string' ? JSON.parse(ps.payload) : ps.payload) : ps;

        await manager.query(
          `INSERT INTO parked_sales (tenant_id, id, parked_at, payload)
           VALUES ($1, $2, $3, $4)
           ON CONFLICT (tenant_id, id) DO NOTHING`,
          [tenantId, id, parkedAt, JSON.stringify(payload)],
        );
      }

      // 3.14 Settings
      if (snapshot.sa_settings) {
        const set = snapshot.sa_settings;
        const shopName = String(set.shopName || set.shop_name || 'ร้านอะไหล่');
        const shopNameEn = String(set.shopNameEN || set.shop_name_en || '');
        const taxRate = round2(set.taxRate ?? set.tax_rate ?? 7);
        const quoteValidDays = Math.floor(Number(set.quoteValidDays ?? set.quote_valid_days ?? 30));
        const address = set.address ? String(set.address) : null;
        const phone = set.phone ? String(set.phone) : null;
        const cashierName = set.cashierName || set.cashier_name ? String(set.cashierName || set.cashier_name) : null;
        const taxId = set.taxId || set.tax_id ? String(set.taxId || set.tax_id) : null;
        const branchNo = set.branchNo || set.branch_no ? String(set.branchNo || set.branch_no) : null;

        await manager.query(
          `INSERT INTO settings (tenant_id, shop_name, shop_name_en, tax_rate, quote_valid_days, address, phone, cashier_name, tax_id, branch_no)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
           ON CONFLICT (tenant_id) DO UPDATE SET
             shop_name = EXCLUDED.shop_name,
             shop_name_en = EXCLUDED.shop_name_en,
             tax_rate = EXCLUDED.tax_rate,
             quote_valid_days = EXCLUDED.quote_valid_days,
             address = EXCLUDED.address,
             phone = EXCLUDED.phone,
             cashier_name = EXCLUDED.cashier_name,
             tax_id = EXCLUDED.tax_id,
             branch_no = EXCLUDED.branch_no`,
          [tenantId, shopName, shopNameEn, taxRate, quoteValidDays, address, phone, cashierName, taxId, branchNo],
        );
      }

      // 3.7 Audit log inside the business transaction
      await this.auditService.log(manager, {
        tenantId,
        platformAdminId: adminId,
        action: 'platform.tenant.import',
        // #238: how many soft-deleted rows the import invented, per table.
        // #252: how many orphaned supplier rows it dropped instead.
        after: { tombstones: tombstoneCounts, droppedSuppliers },
        ip,
      });

      // Last statement before COMMIT: re-stamp every row a device pulls by `updated_at`
      // (ADR-0010 keyset cursor, 30 s rewind). A row stamped at the start of a long import —
      // `now()` defaults on customers/mechanics, or an early product's clock_timestamp() —
      // commits later than its stamp and could land behind an already-advanced cursor (#217).
      for (const table of ['products', 'customers', 'mechanics'] as const) {
        await manager.query(`UPDATE ${table} SET updated_at = clock_timestamp() WHERE tenant_id = $1`, [tenantId]);
      }

      // #239 review (issue 2): the job's own success record, atomic with everything above —
      // see this method's doc comment. `status <> 'succeeded'` is a no-op guard, not a real
      // race: nothing else can reach this row while it is `queued`/`running`
      // (`uq_import_jobs_active`), so this only ever protects against calling `writeSnapshot`
      // twice for the same job, which `processJob` already avoids by returning early.
      if (jobId) {
        await manager.query(
          `UPDATE import_jobs
              SET status = 'succeeded', result = $2::jsonb, payload = NULL, error = NULL, finished_at = clock_timestamp()
            WHERE id = $1 AND status <> 'succeeded'`,
          [jobId, JSON.stringify(result)],
        );
      }
    });

    // #32: the transaction above has committed (it is the admin data source's own, not
    // a request transaction, so `invalidateAfterCommit` would not wait for it). A
    // throw inside it rejects before reaching this line, so a failed import
    // invalidates nothing.
    for (const ns of ['products', 'categories', 'customers', 'mechanics', 'settings'] as const) {
      await this.cache.invalidate(tenantId, ns);
    }

    return result;
  }

  /**
   * Pre-flight + write, synchronously, in one call — no job. `TenantImportController` never
   * calls this (it uses `createJob`/the worker's `processJob`, #239); it exists for callers
   * that seed a tenant directly, in-process, with no HTTP round trip and no need for async
   * semantics (`test/platform.spec.ts`'s mocked-DB suite, `test/cache-invalidation.e2e-spec.ts`,
   * `test/catalogue.e2e-spec.ts`). Same return shape the endpoint always answered before #239.
   */
  async importSnapshot(
    tenantId: string,
    snapshot: SnapshotPayload,
    adminId: string,
    ip?: string,
  ): Promise<{ status: 'success'; tenantId: string } & ImportJobResult> {
    const plan = await this.preflight(tenantId, snapshot);
    const result = await this.writeSnapshot(tenantId, snapshot, adminId, ip, plan);
    return { status: 'success', tenantId, ...result };
  }

  // ── #239: the import is a background job (owner decision, 2026-09-15) ──────────────────
  // A synchronous request took ~6.4 s per 2 MiB locally, and nginx's `proxy_read_timeout 30s`
  // can cut a bigger file off mid-flight while the transaction goes on to commit — the retry
  // then reads the tenant as already imported (409) with no job id to check. `POST .../import`
  // now runs pre-flight synchronously (fast: no write, one existence SELECT) so a bad file
  // still gets an immediate 400/409, then hands the write to a worker and answers 202.

  /** `POST /platform/tenants/:id/import` — pre-flight, then enqueue. Never writes itself. */
  async createJob(tenantId: string, snapshot: SnapshotPayload, adminId: string, ip: string | undefined): Promise<{ jobId: string }> {
    await this.preflight(tenantId, snapshot);

    const jobId = newId('imp_');
    try {
      await this.adminDs.transaction(async (manager) => {
        // #239 review (issue 1): a worker that crashed or stalled leaves its row 'queued' or
        // 'running' forever — nothing else ever transitions it — and `uq_import_jobs_active`
        // then refuses every later import for this tenant. Reclaim only a row this stale
        // (`STALE_JOB_CEILING_MINUTES`'s doc comment has the worst-case-time math); a genuinely
        // in-flight job's timestamp is recent and survives this UPDATE untouched, so a real
        // concurrent attempt still hits the unique index below and gets 409, same as today.
        // `COALESCE(started_at, created_at)`: a `queued` job that a worker never even picked
        // up has no `started_at` yet.
        await manager.query(
          `UPDATE import_jobs
              SET status = 'failed', error = 'stale: worker lost', payload = NULL, finished_at = clock_timestamp()
            WHERE tenant_id = $1
              AND status IN ('queued', 'running')
              AND COALESCE(started_at, created_at) < now() - ($2 || ' minutes')::interval`,
          [tenantId, STALE_JOB_CEILING_MINUTES],
        );
        await manager.query(
          `INSERT INTO import_jobs (tenant_id, id, status, payload, requested_by, ip)
           VALUES ($1, $2, 'queued', $3::jsonb, $4, $5)`,
          [tenantId, jobId, JSON.stringify(snapshot), adminId || null, ip ?? null],
        );
      });
    } catch (err) {
      if (isUniqueViolationOn(err, 'uq_import_jobs_active')) {
        throw new ConflictException('An import is already queued or running for this tenant');
      }
      throw err;
    }

    const payload: TenantImportJobPayload = { tenantId, correlationId: newId('import_'), importJobId: jobId };
    await this.importQueue.add(JOB_TENANT_IMPORT, payload, DEFAULT_JOB_OPTIONS);
    return { jobId };
  }

  /** `GET /platform/tenants/:id/import/:jobId` — the job row is the single source of truth. */
  async getJob(tenantId: string, jobId: string): Promise<ImportJobStatus> {
    const rows = await this.adminDs.query(
      `SELECT id, status, result, error FROM import_jobs WHERE tenant_id = $1 AND id = $2`,
      [tenantId, jobId],
    );
    if (rows.length === 0) {
      throw new NotFoundException(`Import job '${jobId}' not found for this tenant`);
    }
    const row = rows[0] as { id: string; status: ImportJobState; result: ImportJobResult | null; error: string | null };
    return {
      jobId: row.id,
      status: row.status,
      ...(row.result ? { tombstones: row.result.tombstones, droppedSuppliers: row.result.droppedSuppliers } : {}),
      ...(row.error ? { error: row.error } : {}),
    };
  }

  // ── Worker side (`TenantImportProcessor`) — BullMQ concerns stay in the processor ──────

  async markRunning(jobId: string): Promise<void> {
    await this.adminDs.query(`UPDATE import_jobs SET status = 'running', started_at = clock_timestamp() WHERE id = $1`, [jobId]);
  }

  /** On the LAST attempt only, per BullMQ convention (`TenantJobRunner.routeToDlq`'s rule). */
  async markFailed(jobId: string, error: string, final: boolean): Promise<void> {
    if (final) {
      await this.adminDs.query(
        `UPDATE import_jobs SET status = 'failed', error = $2, payload = NULL, finished_at = clock_timestamp() WHERE id = $1`,
        [jobId, error],
      );
    } else {
      // A retry still has to read `payload` back, so it is kept — only the last attempt's
      // message is recorded, in case every attempt fails and the row is inspected later.
      await this.adminDs.query(`UPDATE import_jobs SET error = $2 WHERE id = $1`, [jobId, error]);
    }
  }

  /**
   * The worker's entry point: load, validate again (defence in depth), write, report.
   * `writeSnapshot` (given `jobId`) writes `status = 'succeeded'` itself, atomically with the
   * business data (#239 review, issue 2) — there is no separate `markSucceeded` step, and so
   * no gap between "the import committed" and "the row says so" for a crash to land in.
   */
  async processJob(jobId: string): Promise<ImportJobResult> {
    const rows = await this.adminDs.query(
      `SELECT tenant_id, payload, requested_by, ip, status, result FROM import_jobs WHERE id = $1`,
      [jobId],
    );
    if (rows.length === 0) {
      throw new Error(`import job '${jobId}' not found`);
    }
    const row = rows[0] as {
      tenant_id: string;
      payload: SnapshotPayload | null;
      requested_by: string | null;
      ip: string | null;
      status: ImportJobState;
      result: ImportJobResult | null;
    };
    if (row.status === 'succeeded') {
      // A retry landing here means the import itself already committed (§ above) and only
      // the *acknowledgement* — this call returning, the BullMQ job completing — was lost, so
      // re-running would import everything a second time against data that is already there.
      // The transaction that wrote the data already recorded success in the same commit; this
      // is that recorded result, not a re-derivation.
      return row.result as ImportJobResult;
    }
    if (!row.payload) {
      // Not succeeded, and no payload left: a prior attempt's *final* failure already ran
      // (`markFailed` clears payload only when `final`), so retrying would preflight/write
      // against nothing.
      throw new Error(`import job '${jobId}' has no payload left to process (already finished)`);
    }
    const plan = await this.preflight(row.tenant_id, row.payload);
    return this.writeSnapshot(row.tenant_id, row.payload, row.requested_by ?? '', row.ip ?? undefined, plan, jobId);
  }
}
