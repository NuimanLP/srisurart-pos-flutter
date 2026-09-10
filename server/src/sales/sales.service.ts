import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { newId } from '../common/ids.js';
import { fromSatang, pointsFor } from '../common/money.js';
import { currentRequestContext } from '../common/request-context.js';
import { returning } from '../common/sql.js';
import { DocNumberService } from '../documents/doc-number.service.js';
import type { CreateSale, SaleLine } from './sales.dto.js';

/** Who is ringing the bill up — read from the token, never from the body. */
export interface SaleActor {
  userId: string;
  deviceId: string;
}

/** What `POST /sales` answers with (02_API_SCREENS.md §3.1). */
export interface CreateSaleResult {
  id: string;
  receiptNo: string;
  total: string;
  pointsGranted: number;
  date: string;
  /** Every product this bill touched, so the client patches its cache without a re-read. */
  products: { id: string; stock: number }[];
}

/** A product row as the locking select returns it. */
interface LockedProduct {
  id: string;
  part_no: string;
  name: string;
  name_th: string;
  cost: string;
  stock: number;
}

/** How much of one product the whole bill wants, and where it was first asked for. */
interface Demand {
  productId: string;
  qty: number;
  /** The name the client used, for the "not in stock" line — that product has no row. */
  requestedName: string;
  firstLineIndex: number;
}

/** The client's arithmetic may differ from ours by this much and still be believed. */
const TOTAL_TOLERANCE_SATANG = 1;

/**
 * The sale transaction — the heart of the system.
 *
 * Everything below runs inside the request's transaction (`RequestContextMiddleware`
 * opened it, `TransactionInterceptor` commits it), in the order #20 fixes:
 *
 *   1. the idempotency claim (the interceptor, before this method is called)
 *   2. `SELECT ... ORDER BY id FOR UPDATE` — the ordering is the deadlock guard
 *   3. build the *complete* Thai error from that locked read
 *   4. deduct, keeping `stock >= qty` in the predicate as an assertion
 *   5. issue the receipt number
 *   6. insert the header and the lines, `cost_at_sale` from the same locked read
 *   7. insert the `movements` rows
 *   8. commit — and only then may anything external happen
 *
 * This closes a real race the Dart reference has: `sales_repository.dart` pre-checks
 * stock *outside* its transaction and then opens one to deduct. It has never bitten
 * because the shop has one machine.
 *
 * The customer and mechanic ledger effects are deliberately **not** here: they are
 * #21, which is blocked on #11 (`mechanics.total_credit` — the design doc and the
 * Dart reference disagree, and only the project owner can settle it).
 */
@Injectable()
export class SalesService {
  constructor(private readonly docNumbers: DocNumberService) {}

  async create(dto: CreateSale, actor: SaleActor): Promise<CreateSaleResult> {
    const { tenantId, manager } = currentRequestContext();

    const demands = aggregate(dto.items);
    const locked = await this.lockProducts(manager, tenantId, demands);
    this.assertStock(demands, locked);
    this.assertTotals(dto);

    const stockAfter = await this.deduct(manager, tenantId, demands, locked);

    const receiptNo = await this.docNumbers.issue(manager, {
      tenantId,
      deviceId: actor.deviceId,
      docType: 'receipt',
    });

    const pointsGranted = pointsFor(dto.totalSatang);
    const date = await this.insertSale(
      manager,
      tenantId,
      dto,
      actor,
      receiptNo,
      pointsGranted,
    );
    await this.insertLines(manager, tenantId, dto, locked);
    await this.insertMovements(manager, tenantId, dto.id, demands, locked, stockAfter);

    return {
      id: dto.id,
      receiptNo,
      total: fromSatang(dto.totalSatang),
      pointsGranted,
      date,
      // Deliberately no `offlineOk`: it has no storage in phase 1, and a field the
      // server invents is a field the client will eventually trust.
      products: demands.map((d) => ({
        id: d.productId,
        stock: stockAfter.get(d.productId)!,
      })),
    };
  }

  /**
   * Locks every product on the bill, in id order.
   *
   * **The ordering is the deadlock guard, not decoration:** two bills sharing two
   * products, each locking them in its own arrival order, deadlock; locking both in
   * the same order makes the second wait instead.
   */
  private lockProducts(
    manager: EntityManager,
    tenantId: string,
    demands: Demand[],
  ): Promise<LockedProduct[]> {
    return manager.query(
      `SELECT id, part_no, name, name_th, cost, stock
         FROM products
        WHERE tenant_id = $1::uuid AND id = ANY($2::text[]) AND deleted_at IS NULL
        ORDER BY id
          FOR UPDATE`,
      [tenantId, demands.map((d) => d.productId)],
    ) as Promise<LockedProduct[]>;
  }

