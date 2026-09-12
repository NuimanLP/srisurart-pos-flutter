import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { newId } from '../common/ids.js';
import { fromSatang, satangOf } from '../common/money.js';
import { currentRequestContext } from '../common/request-context.js';
import { returning } from '../common/sql.js';
import { DocNumberService } from '../documents/doc-number.service.js';
import { ShiftsService } from '../shifts/shifts.service.js';
import { saleNotFound } from '../sales/sale-reads.service.js';
import {
  MOVEMENT_COLUMNS,
  mechanicAfter as toMechanicAfter,
  movementOut,
  type CustomerAfter,
  type MechanicAfter,
  type MechanicRow,
  type MovementOut,
  type MovementRow,
} from '../sales/sales.service.js';
import type { CreateReturn, ReturnLine } from './returns.dto.js';

/** Who is taking the goods back — read from the token, never from the body. */
export interface ReturnActor {
  userId: string;
  deviceId: string;
}

/** One credit-note line as the API hands it back. */
export interface ReturnLineOut {
  lineNo: number;
  productId: string;
  name: string;
  qty: number;
  price: string;
  originalQty: number | null;
  costAtSale: string | null;
}

/** A credit note with its lines — what both `POST` and `GET /returns` answer with. */
export interface ReturnWithItems {
  id: string;
  cnNo: string;
  saleId: string;
  receiptNo: string;
  refundSubtotal: string;
  refundDiscount: string;
  refundTotal: string;
  refundMethod: string;
  reason: string;
  customerId: string | null;
  mechanicId: string | null;
  mechanicName: string | null;
  date: string;
  shiftId: string | null;
  items: ReturnLineOut[];
}

/** `POST /returns` — the credit note plus the effects the client's cache must patch. */
export interface CreateReturnResult extends ReturnWithItems {
  /** True when this return took the last unit off the bill and voided it. */
  saleVoided: boolean;
  /** Every product this credit note put back, with its new stock. */
  products: { id: string; stock: number }[];
  /**
   * The ledger rows this credit note wrote, `type: 'return'` (#82) — so the stock log
   * on the client is not blind to refunds. A **void** writes `'void'` against the
   * same goods and is a different row; the two must never be collapsed.
   */
  movements: MovementOut[];
  customerAfter: CustomerAfter | null;
  /**
   * The mechanic's balance after the reversal; null when the bill named none. Kept
   * alongside `mechanicAfter` — it is what every existing reader looks at.
   */
  mechanicCreditBalanceAfter: string | null;
  /** All four running totals `reverseMechanic` moved; null when the bill names none. */
  mechanicAfter: MechanicAfter | null;
}

/** The parent bill, locked, with everything the reversal needs off it. */
interface LockedSale {
  subtotal: string;
  discount: string;
  total: string;
  points_granted: number;
  customer_id: string | null;
  mechanic_id: string | null;
  mechanic_name: string | null;
  mechanic_delta: string | null;
  payment_method: string;
  receipt_no: string;
  voided: boolean;
}

/** What one product-and-price on the parent bill sold as — never from the catalogue. */
interface SoldLine {
  qty: number;
  costAtSale: string | null;
}

/**
 * The parent bill's lines, indexed the ways the guards need them.
 *
 * 🔴 One bill may legitimately carry the same product on two lines at two different
 * prices, so "the price this product sold at on this bill" is a **set**, not a value.
 * Every guard below therefore works per product-and-price, with `qtyByProduct` kept
 * only as the backstop described in `assertRefundable`.
 */
interface Sold {
  /** Total quantity per product, across every price it went out at. */
  qtyByProduct: Map<string, number>;
  /** Quantity and cost per product-and-price, keyed by `priceKey`. */
  byPrice: Map<string, SoldLine>;
  /** The prices one product sold at, for the refusal a mispriced line earns. */
  pricesByProduct: Map<string, number[]>;
}

/** How much of each product has already come back, by product and by price. */
interface Refunded {
  byProduct: Map<string, number>;
  byPrice: Map<string, number>;
}

/**
 * A product and the price it sold at, in satang — the unit both guards work in.
 * The separator is `\u0000` because a product id is client text: any printable one
 * could be part of an id, and two different products would share a bucket.
 */
function priceKey(productId: string, priceSatang: number): string {
  return `${productId}\u0000${priceSatang}`;
}

/** How much of one product this credit note takes back, and what to call it. */
interface Demand {
  productId: string;
  qty: number;
  priceSatang: number;
  originalQty: number | null;
  /** The name the client used, for the Thai error and for `return_items.name`. */
  requestedName: string;
  firstLineIndex: number;
}

