import { BadRequestException, Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { newUuid } from '../common/ids.js';
import { fromSatang, satangOf } from '../common/money.js';
import { currentRequestContext } from '../common/request-context.js';
import { TenantService } from '../common/database/tenant.service.js';
import { returning } from '../common/sql.js';
import { DocNumberService } from '../documents/doc-number.service.js';
import { QuoteSaleService } from '../sales/quote-sale.service.js';
import type { CreateSale, SaleParty } from '../sales/sales.dto.js';
import {
  SalesService,
  assertSaleTotals,
  insufficientStock,
  type CreateSaleResult,
  type SaleActor,
} from '../sales/sales.service.js';
import {
  quoteAlreadyConverted,
  quoteConvertedNotDeletable,
  quoteNotFound,
} from './quote-errors.js';
import type { QuoteCreate, QuoteFilter, QuotePatch } from './quotes.dto.js';

/** A quote on the wire. Money is a string (02_API_SCREENS.md §1.1). */
export interface Quote {
  id: string;
  quoteNo: string;
  status: string;
  date: string;
  validUntil: string;
  convertedAt: string | null;
  convertedSaleId: string | null;
  subtotal: string | null;
  discount: string | null;
  total: string | null;
  customerName: string | null;
  customerPhone: string | null;
  notes: string | null;
  validDays: number | null;
  /**
   * `QuoteRowStatus.isExpired` — `validUntil.isBefore(DateTime.now())` — evaluated
   * against the database clock at read time, on every quote whatever its status, as
   * the Dart extension does. Stored `status` is never rewritten to `'expired'`.
   */
  isExpired: boolean;
  /** `QuoteRowStatus.isConverted` — `status == 'converted'`. */
  isConverted: boolean;
  items: QuoteItem[];
}

export interface QuoteItem {
  lineNo: number;
  productId: string | null;
  name: string;
  qty: number;
  price: string;
}

/** What `POST /quotes/:id/convert` answers: the bill exactly as `POST /sales` would, and the marked quote. */
export interface ConvertQuoteResult {
  sale: CreateSaleResult;
  quote: Quote;
}

interface QuoteRow {
  id: string;
  quote_no: string;
  status: string;
  date: Date;
  valid_until: Date;
  converted_at: Date | null;
  converted_sale_id: string | null;
  subtotal: string | null;
  discount: string | null;
  total: string | null;
  customer_name: string | null;
  customer_phone: string | null;
  notes: string | null;
  valid_days: number | null;
  expired: boolean;
}

interface QuoteItemRow {
  quote_id: string;
  line_no: number;
  product_id: string | null;
  name: string;
  qty: number;
  price: string;
}

const COLUMNS = `id, quote_no, status, date, valid_until, converted_at, converted_sale_id,
                 subtotal, discount, total, customer_name, customer_phone, notes, valid_days,
                 (valid_until < now()) AS expired`;

/** `saveQuote`: `(validDays ?? 30)` days — the data layer's own literal, never `settings`. */
const DEFAULT_VALID_DAYS = 30;

/**
 * Quotes (#27). **No method here touches `products`** except `convert`, and that one
 * only through `SalesService.create` — the sale transaction owns every stock write.
 *
 * Lock order on convert — and on `POST /sales` with a `quoteId` (owner, 2026-10-03,
 * `QuoteSaleService`): the quote row `FOR UPDATE` is taken first, then the sale
 * path's own order (sale → shift `FOR SHARE` → mechanic → products → `doc_counters`
 * → customer). Nothing else locks a quote after any of those, so the prefix cannot
 * form a cycle: create/duplicate take only `doc_counters`, patch/delete only the
 * quote row, and the void and return paths never read `quotes` at all.
 */
@Injectable()
export class QuotesService {
  constructor(
    private readonly docNumbers: DocNumberService,
    private readonly sales: SalesService,
    private readonly quoteSales: QuoteSaleService,
    private readonly tenants: TenantService,
  ) {}

  /**
   * Newest first (`getQuotes` orders by `date DESC`). `status` is the Quotes
   * screen's filter, computed exactly as `_applyFilter` does from `isConverted` and
   * `isExpired` — not from the stored status column.
   */
  list(query: {
    status?: QuoteFilter;
    from?: string;
    to?: string;
    page: number;
    limit: number;
  }): Promise<{ items: Quote[]; total: number }> {
    return this.tenants.runTx(() => this.listIn(query));
  }

  private async listIn(query: {
    status?: QuoteFilter;
    from?: string;
    to?: string;
    page: number;
    limit: number;
  }): Promise<{ items: Quote[]; total: number }> {
    const { tenantId, manager } = currentRequestContext();
    const params: unknown[] = [tenantId];
    const where = ['tenant_id = $1::uuid'];
    if (query.status === 'open') {
      where.push(`status <> 'converted'`, `NOT (valid_until < now())`);
    } else if (query.status === 'expired') {
      where.push(`status <> 'converted'`, `valid_until < now()`);
    } else if (query.status === 'converted') {
      where.push(`status = 'converted'`);
    }
    if (query.from) {
      params.push(query.from);
      where.push(`date >= $${params.length}::timestamptz`);
    }
    if (query.to) {
      params.push(query.to);
      where.push(`date <= $${params.length}::timestamptz`);
    }
    const clause = where.join(' AND ');
    const totals = (await manager.query(
      `SELECT count(*)::int AS n FROM quotes WHERE ${clause}`,
      params,
    )) as { n: number }[];
    params.push(query.limit, (query.page - 1) * query.limit);
    const rows = (await manager.query(
      `SELECT ${COLUMNS} FROM quotes WHERE ${clause}
        ORDER BY date DESC, id DESC
        LIMIT $${params.length - 1} OFFSET $${params.length}`,
      params,
    )) as QuoteRow[];
    return {
      items: await this.withItems(manager, tenantId, rows),
      total: totals[0]?.n ?? 0,
    };
  }

  byId(id: string): Promise<Quote> {
    return this.tenants.runTx(() => this.byIdIn(id));
  }

  private async byIdIn(id: string): Promise<Quote> {
    const { tenantId, manager } = currentRequestContext();
    return this.read(manager, tenantId, id);
  }

  /** `saveQuote`: a fresh `q` id, a QT number, `date = now`, status `'open'`. */
  create(input: QuoteCreate, deviceId: string): Promise<Quote> {
    return this.tenants.runTx(() => this.createIn(input, deviceId));
  }

  private async createIn(input: QuoteCreate, deviceId: string): Promise<Quote> {
    // The same arithmetic a bill is held to, so a quote that saves is a quote that
    // converts — `SalesService.create` would refuse it with the same 409 later.
    assertSaleTotals(input);
    const { tenantId, manager } = currentRequestContext();
    const id = newUuid();
    const quoteNo = await this.docNumbers.issue(manager, {
      tenantId,
      deviceId,
      docType: 'quote',
    });
    await manager.query(
      `INSERT INTO quotes (tenant_id, id, quote_no, status, date, valid_until,
                           subtotal, discount, total, customer_name, customer_phone, notes, valid_days)
       VALUES ($1::uuid, $2, $3, 'open', now(), now() + ($4::int * interval '24 hours'),
               $5, $6, $7, $8, $9, $10, $11)`,
      [
        tenantId,
        id,
        quoteNo,
        input.validDays ?? DEFAULT_VALID_DAYS,
        fromSatang(input.subtotalSatang),
        fromSatang(input.discountSatang),
        fromSatang(input.totalSatang),
        input.customerName,
        input.customerPhone,
        input.notes,
        input.validDays,
      ],
    );
    await this.insertItems(
      manager,
      tenantId,
      id,
      input.items.map((l) => ({
        lineNo: l.lineNo,
        productId: l.productId,
        name: l.name,
        qty: l.qty,
        price: fromSatang(l.priceSatang),
      })),
    );
    return this.read(manager, tenantId, id);
  }

  /**
   * Header text on a quote that has not been converted. A converted quote is the
   * record of what a bill was sold from; the screen already refuses to edit one
   * (`'ใบนี้แปลงเป็นการขายแล้ว แก้ไขไม่ได้'`).
   */
  update(id: string, patch: QuotePatch): Promise<Quote> {
    return this.tenants.runTx(() => this.updateIn(id, patch));
  }

  private async updateIn(id: string, patch: QuotePatch): Promise<Quote> {
    const { tenantId, manager } = currentRequestContext();
    const columns: Record<keyof QuotePatch, string> = {
      customerName: 'customer_name',
      customerPhone: 'customer_phone',
      notes: 'notes',
    };
    const values: unknown[] = [tenantId, id];
    const sets: string[] = [];
    for (const [field, value] of Object.entries(patch)) {
      values.push(value);
      sets.push(`${columns[field as keyof QuotePatch]} = $${values.length}`);
    }
    // An empty patch still has to prove the quote exists and is editable.
    const rows = returning<{ id: string }>(
      await manager.query(
        `UPDATE quotes SET ${sets.length > 0 ? sets.join(', ') : 'id = id'}
          WHERE tenant_id = $1::uuid AND id = $2 AND status <> 'converted'
      RETURNING id`,
        values,
      ),
    );
    if (rows.length === 0) {
      const existing = await this.read(manager, tenantId, id); // 404 if absent
      throw quoteAlreadyConverted(existing.convertedSaleId);
    }
    return this.read(manager, tenantId, id);
  }

  /**
   * `deleteQuote`: an unconverted quote only. A converted quote is the record a bill
   * was sold from, so deleting it is `409 QUOTE_CONVERTED_NOT_DELETABLE` (owner,
   * 2026-10-03, #27 Q2) — which also keeps a lost-key retry of that bill from meeting
   * a 404. `POST /quotes/purge` still removes old converted quotes.
   */
  delete(id: string): Promise<{ id: string; deleted: true }> {
    return this.tenants.runTx(() => this.deleteIn(id));
  }

  private async deleteIn(id: string): Promise<{ id: string; deleted: true }> {
    const { tenantId, manager } = currentRequestContext();
    // A sale converting this quote holds its row `FOR UPDATE`; this DELETE waits for
    // it and re-checks the predicate against the committed row, so it cannot remove
    // a quote that was converted while it waited.
    const rows = returning<{ id: string }>(
      await manager.query(
        `DELETE FROM quotes WHERE tenant_id = $1::uuid AND id = $2 AND status <> 'converted'
      RETURNING id`,
        [tenantId, id],
      ),
    );
    if (rows.length === 0) {
      const existing = await this.read(manager, tenantId, id); // 404 if absent
      throw quoteConvertedNotDeletable(existing.convertedSaleId);
    }
    return { id, deleted: true };
  }

  /**
   * `duplicateQuote`: header and lines copied, a fresh id, QT number, `date` and
   * `validUntil` (`validDays ?? 30` from now), status `'open'`, conversion stripped.
   * A converted or expired quote may be duplicated — that is the screen's
   * "ทำซ้ำ (ต่ออายุใหม่)".
   */
  duplicate(id: string, deviceId: string): Promise<Quote> {
    return this.tenants.runTx(() => this.duplicateIn(id, deviceId));
  }

  private async duplicateIn(id: string, deviceId: string): Promise<Quote> {
    const { tenantId, manager } = currentRequestContext();
    const src = await this.read(manager, tenantId, id);
    const newQuoteId = newUuid();
    const quoteNo = await this.docNumbers.issue(manager, {
      tenantId,
      deviceId,
      docType: 'quote',
    });
    await manager.query(
      `INSERT INTO quotes (tenant_id, id, quote_no, status, date, valid_until,
                           subtotal, discount, total, customer_name, customer_phone, notes, valid_days)
       VALUES ($1::uuid, $2, $3, 'open', now(), now() + ($4::int * interval '24 hours'),
               $5, $6, $7, $8, $9, $10, $11)`,
      [
        tenantId,
        newQuoteId,
        quoteNo,
        src.validDays ?? DEFAULT_VALID_DAYS,
        src.subtotal,
        src.discount,
        src.total,
        src.customerName,
        src.customerPhone,
        src.notes,
        src.validDays,
      ],
    );
    await this.insertItems(manager, tenantId, newQuoteId, src.items);
    return this.read(manager, tenantId, newQuoteId);
  }

  /**
   * Sells the quote through `SalesService.create` and marks it converted in the same
   * transaction — the one place a quote moves stock, and it does not move it itself.
   * The lines and money are the saved quote's.
   *
   * Kept for API compatibility; since the owner's #27 decision (2026-10-03) the
   * client sells a quote's cart through `POST /sales` with a `quoteId` instead, so a
   * cart edited at Checkout still converts its quote. Both share `QuoteSaleService`'s
   * lock and eligibility rules.
   */
  convert(
    id: string,
    party: SaleParty,
    actor: SaleActor,
  ): Promise<ConvertQuoteResult> {
    return this.tenants.runTx(() => this.convertIn(id, party, actor));
  }

  private async convertIn(
    id: string,
    party: SaleParty,
    actor: SaleActor,
  ): Promise<ConvertQuoteResult> {
    const { tenantId, manager } = currentRequestContext();
    const state = await this.quoteSales.lockForSale(manager, tenantId, id, party.id);
    if (state === 'missing') throw quoteNotFound();
    const q = (
      (await manager.query(
        `SELECT ${COLUMNS} FROM quotes WHERE tenant_id = $1::uuid AND id = $2`,
        [tenantId, id],
      )) as QuoteRow[]
    )[0];

    const sale = await this.sales.create(
      await this.saleFrom(manager, tenantId, q, party),
      actor,
    );
    if (state === 'fresh') {
      await this.quoteSales.markConverted(manager, tenantId, id, sale.id);
    }
    return { sale, quote: await this.read(manager, tenantId, id) };
  }

  /**
   * The bill a quote sells as: its lines at the quoted prices and its money, plus the
   * party from the body. A line with no product is refused here with the sale path's
   * own `สต็อกไม่พอ … ไม่พบในสต็อก` (as Checkout's `_maybeConsumePendingQuote` ends up
   * doing), on a first convert and a replay alike. A row imported with no money derives
   * it from its lines.
   */
  private async saleFrom(
    manager: EntityManager,
    tenantId: string,
    q: QuoteRow,
    party: SaleParty,
  ): Promise<CreateSale> {
    const lines = (await manager.query(
      `SELECT quote_id, line_no, product_id, name, qty, price FROM quote_items
        WHERE tenant_id = $1::uuid AND quote_id = $2 ORDER BY line_no`,
      [tenantId, q.id],
    )) as QuoteItemRow[];
    if (lines.length === 0) {
      throw new BadRequestException('Quote has no lines to sell.');
    }
    // A free-text line names no catalogue product, so it cannot be sold: refused here
    // with the sale path's own "ไม่พบในสต็อก" (#616) — never handed on as a product id.
    const loose = lines.filter((l) => l.product_id === null);
    if (loose.length > 0) {
      throw insufficientStock(
        loose.map((l) => `${l.name}: ไม่พบในสต็อก`),
        loose.map((l) => ({ productId: null, stock: null, requested: l.qty })),
      );
    }
    const items = lines.map((l) => ({
      lineNo: l.line_no,
      productId: l.product_id!,
      partNo: null,
      name: l.name,
      nameTH: null,
      qty: l.qty,
      priceSatang: satangOf(l.price),
    }));
    const computed = items.reduce((sum, l) => sum + l.qty * l.priceSatang, 0);
    const subtotalSatang =
      q.subtotal === null ? computed : satangOf(q.subtotal);
    const discountSatang = q.discount === null ? 0 : satangOf(q.discount);
    const totalSatang =
      q.total === null ? subtotalSatang - discountSatang : satangOf(q.total);
    return { ...party, subtotalSatang, discountSatang, totalSatang, items };
  }

  private async read(
    manager: EntityManager,
    tenantId: string,
    id: string,
  ): Promise<Quote> {
    const rows = (await manager.query(
      `SELECT ${COLUMNS} FROM quotes WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, id],
    )) as QuoteRow[];
    if (rows.length === 0) throw quoteNotFound();
    return (await this.withItems(manager, tenantId, rows))[0];
  }

  private async withItems(
    manager: EntityManager,
    tenantId: string,
    rows: QuoteRow[],
  ): Promise<Quote[]> {
    if (rows.length === 0) return [];
    const items = (await manager.query(
      `SELECT quote_id, line_no, product_id, name, qty, price FROM quote_items
        WHERE tenant_id = $1::uuid AND quote_id = ANY($2::uuid[])
        ORDER BY quote_id, line_no`,
      [tenantId, rows.map((r) => r.id)],
    )) as QuoteItemRow[];
    const byQuote = new Map<string, QuoteItem[]>();
    for (const it of items) {
      const list = byQuote.get(it.quote_id) ?? [];
      list.push({
        lineNo: it.line_no,
        productId: it.product_id,
        name: it.name,
        qty: it.qty,
        price: money(it.price),
      });
      byQuote.set(it.quote_id, list);
    }
    return rows.map((r) => toQuote(r, byQuote.get(r.id) ?? []));
  }

  private async insertItems(
    manager: EntityManager,
    tenantId: string,
    quoteId: string,
    items: QuoteItem[],
  ): Promise<void> {
    for (const it of items) {
      await manager.query(
        `INSERT INTO quote_items (tenant_id, quote_id, line_no, product_id, name, qty, price)
         VALUES ($1::uuid, $2, $3, $4, $5, $6, $7)`,
        [tenantId, quoteId, it.lineNo, it.productId, it.name, it.qty, it.price],
      );
    }
  }
}

function toQuote(r: QuoteRow, items: QuoteItem[]): Quote {
  return {
    id: r.id,
    quoteNo: r.quote_no,
    status: r.status,
    date: r.date.toISOString(),
    validUntil: r.valid_until.toISOString(),
    convertedAt: r.converted_at ? r.converted_at.toISOString() : null,
    convertedSaleId: r.converted_sale_id,
    subtotal: r.subtotal === null ? null : money(r.subtotal),
    discount: r.discount === null ? null : money(r.discount),
    total: r.total === null ? null : money(r.total),
    customerName: r.customer_name,
    customerPhone: r.customer_phone,
    notes: r.notes,
    validDays: r.valid_days,
    isExpired: r.expired,
    isConverted: r.status === 'converted',
    items,
  };
}

function money(numeric: string): string {
  return fromSatang(satangOf(numeric));
}