  /**
   * Builds the **whole** Thai error from the locked read and throws once for the bill.
   *
   * `UPDATE ... WHERE stock >= qty` cannot do this: a row count of zero cannot tell
   * "not enough" from "no such product". Nor can failing fast on the first bad line —
   * staff would re-submit the bill once per missing item to discover what is short.
   * Strings are verbatim from `sales_repository.dart`, which ported them from `db.js`.
   */
  private assertStock(demands: Demand[], locked: LockedProduct[]): void {
    const byId = new Map(locked.map((p) => [p.id, p]));
    const lines: string[] = [];
    const details: { productId: string; stock: number | null; requested: number }[] = [];

    for (const d of demands) {
      const p = byId.get(d.productId);
      if (!p) {
        lines.push(`${d.requestedName}: ไม่พบในสต็อก`);
        details.push({ productId: d.productId, stock: null, requested: d.qty });
      } else if (p.stock < d.qty) {
        lines.push(`${p.name}: สต็อก ${p.stock} แต่ต้องการ ${d.qty}`);
        details.push({ productId: d.productId, stock: p.stock, requested: d.qty });
      }
    }

    if (lines.length > 0) {
      throw new HttpException(
        {
          code: 'INSUFFICIENT_STOCK',
          message: `สต็อกไม่พอ:\n${lines.join('\n')}`,
          details,
        },
        HttpStatus.CONFLICT,
      );
    }
  }

  /**
   * The client owns the money because the receipt is already printed; the server
   * checks its arithmetic (§1.3). More than one satang apart is `409 TOTAL_MISMATCH`;
   * within tolerance the client's own values are what get stored.
   *
   * The server never compares a line price against the catalogue price — a bill rung
   * up at a haggled price is an ordinary day at this counter, not an error.
   */
  private assertTotals(dto: CreateSale): void {
    const computedSubtotal = dto.items.reduce((sum, i) => sum + i.qty * i.priceSatang, 0);
    const computedTotal = computedSubtotal - dto.discountSatang;
    const off =
      Math.abs(computedSubtotal - dto.subtotalSatang) > TOTAL_TOLERANCE_SATANG ||
      Math.abs(computedTotal - dto.totalSatang) > TOTAL_TOLERANCE_SATANG;

    if (off) {
      throw new HttpException(
        {
          code: 'TOTAL_MISMATCH',
          message: 'ยอดเงินไม่ตรงกัน กรุณาทำรายการใหม่',
          details: {
            subtotal: fromSatang(computedSubtotal),
            total: fromSatang(computedTotal),
          },
        },
        HttpStatus.CONFLICT,
      );
    }
  }

  /**
   * Deducts, strictly. `stock >= qty` stays in the predicate as an assertion against
   * our own bugs — the rows are already locked, so it can only fail if something
   * above this line is wrong, and a silent clamp to zero would hide inventory loss.
   * (`adjustStock` is the one path that may clamp; a sale never is.)
   */
  private async deduct(
    manager: EntityManager,
    tenantId: string,
    demands: Demand[],
    locked: LockedProduct[],
  ): Promise<Map<string, number>> {
    const stockAfter = new Map<string, number>();
    // In id order, like the lock: the rows are already held, but keeping one order
    // everywhere is what makes that easy to keep true.
    const inLockOrder = [...demands].sort((a, b) =>
      a.productId < b.productId ? -1 : a.productId > b.productId ? 1 : 0,
    );
    for (const d of inLockOrder) {
      const rows = returning<{ stock: number }>(
        await manager.query(
          `UPDATE products
              SET stock = stock - $3, updated_at = now()
            WHERE tenant_id = $1::uuid AND id = $2 AND stock >= $3
        RETURNING stock`,
          [tenantId, d.productId, d.qty],
        ),
      );

      if (rows.length === 0) {
        const before = locked.find((p) => p.id === d.productId)?.stock;
        throw new Error(
          `Stock underflow on ${d.productId}: locked at ${before}, wanted ${d.qty}.`,
        );
      }
      stockAfter.set(d.productId, rows[0].stock);
    }
    return stockAfter;
  }