/** The one refund method that comes off the mechanic's tab instead of out of the drawer. */
const DEDUCT_FROM_CREDIT = 'หักจากเครดิต';

/**
 * The credit-note transaction — a faithful port of `returns_repository.dart`, which
 * is itself the port of `db.js` `createReturn`.
 *
 * Everything runs inside the request's transaction, in this order, and the order is
 * the design:
 *
 *   1. the idempotency claim (the interceptor, before this method is called)
 *   2. `SELECT … FROM sales … FOR UPDATE` — 404 / `SALE_VOIDED` come off this row
 *   3. the over-refund guard, from the locked bill and every prior credit note
 *   4. the money, in integer satang
 *   5. lock the mechanic's row, if the bill named one
 *   6. `SELECT … FROM products … ORDER BY id FOR UPDATE`
 *   7. issue the CN number
 *   8. insert the header and the lines, `cost_at_sale` copied from the parent line
 *   9. put the stock back and write the `movements` rows
 *  10. reverse the customer's points and spend, and the mechanic's tab, in proportion
 *  11. auto-void the parent bill once every unit on it has come back
 *
 * 🔴 **The `FOR UPDATE` on the sale in step 2 is what makes the guard in step 3 mean
 * anything.** Without it two concurrent partial returns of the same bill both read the
 * same "already refunded" total, both pass, and the shop refunds more than it sold.
 * The Dart reference is single-process and structurally cannot expose that race.
 *
 * 🔴 **Lock order: sale → mechanic → products → `doc_counters`.** `POST /sales` locks
 * the mechanic before the products (README, *Lock order*) so a cash bill and a credit
 * bill for the same mechanic cannot deadlock over a shared part; a return that took
 * the products first would deadlock against any such bill.
 */
@Injectable()
export class ReturnsService {
  constructor(
    private readonly docNumbers: DocNumberService,
    private readonly shifts: ShiftsService,
  ) {}

  async create(
    dto: CreateReturn,
    actor: ReturnActor,
  ): Promise<CreateReturnResult> {
    const { tenantId, manager } = currentRequestContext();

    const sale = await this.lockSale(manager, tenantId, dto.saleId);
    // The DTO whitelists the three refund methods but cannot see the bill, and only a
    // bill naming a mechanic has a tab to deduct from — the Returns screen offers the
    // option on no other (`returns_screen.dart:904`). Without this check the credit
    // note records a deduction that deducted from nothing, and the closing report does
    // not count it as cash either, so the money is simply lost.
    if (dto.refundMethod === DEDUCT_FROM_CREDIT && sale.mechanic_id === null) {
      throw new HttpException(
        {
          code: 'REFUND_METHOD_NOT_ALLOWED',
          message: `Refund method '${DEDUCT_FROM_CREDIT}' needs a bill with a mechanic.`,
        },
        HttpStatus.CONFLICT,
      );
    }
    const sold = await this.soldLines(manager, tenantId, dto.saleId);
    const refunded = await this.refundedSoFar(manager, tenantId, dto.saleId);

    const demands = aggregate(dto.items);
    this.assertRefundable(demands, sold, refunded);

    const money = refundAmounts(demands, sale);

    // Mechanic before products, always — see the class comment.
    const mechanic = await this.lockMechanic(manager, tenantId, sale.mechanic_id);
    const locked = await this.lockProducts(manager, tenantId, demands);

    const cnNo = await this.docNumbers.issue(manager, {
      tenantId,
      deviceId: actor.deviceId,
      docType: 'cn',
    });
    const returnId = newId('r');
    // Stamped from the device's own open drawer, never from the body (#28): the
    // closing report is computed by `shift_id`, and null when the drawer was never
    // opened — the old app lets staff take goods back without one.
    const shiftId = await this.shifts.currentShiftIdFor(
      manager,
      tenantId,
      actor.deviceId,
    );

    const date = await this.insertReturn(
      manager,
      tenantId,
      returnId,
      cnNo,
      dto,
      sale,
      money,
      shiftId,
    );
    const items = await this.insertLines(
      manager,
      tenantId,
      returnId,
      demands,
      sold,
    );

    const { stockAfter, movements } = await this.restoreStock(
      manager,
      tenantId,
      returnId,
      demands,
      locked,
    );

    const customerAfter = await this.reverseCustomer(
      manager,
      tenantId,
      sale,
      money,
    );
    const mechanicAfter = await this.reverseMechanic(
      manager,
      tenantId,
      sale,
      mechanic,
      dto.refundMethod,
      money,
    );
    const mechanicCreditBalanceAfter = mechanicAfter?.creditBalance ?? null;

    const saleVoided = await this.autoVoid(manager, tenantId, dto.saleId, sold);

    return {
      id: returnId,
      cnNo,
      saleId: dto.saleId,
      receiptNo: sale.receipt_no,
      refundSubtotal: fromSatang(money.refundSubtotalSatang),
      refundDiscount: fromSatang(money.refundDiscountSatang),
      refundTotal: fromSatang(money.refundTotalSatang),
      refundMethod: dto.refundMethod,
      reason: dto.reason,
      customerId: sale.customer_id,
      mechanicId: sale.mechanic_id,
      mechanicName: sale.mechanic_name,
      date,
      shiftId,
      items,
      saleVoided,
      products: [...stockAfter].map(([id, stock]) => ({ id, stock })),
      movements,
      customerAfter,
      mechanicCreditBalanceAfter,
      mechanicAfter,
    };
  }

  /**
   * A page of credit notes, newest first, optionally for one bill or one date range.
   *
   * `from`/`to` are the documented filters (`02_API_SCREENS.md §3.7`, the refund
   * history) and behave exactly as `GET /sales` does; `saleId` is the extra one
   * `POST /returns` needs to show a bill's own notes.
   */
  async list(query: {
    saleId?: string;
    from?: string;
    to?: string;
    page: number;
    limit: number;
  }): Promise<{ items: ReturnWithItems[]; total: number }> {
    const { tenantId, manager } = currentRequestContext();
    const params: unknown[] = [tenantId];
    let clause = 'tenant_id = $1::uuid';
    if (query.saleId) {
      params.push(query.saleId);
      clause += ` AND sale_id = $${params.length}`;
    }
    if (query.from) {
      params.push(query.from);
      clause += ` AND date >= $${params.length}::timestamptz`;
    }
    if (query.to) {
      params.push(query.to);
      clause += ` AND date <= $${params.length}::timestamptz`;
    }

    const totals = (await manager.query(
      `SELECT count(*)::int AS n FROM returns WHERE ${clause}`,
      params,
    )) as { n: number }[];

    params.push(query.limit, (query.page - 1) * query.limit);
    const rows = (await manager.query(
      `SELECT ${RETURN_COLUMNS} FROM returns
        WHERE ${clause}
        ORDER BY date DESC, id DESC
        LIMIT $${params.length - 1} OFFSET $${params.length}`,
      params,
    )) as ReturnRow[];
    if (rows.length === 0) return { items: [], total: totals[0].n };

    const items = (await manager.query(
      `SELECT return_id, line_no, product_id, name, qty, price, original_qty, cost_at_sale
         FROM return_items
        WHERE tenant_id = $1::uuid AND return_id = ANY($2::text[])
        ORDER BY return_id, line_no`,
      [tenantId, rows.map((r) => r.id)],
    )) as ({ return_id: string } & Record<string, unknown>)[];

    const byReturn = new Map<string, ReturnLineOut[]>();
    for (const item of items) {
      const list = byReturn.get(item.return_id) ?? [];
      list.push({
        lineNo: item.line_no as number,
        productId: item.product_id as string,
        name: item.name as string,
        qty: item.qty as number,
        price: item.price as string,
        originalQty: (item.original_qty as number) ?? null,
        costAtSale: (item.cost_at_sale as string) ?? null,
      });
      byReturn.set(item.return_id, list);
    }

    return {
      items: rows.map((row) => toReturn(row, byReturn.get(row.id) ?? [])),
      total: totals[0].n,
    };
  }

  /**
   * Locks the parent bill for the rest of the transaction.
   *
   * 🔴 This is the serialisation point of the whole endpoint. Two clerks crediting
   * back the same bill at the same moment would otherwise both read the same
   * already-refunded totals in `assertRefundable`, both find room, and jointly refund
   * more than the bill ever sold — every later statement here is per-row and cannot
   * notice.
   */
  private async lockSale(
    manager: EntityManager,
    tenantId: string,
    saleId: string,
  ): Promise<LockedSale> {
    const rows = (await manager.query(
      `SELECT subtotal, discount, total, points_granted, customer_id, mechanic_id,
              mechanic_name, mechanic_delta, payment_method, receipt_no, voided
         FROM sales
        WHERE tenant_id = $1::uuid AND id = $2
          FOR UPDATE`,
      [tenantId, saleId],
    )) as LockedSale[];
    if (rows.length === 0) throw saleNotFound();
    if (rows[0].voided) {
      throw new HttpException(
        { code: 'SALE_VOIDED', message: 'Bill already voided' },
        HttpStatus.CONFLICT,
      );
    }
    return rows[0];
  }