  /** Inserts the header. Returns the date Postgres stamped on it. */
  private async insertSale(
    manager: EntityManager,
    tenantId: string,
    dto: CreateSale,
    actor: SaleActor,
    receiptNo: string,
    pointsGranted: number,
  ): Promise<string> {
    const rows = (await manager.query(
      `INSERT INTO sales (
         tenant_id, id, receipt_no, subtotal, discount, total, payment_method,
         customer_id, customer_name, mechanic_id, mechanic_name, mechanic_delta,
         points_granted, user_id, device_id)
       VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14::uuid, $15)
       RETURNING date`,
      [
        tenantId,
        dto.id,
        receiptNo,
        fromSatang(dto.subtotalSatang),
        fromSatang(dto.discountSatang),
        fromSatang(dto.totalSatang),
        dto.paymentMethod,
        dto.customerId,
        dto.customerName,
        dto.mechanicId,
        dto.mechanicName,
        dto.mechanicDeltaSatang === null ? null : fromSatang(dto.mechanicDeltaSatang),
        pointsGranted,
        actor.userId,
        actor.deviceId,
      ],
    )) as { date: Date }[];
    return rows[0].date.toISOString();
  }

  /**
   * Inserts the lines, `cost_at_sale` taken from the **same locked read** (ADR-0008).
   * Never re-read outside the transaction — `products.cost` is recomputed by every
   * weighted-average PO receive, so the profit on an old bill would silently change
   * whenever new stock is bought in — and never accepted from the client.
   */
  private async insertLines(
    manager: EntityManager,
    tenantId: string,
    dto: CreateSale,
    locked: LockedProduct[],
  ): Promise<void> {
    const byId = new Map(locked.map((p) => [p.id, p]));
    for (const [i, line] of dto.items.entries()) {
      await manager.query(
        `INSERT INTO sale_items (
           tenant_id, sale_id, line_no, product_id, part_no, name, name_th, qty, price, cost_at_sale)
         VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
        [
          tenantId,
          dto.id,
          // The client's `lineNo` only orders the receipt; the primary key needs it
          // unique, and two lines carrying the same number is a client bug that must
          // not become a 500.
          i + 1,
          line.productId,
          line.partNo ?? byId.get(line.productId)?.part_no ?? null,
          line.name,
          line.nameTH,
          line.qty,
          fromSatang(line.priceSatang),
          byId.get(line.productId)!.cost,
        ],
      );
    }
  }

  /**
   * One ledger row per product, not per line: `uq_movements_ref` is unique on
   * `(tenant_id, type, ref_id, product_id)`, and a bill listing the same part twice
   * is one movement of the summed quantity.
   */
  private async insertMovements(
    manager: EntityManager,
    tenantId: string,
    saleId: string,
    demands: Demand[],
    locked: LockedProduct[],
    stockAfter: Map<string, number>,
  ): Promise<void> {
    const byId = new Map(locked.map((p) => [p.id, p]));
    for (const d of demands) {
      const p = byId.get(d.productId)!;
      await manager.query(
        `INSERT INTO movements (
           tenant_id, id, product_id, part_no, name, delta, type, stock_after, ref_id)
         VALUES ($1::uuid, $2, $3, $4, $5, $6, 'sale', $7, $8)`,
        [
          tenantId,
          newId('mv'),
          d.productId,
          p.part_no,
          p.name,
          -d.qty,
          stockAfter.get(d.productId),
          saleId,
        ],
      );
    }
  }
}

/**
 * Collapses the bill to one demand per product, keeping the order the lines were
 * asked for so the Thai error reads in the order staff typed.
 *
 * The Dart reference checks each line against the full stock separately, so a bill
 * listing the same part on two lines can pass the check and then underflow. Summing
 * first is the same behaviour for every bill the UI can actually build — it merges
 * lines by product — and it turns that case into the ordinary Thai message instead
 * of a 500.
 */
function aggregate(items: SaleLine[]): Demand[] {
  const byProduct = new Map<string, Demand>();
  for (const [i, line] of items.entries()) {
    const existing = byProduct.get(line.productId);
    if (existing) existing.qty += line.qty;
    else
      byProduct.set(line.productId, {
        productId: line.productId,
        qty: line.qty,
        requestedName: line.name,
        firstLineIndex: i,
      });
  }
  return [...byProduct.values()].sort((a, b) => a.firstLineIndex - b.firstLineIndex);
}