  /**
   * What the bill sold, per product **and per price**, with the cost each line left
   * the shop at.
   *
   * 🔴 `price` is read here because the **server** decides what a refund is worth. The
   * body may name a product and a quantity; the amount comes off this row. Without it
   * a `pos` token could credit 999,999 baht against a bill that sold the part for 85,
   * and the `GREATEST(0, …)` clamps downstream would absorb the damage in silence —
   * zeroing a mechanic's tab and raising nothing. The Dart reference has the same hole
   * because there the client *is* the authority; here Postgres is.
   *
   * `cost_at_sale` is the first line of each group. `POST /sales` stamps it from one
   * locked read of `products.cost`, so every line of a product on one bill carries the
   * same cost and the choice cannot matter.
   */
  private async soldLines(
    manager: EntityManager,
    tenantId: string,
    saleId: string,
  ): Promise<Sold> {
    const rows = (await manager.query(
      `SELECT product_id, price, sum(qty)::int AS qty,
              (array_agg(cost_at_sale ORDER BY line_no))[1] AS cost_at_sale
         FROM sale_items
        WHERE tenant_id = $1::uuid AND sale_id = $2
        GROUP BY product_id, price
        ORDER BY product_id, price`,
      [tenantId, saleId],
    )) as {
      product_id: string;
      price: string;
      qty: number;
      cost_at_sale: string | null;
    }[];

    const sold: Sold = {
      qtyByProduct: new Map(),
      byPrice: new Map(),
      pricesByProduct: new Map(),
    };
    for (const r of rows) {
      const priceSatang = satangOf(r.price);
      sold.qtyByProduct.set(
        r.product_id,
        (sold.qtyByProduct.get(r.product_id) ?? 0) + r.qty,
      );
      sold.byPrice.set(priceKey(r.product_id, priceSatang), {
        qty: r.qty,
        costAtSale: r.cost_at_sale,
      });
      sold.pricesByProduct.set(r.product_id, [
        ...(sold.pricesByProduct.get(r.product_id) ?? []),
        priceSatang,
      ]);
    }
    return sold;
  }

  /**
   * How much every prior credit note against this bill took back — by product, and by
   * product-and-price, because that is the unit `assertRefundable` bounds.
   */
  private async refundedSoFar(
    manager: EntityManager,
    tenantId: string,
    saleId: string,
  ): Promise<Refunded> {
    const rows = (await manager.query(
      `SELECT ri.product_id, ri.price, sum(ri.qty)::int AS qty
         FROM return_items ri
         JOIN returns r ON r.tenant_id = ri.tenant_id AND r.id = ri.return_id
        WHERE ri.tenant_id = $1::uuid AND r.sale_id = $2
        GROUP BY ri.product_id, ri.price`,
      [tenantId, saleId],
    )) as { product_id: string; price: string; qty: number }[];

    const refunded: Refunded = { byProduct: new Map(), byPrice: new Map() };
    for (const r of rows) {
      refunded.byProduct.set(
        r.product_id,
        (refunded.byProduct.get(r.product_id) ?? 0) + r.qty,
      );
      const key = priceKey(r.product_id, satangOf(r.price));
      refunded.byPrice.set(key, (refunded.byPrice.get(key) ?? 0) + r.qty);
    }
    return refunded;
  }

  /**
   * The over-refund guard, built whole and thrown once — like `assertStock` on the
   * sale side, so staff see every bad line at once instead of discovering them one
   * resubmission at a time. Both strings are verbatim from `returns_repository.dart`.
   *
   * Ahead of it, `409 RETURN_PRICE_MISMATCH` for a line priced at anything this bill
   * did not charge — refused rather than silently corrected, because a body that
   * disagrees with the bill about the price disagrees about which line it means.
   *
   * Nothing has been written when either fires: the only statements above them are
   * reads and the lock on the parent bill.
   */
  private assertRefundable(
    demands: Demand[],
    sold: Sold,
    refunded: Refunded,
  ): void {
    // Price before quantity: a line priced at something this bill never charged is
    // not a quantity problem, and the Thai sentence below would misdescribe it.
    const mispriced = demands.filter(
      (d) =>
        sold.qtyByProduct.has(d.productId) &&
        !sold.byPrice.has(priceKey(d.productId, d.priceSatang)),
    );
    if (mispriced.length > 0) {
      throw new HttpException(
        {
          code: 'RETURN_PRICE_MISMATCH',
          message: 'A refund line must be priced as this bill sold it.',
          details: {
            lines: mispriced.map((d) => ({
              productId: d.productId,
              price: fromSatang(d.priceSatang),
              soldAt: (sold.pricesByProduct.get(d.productId) ?? []).map(
                (satang) => fromSatang(satang),
              ),
            })),
          },
        },
        HttpStatus.CONFLICT,
      );
    }

    const lines: string[] = [];
    for (const d of demands) {
      const key = priceKey(d.productId, d.priceSatang);
      const line = sold.byPrice.get(key);
      if (!line) {
        lines.push(`${d.requestedName}: ไม่อยู่ในบิลนี้`);
        continue;
      }
      // Bounded per product-and-price, and never above what the product has left
      // overall: a credit note imported from the old app may carry a price this bill
      // never charged, and no per-price figure can see that quantity.
      const remaining = Math.min(
        line.qty - (refunded.byPrice.get(key) ?? 0),
        (sold.qtyByProduct.get(d.productId) ?? 0) -
          (refunded.byProduct.get(d.productId) ?? 0),
      );
      if (d.qty > remaining) {
        lines.push(
          `${d.requestedName}: คืนได้อีก ${remaining} แต่ขอคืน ${d.qty}`,
        );
      }
    }
    if (lines.length > 0) {
      throw new HttpException(
        {
          code: 'OVER_REFUND',
          message: `คืนเกินจำนวนที่ขาย:\n${lines.join('\n')}`,
        },
        HttpStatus.CONFLICT,
      );
    }
  }

  /**
   * Takes the mechanic's row lock before any product is touched, and reads the two
   * running totals the reversal needs as they stand under it.
   *
   * No row is not an error: `sales.mechanic_id` is a foreign key, so a bill naming
   * one has one, and the Dart reference skips the reversal rather than failing.
   */
  private async lockMechanic(
    manager: EntityManager,
    tenantId: string,
    mechanicId: string | null,
  ): Promise<{ total_discount: string; total_credit: string } | null> {
    if (mechanicId === null) return null;
    const rows = (await manager.query(
      `SELECT total_discount, total_credit FROM mechanics
        WHERE tenant_id = $1::uuid AND id = $2 FOR UPDATE`,
      [tenantId, mechanicId],
    )) as { total_discount: string; total_credit: string }[];
    return rows.length === 0 ? null : rows[0];
  }

  /**
   * Locks every product this credit note puts back, in id order — the same deadlock
   * guard the sale takes.
   *
   * 🔴 **Soft-deleted products included.** They used to be filtered out here, so the
   * same goods came back onto the shelf through `POST /sales/:id/void` and silently
   * did not through `POST /returns` — and on this path with no `movements` row to say
   * they had come back at all. Restoring is the defensible half: the goods physically
   * exist again, and a product taken off the catalogue is still a product the shop is
   * holding.
   */
  private lockProducts(
    manager: EntityManager,
    tenantId: string,
    demands: Demand[],
  ): Promise<{ id: string }[]> {
    return manager.query(
      `SELECT id FROM products
        WHERE tenant_id = $1::uuid AND id = ANY($2::text[])
        ORDER BY id
          FOR UPDATE`,
      [tenantId, demands.map((d) => d.productId)],
    ) as Promise<{ id: string }[]>;
  }

  /** Inserts the header. Returns the date Postgres stamped on it. */
  private async insertReturn(
    manager: EntityManager,
    tenantId: string,
    returnId: string,
    cnNo: string,
    dto: CreateReturn,
    sale: LockedSale,
    money: RefundAmounts,
    shiftId: string | null,
  ): Promise<string> {
    const rows = (await manager.query(
      `INSERT INTO returns (
         tenant_id, id, cn_no, sale_id, receipt_no, refund_subtotal, refund_discount,
         refund_total, refund_method, reason, customer_id, mechanic_id, mechanic_name, shift_id)
       VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
       RETURNING date`,
      [
        tenantId,
        returnId,
        cnNo,
        dto.saleId,
        // Copied off the parent bill, not sent by the client: the credit note has to
        // name the receipt it credits, and the client cannot be the authority on that.
        sale.receipt_no,
        fromSatang(money.refundSubtotalSatang),
        fromSatang(money.refundDiscountSatang),
        fromSatang(money.refundTotalSatang),
        dto.refundMethod,
        dto.reason,
        sale.customer_id,
        sale.mechanic_id,
        sale.mechanic_name,
        shiftId,
      ],
    )) as { date: Date }[];
    return rows[0].date.toISOString();
  }

  /**
   * Inserts the lines, `cost_at_sale` copied from the **parent sale line** read above
   * (ADR-0008, #22). Never re-read from `products.cost`: a weighted-average PO receive
   * rewrites that column, so profit-after-returns on an old bill would drift with
   * whatever stock was bought in since.
   */
  private async insertLines(
    manager: EntityManager,
    tenantId: string,
    returnId: string,
    demands: Demand[],
    sold: Sold,
  ): Promise<ReturnLineOut[]> {
    const out: ReturnLineOut[] = [];
    for (const [i, d] of demands.entries()) {
      const lineNo = i + 1;
      const costAtSale =
        sold.byPrice.get(priceKey(d.productId, d.priceSatang))?.costAtSale ??
        null;
      await manager.query(
        `INSERT INTO return_items (
           tenant_id, return_id, line_no, product_id, name, qty, price, original_qty, cost_at_sale)
         VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8, $9)`,
        [
          tenantId,
          returnId,
          lineNo,
          d.productId,
          d.requestedName,
          d.qty,
          fromSatang(d.priceSatang),
          d.originalQty,
          costAtSale,
        ],
      );
      out.push({
        lineNo,
        productId: d.productId,
        name: d.requestedName,
        qty: d.qty,
        price: fromSatang(d.priceSatang),
        originalQty: d.originalQty,
        costAtSale,
      });
    }
    return out;
  }

  /**
   * Puts the goods back and writes one ledger row per **product** — the demands are
   * per product-and-price, and a credit note taking one part back at two prices must
   * still write a single row: `uq_movements_ref` is unique on
   * `(tenant_id, type, ref_id, product_id)` and the second would be a 500.
   *
   * `ref_id` is the **return** id, not the sale's, for the same index: keying on the
   * sale would let the first credit note against a bill take the slot.
   */
  private async restoreStock(
    manager: EntityManager,
    tenantId: string,
    returnId: string,
    demands: Demand[],
    locked: { id: string }[],
  ): Promise<{ stockAfter: Map<string, number>; movements: MovementOut[] }> {
    const alive = new Set(locked.map((p) => p.id));
    const byProduct = new Map<string, number>();
    for (const d of demands) {
      byProduct.set(d.productId, (byProduct.get(d.productId) ?? 0) + d.qty);
    }

    const stockAfter = new Map<string, number>();
    const movements: MovementOut[] = [];
    for (const [productId, qty] of byProduct) {
      // Only a product with no row at all, which a sold one cannot be: `movements`
      // has a foreign key to `products` with no cascade and every sale writes a row
      // per product, so deleting a product that has ever sold can only ever set
      // `deleted_at` — and `lockProducts` now returns those too.
      if (!alive.has(productId)) continue;
      const updated = returning<{
        stock: number;
        part_no: string;
        name: string;
      }>(
        await manager.query(
          `UPDATE products
              SET stock = stock + $3, updated_at = now()
            WHERE tenant_id = $1::uuid AND id = $2
        RETURNING stock, part_no, name`,
          [tenantId, productId, qty],
        ),
      );
      stockAfter.set(productId, updated[0].stock);

      // `RETURNING` rather than a second read (#82): the row's `id` and `date` are
      // the database's, and the client has nowhere else to get them.
      const written = returning<MovementRow>(
        await manager.query(
          `INSERT INTO movements (
           tenant_id, id, product_id, part_no, name, delta, type, stock_after, ref_id)
         VALUES ($1::uuid, $2, $3, $4, $5, $6, 'return', $7, $8)
       RETURNING ${MOVEMENT_COLUMNS}`,
          [
            tenantId,
            newId('mv'),
            productId,
            updated[0].part_no,
            updated[0].name,
            qty,
            updated[0].stock,
            returnId,
          ],
        ),
      );
      movements.push(movementOut(written[0]));
    }
    return { stockAfter, movements };
  }

  /**
   * Reverses the customer's spend and points in proportion.
   *
   * `basePoints` falls back to `floor(total / 10)` when the bill recorded none, which
   * is what `returns_repository.dart` does for bills imported from the old app; the
   * reversal is then `floor(basePoints × ratio)`, floored exactly as the reference
   * floors it, so a quarter of a 34-point bill gives back 8, not 9.
   */
  private async reverseCustomer(
    manager: EntityManager,
    tenantId: string,
    sale: LockedSale,
    money: RefundAmounts,
  ): Promise<CustomerAfter | null> {
    if (sale.customer_id === null) return null;
    const basePoints =
      sale.points_granted > 0
        ? sale.points_granted
        : Math.floor(money.saleTotalSatang / 1000);
    const pointsToReverse =
      money.saleTotalSatang > 0
        ? Math.floor(
            (basePoints * money.refundTotalSatang) / money.saleTotalSatang,
          )
        : 0;

    const rows = returning<{ id: string; points: number; total_spend: string }>(
      await manager.query(
        `UPDATE customers
            SET points = GREATEST(0, points - $3),
                total_spend = GREATEST(0, total_spend - $4),
                updated_at = now()
          WHERE tenant_id = $1::uuid AND id = $2
      RETURNING id, points, total_spend`,
        [
          tenantId,
          sale.customer_id,
          pointsToReverse,
          fromSatang(money.refundTotalSatang),
        ],
      ),
    );
    return rows.length === 0
      ? null
      : {
          id: rows[0].id,
          points: rows[0].points,
          totalSpend: fromSatang(satangOf(rows[0].total_spend)),
        };
  }

  /**
   * Reverses the mechanic's statistics and, only for `'หักจากเครดิต'`, his tab.
   *
   * 🔴 `credit_balance` moves on that one string and nothing else. A cash refund on a
   * credit sale deliberately leaves the tab alone — the shop hands over cash and the
   * mechanic still owes what he owed, which is exactly why the Returns screen warns
   * staff before it lets them choose cash on a credit bill.
   *
   * 🔴 `total_credit` is **read and never written** (decision #11): it is the JS app's
   * legacy alias of `total_discount`, and the `(total_discount || total_credit)`
   * fallback below is the old app's own, kept so a mechanic imported from it reverses
   * against the figure his screen actually shows.
   */
  private async reverseMechanic(
    manager: EntityManager,
    tenantId: string,
    sale: LockedSale,
    mechanic: { total_discount: string; total_credit: string } | null,
    refundMethod: string,
    money: RefundAmounts,
  ): Promise<MechanicAfter | null> {
    if (sale.mechanic_id === null || mechanic === null) return null;

    const origDelta =
      sale.mechanic_delta === null ? 0 : satangOf(sale.mechanic_delta);
    // In proportion to what this credit note takes back, never in full — the same
    // share `reverseCustomer` uses for the points.
    const inProportion = (satang: number): number =>
      money.saleTotalSatang > 0
        ? Math.round((satang * money.refundTotalSatang) / money.saleTotalSatang)
        : 0;
    // A negative delta was a discount given to the mechanic, a positive one a markup.
    const reverseCredit = origDelta < 0 ? inProportion(-origDelta) : 0;
    const reverseMarkup = origDelta > 0 ? inProportion(origDelta) : 0;
    const reduceBalance =
      refundMethod === DEDUCT_FROM_CREDIT ? money.refundTotalSatang : 0;
    const totalDiscount = satangOf(mechanic.total_discount);
    const discountBaseSatang =
      totalDiscount !== 0 ? totalDiscount : satangOf(mechanic.total_credit);

    const rows = returning<MechanicRow>(
      await manager.query(
        `UPDATE mechanics
            SET total_sales = GREATEST(0, total_sales - $3),
                total_discount = GREATEST(0, $4::numeric),
                total_markup = GREATEST(0, total_markup - $5),
                credit_balance = GREATEST(0, credit_balance - $6),
                updated_at = now()
          WHERE tenant_id = $1::uuid AND id = $2
      RETURNING id, total_sales, total_discount, total_markup, credit_balance`,
        [
          tenantId,
          sale.mechanic_id,
          fromSatang(money.refundTotalSatang),
          // Assigned, not subtracted: the base is `total_discount` unless it is zero,
          // in which case it is the legacy `total_credit`. Safe to compute in Node
          // because this row has been locked since `lockMechanic`. The `::numeric`
          // on it is load-bearing — with no column in the GREATEST to infer from,
          // Postgres types the parameter from the literal `0` and rejects `"0.00"`
          // as an integer.
          fromSatang(discountBaseSatang - reverseCredit),
          fromSatang(reverseMarkup),
          fromSatang(reduceBalance),
        ],
      ),
    );
    // 🔴 `total_credit` is not in the answer, only in the read above: it is the legacy
    // alias this method reverses *against*, never a figure the client may patch (#11).
    return rows.length === 0 ? null : toMechanicAfter(rows[0]);
  }

  /**
   * Voids the parent bill once every unit on it has come back — cumulative quantity
   * across all credit notes, this one included, exactly as the old app decides it.
   * The bill is already locked, so this read cannot race a concurrent return.
   */
  private async autoVoid(
    manager: EntityManager,
    tenantId: string,
    saleId: string,
    sold: Sold,
  ): Promise<boolean> {
    const refunded = await this.refundedSoFar(manager, tenantId, saleId);
    const refundedTotal = [...refunded.byProduct.values()].reduce(
      (s, q) => s + q,
      0,
    );
    const soldTotal = [...sold.qtyByProduct.values()].reduce((s, q) => s + q, 0);
    if (refundedTotal < soldTotal) return false;

    await manager.query(
      `UPDATE sales SET voided = TRUE, voided_at = now()
        WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, saleId],
    );
    return true;
  }
}

/** The four figures on the credit note, in integer satang. */
interface RefundAmounts {
  refundSubtotalSatang: number;
  refundDiscountSatang: number;
  refundTotalSatang: number;
  saleTotalSatang: number;
}

/**
 * The refund carries the parent bill's discount at the same rate it was given:
 * `refundDiscount = round2(refundSubtotal × discount / subtotal)`.
 *
 * In integer satang throughout, the way `sales.service.ts` handles money — a refund
 * is a sum of lines, and `0.1 + 0.2` is how a credit note ends up a satang off the
 * bill it credits. `Math.round` on a non-negative value is the Dart `round2`
 * (`(v * 100).round() / 100`, half away from zero) to the satang.
 *
 * Every `priceSatang` summed here has already been matched against a price the bill
 * actually charged (`assertRefundable`), which is what makes this the bill's money
 * rather than the client's.
 */
function refundAmounts(demands: Demand[], sale: LockedSale): RefundAmounts {
  const refundSubtotalSatang = demands.reduce(
    (s, d) => s + d.qty * d.priceSatang,
    0,
  );
  const saleSubtotalSatang = satangOf(sale.subtotal);
  const refundDiscountSatang =
    saleSubtotalSatang > 0
      ? Math.round(
          (refundSubtotalSatang * satangOf(sale.discount)) / saleSubtotalSatang,
        )
      : 0;
  return {
    refundSubtotalSatang,
    refundDiscountSatang,
    // Both operands are already whole satang, so the reference's second `round2` is
    // a no-op here.
    refundTotalSatang: refundSubtotalSatang - refundDiscountSatang,
    saleTotalSatang: satangOf(sale.total),
  };
}

/**
 * Collapses the credit note to one demand per product **and price**, keeping the order
 * the lines were asked for so the Thai error reads in the order staff typed.
 *
 * The Dart reference checks each line separately against the remaining quantity, so a
 * credit note listing the same part on two lines can pass the guard and jointly
 * over-refund. Summing first turns that into the ordinary Thai message instead of a
 * silent over-refund, the way `sales.service.ts` does.
 *
 * 🔴 Summing **only lines that agree on the price**. Collapsing by product alone kept
 * the first line's price and multiplied it by the whole quantity, so `[p1×1@85,
 * p1×1@70]` refunded 170 where the reference refunds 155 — and the stored
 * `return_items` row then matched neither the bill nor the request. Two prices stay two
 * demands: each keeps its own money, its own row, and its own slice of the guard.
 */
function aggregate(items: ReturnLine[]): Demand[] {
  const byProduct = new Map<string, Demand>();
  for (const [i, line] of items.entries()) {
    const key = priceKey(line.productId, line.priceSatang);
    const existing = byProduct.get(key);
    if (existing) existing.qty += line.qty;
    else
      byProduct.set(key, {
        productId: line.productId,
        qty: line.qty,
        priceSatang: line.priceSatang,
        originalQty: line.originalQty,
        requestedName: line.name,
        firstLineIndex: i,
      });
  }
  return [...byProduct.values()].sort(
    (a, b) => a.firstLineIndex - b.firstLineIndex,
  );
}

interface ReturnRow {
  id: string;
  cn_no: string;
  sale_id: string;
  receipt_no: string;
  refund_subtotal: string;
  refund_discount: string;
  refund_total: string;
  refund_method: string;
  reason: string;
  customer_id: string | null;
  mechanic_id: string | null;
  mechanic_name: string | null;
  date: Date;
  shift_id: string | null;
}

const RETURN_COLUMNS = `id, cn_no, sale_id, receipt_no, refund_subtotal, refund_discount,
                        refund_total, refund_method, reason, customer_id, mechanic_id,
                        mechanic_name, date, shift_id`;

function toReturn(row: ReturnRow, items: ReturnLineOut[]): ReturnWithItems {
  return {
    id: row.id,
    cnNo: row.cn_no,
    saleId: row.sale_id,
    receiptNo: row.receipt_no,
    refundSubtotal: row.refund_subtotal,
    refundDiscount: row.refund_discount,
    refundTotal: row.refund_total,
    refundMethod: row.refund_method,
    reason: row.reason,
    customerId: row.customer_id,
    mechanicId: row.mechanic_id,
    mechanicName: row.mechanic_name,
    date: row.date.toISOString(),
    shiftId: row.shift_id,
    items,
  };
}
