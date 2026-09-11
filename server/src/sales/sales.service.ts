import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { AuditService } from '../audit/audit.service.js';
import { newId } from '../common/ids.js';
import { fromSatang, pointsFor, satangOf } from '../common/money.js';
import { currentRequestContext } from '../common/request-context.js';
import { returning } from '../common/sql.js';
import { DocNumberService } from '../documents/doc-number.service.js';
import { ShiftsService } from '../shifts/shifts.service.js';
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
  /** The mechanic's balance once this bill is on it; null when the bill names none. */
  mechanicCreditBalanceAfter: string | null;
  /** The customer's row after the bill (ADR-0010 §3); null when the bill names none. */
  customerAfter: CustomerAfter | null;
}

export interface CustomerAfter {
  id: string;
  points: number;
  totalSpend: string;
}

/** What `lockMechanicAndCheckLimit` hands back when the bill went past the limit on the flag. */
interface CreditOverride {
  creditLimit: number;
  creditBalanceBefore: number;
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

/** A customer row as the ledger update and the replay read return it. */
interface CustomerRow {
  id: string;
  points: number;
  total_spend: string;
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

/** Postgres `unique_violation` — the bill's own primary key, under a race. */
const UNIQUE_VIOLATION = '23505';

/** Postgres `foreign_key_violation` — an unknown `customer_id` / `mechanic_id`. */
const FOREIGN_KEY_VIOLATION = '23503';

/** The one payment method that goes on the mechanic's tab instead of into the drawer. */
const MECHANIC_CREDIT = 'เครดิตช่าง';

/**
 * The sale transaction — the heart of the system.
 *
 * Everything below runs inside the request's transaction (`RequestContextMiddleware`
 * opened it, `TransactionInterceptor` commits it), in the order #20 fixes:
 *
 *   1. the idempotency claim (the interceptor, before this method is called)
 *   2. lock the mechanic's row, if the bill names one, and for a credit sale check
 *      the limit — refused here, the bill holds no product lock
 *   3. `SELECT ... ORDER BY id FOR UPDATE` — the ordering is the deadlock guard
 *   4. build the *complete* Thai error from that locked read
 *   5. deduct, keeping `stock >= qty` in the predicate as an assertion
 *   6. issue the receipt number
 *   7. insert the header and the lines, `cost_at_sale` from the same locked read
 *   8. insert the `movements` rows
 *   9. the ledger: customer points and spend, the mechanic's tab and statistics
 *      (#21, rule for rule from `sales_repository.dart`), and the audit row when
 *      the bill went past the credit limit on `overrideCreditLimit`
 *  10. commit — and only then may anything external happen
 *
 * This closes a real race the Dart reference has: `sales_repository.dart` pre-checks
 * stock *outside* its transaction and then opens one to deduct. It has never bitten
 * because the shop has one machine.
 */
@Injectable()
export class SalesService {
  constructor(
    private readonly docNumbers: DocNumberService,
    private readonly shifts: ShiftsService,
    private readonly audit: AuditService,
  ) {}

  async create(dto: CreateSale, actor: SaleActor): Promise<CreateSaleResult> {
    const { tenantId, manager } = currentRequestContext();

    // Arithmetic first: a 409 for a total that does not add up must not take
    // `FOR UPDATE` on every product on the bill and hold them until rollback.
    this.assertTotals(dto);

    // §3.1 makes the client's `id` a natural idempotency key. A retry that lost its
    // Idempotency-Key — a page reload, an app restart — must not be a 500 on the
    // primary key: the bill really was written, and an error here sends staff to ring
    // it up a second time.
    const existing = await this.existingSale(manager, tenantId, dto);
    if (existing) return existing;

    // Mechanic before products, always: a bill refused for the credit limit must not
    // be holding product locks while it rolls back, and the check and the balance
    // update below have to sit under one lock or two credit bills can both pass.
    // Every bill naming a mechanic takes this lock, not just credit ones — a cash
    // bill that locked products first and the mechanic later would deadlock against
    // a credit bill for the same mechanic sharing one product.
    const override = await this.lockMechanicAndCheckLimit(manager, tenantId, dto);

    const demands = aggregate(dto.items);
    const locked = await this.lockProducts(manager, tenantId, demands);
    this.assertStock(demands, locked);

    const stockAfter = await this.deduct(manager, tenantId, demands, locked);

    const receiptNo = await this.docNumbers.issue(manager, {
      tenantId,
      deviceId: actor.deviceId,
      docType: 'receipt',
    });

    const pointsGranted = pointsFor(dto.totalSatang);
    // Stamped at write time from the device's own open drawer, never from the body
    // (#28): the closing report is computed by `shift_id`, and a timestamp window
    // breaks across midnight and cannot separate two machines. Null when the drawer
    // was never opened — the old app lets staff sell without it, and refusing the
    // sale would be a new rule rather than a ported one.
    const shiftId = await this.shifts.currentShiftIdFor(
      manager,
      tenantId,
      actor.deviceId,
    );
    const date = await this.insertSale(
      manager,
      tenantId,
      dto,
      actor,
      receiptNo,
      pointsGranted,
      shiftId,
    );
    await this.insertLines(manager, tenantId, dto, locked);
    await this.insertMovements(
      manager,
      tenantId,
      dto.id,
      demands,
      locked,
      stockAfter,
    );

    const customerAfter = await this.applyCustomer(
      manager,
      tenantId,
      dto,
      pointsGranted,
    );
    const mechanicCreditBalanceAfter = await this.applyMechanic(
      manager,
      tenantId,
      dto,
    );
    if (override && mechanicCreditBalanceAfter !== null) {
      // §8.2: who let this bill past the limit, and by how much. On the request
      // transaction on purpose — an override recorded for a bill that rolled back
      // would be a lie.
      await this.audit.log(manager, {
        tenantId,
        userId: actor.userId,
        deviceId: actor.deviceId,
        action: 'sale.credit_limit_override',
        entity: 'mechanic',
        entityId: dto.mechanicId!,
        after: {
          saleId: dto.id,
          total: fromSatang(dto.totalSatang),
          creditLimit: fromSatang(override.creditLimit),
          creditBalanceBefore: fromSatang(override.creditBalanceBefore),
          creditBalanceAfter: mechanicCreditBalanceAfter,
        },
      });
    }

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
      mechanicCreditBalanceAfter,
      customerAfter,
    };
  }

  /**
   * Takes the mechanic's row lock for the rest of the transaction and, when the bill
   * is going on the tab, checks the limit — `newBalance > creditLimit`, exactly the
   * test in `checkout_screen.dart:561`, with no special case for a limit of 0.
   *
   * Over the limit without the flag is `409 CREDIT_LIMIT_EXCEEDED`; the client owns
   * the Thai confirm dialog and resends with `overrideCreditLimit: true`, which is
   * the case this returns non-null for, so the caller can write the audit row. A
   * flag on a bill that was never over the limit is nothing to record.
   *
   * No row is not an error here: `insertSale`'s foreign key already turns an
   * unknown mechanic into the 400 it deserves.
   */
  private async lockMechanicAndCheckLimit(
    manager: EntityManager,
    tenantId: string,
    dto: CreateSale,
  ): Promise<CreditOverride | null> {
    if (dto.mechanicId === null) return null;
    const rows = (await manager.query(
      `SELECT credit_limit, credit_balance FROM mechanics
        WHERE tenant_id = $1::uuid AND id = $2 FOR UPDATE`,
      [tenantId, dto.mechanicId],
    )) as { credit_limit: string; credit_balance: string }[];
    if (rows.length === 0 || dto.paymentMethod !== MECHANIC_CREDIT) return null;

    const creditLimit = satangOf(rows[0].credit_limit);
    const creditBalance = satangOf(rows[0].credit_balance);
    const newBalance = creditBalance + dto.totalSatang;
    if (newBalance <= creditLimit) return null;

    if (!dto.overrideCreditLimit) {
      throw new HttpException(
        {
          code: 'CREDIT_LIMIT_EXCEEDED',
          message:
            'Credit limit exceeded; resend with overrideCreditLimit to confirm.',
          details: {
            creditLimit: fromSatang(creditLimit),
            creditBalance: fromSatang(creditBalance),
            newBalance: fromSatang(newBalance),
          },
        },
        HttpStatus.CONFLICT,
      );
    }
    return { creditLimit, creditBalanceBefore: creditBalance };
  }

  /**
   * `points += pointsGranted`, `total_spend += total` — `sales_repository.dart`, which
   * does not filter on `deleted_at`, so neither does this. `GREATEST(0, …)` is #21's
   * rule for every running total — the `>= 0` CHECKs are assertions that the clamp is
   * present, never a user-facing path. (The Dart sale path has no clamp; only its
   * return path does, and a sale only ever adds.)
   */
  private async applyCustomer(
    manager: EntityManager,
    tenantId: string,
    dto: CreateSale,
    pointsGranted: number,
  ): Promise<CustomerAfter | null> {
    if (dto.customerId === null) return null;
    const rows = returning<CustomerRow>(
      await manager.query(
        `UPDATE customers
            SET points = GREATEST(0, points + $3),
                total_spend = GREATEST(0, total_spend + $4),
                updated_at = now()
          WHERE tenant_id = $1::uuid AND id = $2
      RETURNING id, points, total_spend`,
        [tenantId, dto.customerId, pointsGranted, fromSatang(dto.totalSatang)],
      ),
    );
    return rows.length === 0 ? null : customerAfter(rows[0]);
  }

  /**
   * The mechanic's statistics and tab, rule for rule from `sales_repository.dart`:
   * `total_sales += total`; a negative `mechanic_delta` is a discount given, a
   * positive one a markup; and the bill goes on `credit_balance` only when it was
   * paid with `'เครดิตช่าง'`.
   *
   * 🔴 `total_credit` is never written. It is the JS app's legacy alias of
   * `total_discount` (decision #11); `POST /returns` reads it only as a fallback for
   * the discount base, and a server that also wrote it would double the figure.
   */
  private async applyMechanic(
    manager: EntityManager,
    tenantId: string,
    dto: CreateSale,
  ): Promise<string | null> {
    if (dto.mechanicId === null) return null;
    const delta = dto.mechanicDeltaSatang ?? 0;
    const rows = returning<{ credit_balance: string }>(
      await manager.query(
        `UPDATE mechanics
            SET total_sales = GREATEST(0, total_sales + $3),
                total_discount = GREATEST(0, total_discount + $4),
                total_markup = GREATEST(0, total_markup + $5),
                credit_balance = GREATEST(0, credit_balance + $6),
                updated_at = now()
          WHERE tenant_id = $1::uuid AND id = $2
      RETURNING credit_balance`,
        [
          tenantId,
          dto.mechanicId,
          fromSatang(dto.totalSatang),
          fromSatang(delta < 0 ? -delta : 0),
          fromSatang(delta > 0 ? delta : 0),
          fromSatang(
            dto.paymentMethod === MECHANIC_CREDIT ? dto.totalSatang : 0,
          ),
        ],
      ),
    );
    return rows.length === 0 ? null : money(rows[0].credit_balance);
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
    const details: {
      productId: string;
      stock: number | null;
      requested: number;
    }[] = [];

    for (const d of demands) {
      const p = byId.get(d.productId);
      if (!p) {
        lines.push(`${d.requestedName}: ไม่พบในสต็อก`);
        details.push({ productId: d.productId, stock: null, requested: d.qty });
      } else if (p.stock < d.qty) {
        lines.push(`${p.name}: สต็อก ${p.stock} แต่ต้องการ ${d.qty}`);
        details.push({
          productId: d.productId,
          stock: p.stock,
          requested: d.qty,
        });
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
    const computedSubtotal = dto.items.reduce(
      (sum, i) => sum + i.qty * i.priceSatang,
      0,
    );
    const computedTotal = computedSubtotal - dto.discountSatang;
    const off =
      Math.abs(computedSubtotal - dto.subtotalSatang) >
        TOTAL_TOLERANCE_SATANG ||
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
    // Order does not matter here: `lockProducts` already holds every one of these rows
    // for the rest of the transaction, so no other writer can interleave. (A JS sort
    // would not reproduce the database's collation anyway — every id from `newId`
    // contains underscores, which sort differently — so pretending otherwise in a
    // comment would be worse than saying nothing.)
    for (const d of demands) {
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

  /**
   * The bill already written under this `id`, replayed — or null if there is none.
   *
   * Read before anything is locked or deducted, so a duplicate costs one indexed
   * lookup and touches no stock. The stock reported back is the stock as it stands
   * now, which is what the client's cache should hold either way.
   *
   * A **voided** bill is the one id that is not replayed: see below.
   */
  private async existingSale(
    manager: EntityManager,
    tenantId: string,
    dto: CreateSale,
  ): Promise<CreateSaleResult | null> {
    const rows = (await manager.query(
      `SELECT receipt_no, total, points_granted, date, voided
         FROM sales WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, dto.id],
    )) as {
      receipt_no: string;
      total: string;
      points_granted: number;
      date: Date;
      voided: boolean;
    }[];
    if (rows.length === 0) return null;

    if (satangOf(rows[0].total) !== dto.totalSatang) {
      // A different bill wearing an id that is already taken. `newId` makes this
      // essentially impossible, so it means a client bug — and silently answering with
      // the old bill would lose the new one's money.
      throw new HttpException(
        {
          code: 'SALE_ID_REUSED',
          message: 'A different sale already exists under this id.',
        },
        HttpStatus.CONFLICT,
      );
    }

    if (rows[0].voided) {
      // The bill under this id has been cancelled: its stock is back on the shelf and
      // its money is out of the closing report. Replaying it would answer 201 with a
      // receipt number, a total and points for a bill that no longer stands, and the
      // counter would read that as "the sale went through".
      //
      // The reason a duplicate is replayed rather than refused — a 409 reads at the
      // counter as "it didn't go through", so staff ring the bill up again and the
      // shop really does sell twice — points the other way once the bill is voided:
      // nothing was sold, so ringing it up again is not a second sale, it is the only
      // way to get a bill that stands. Refusing costs one re-ring; replaying lets the
      // goods leave the shop under a bill that was cancelled.
      throw new HttpException(
        { code: 'SALE_VOIDED', message: 'Bill already voided' },
        HttpStatus.CONFLICT,
      );
    }

    const productIds = [...new Set(dto.items.map((i) => i.productId))];
    const stock = (await manager.query(
      `SELECT id, stock FROM products WHERE tenant_id = $1::uuid AND id = ANY($2::text[])`,
      [tenantId, productIds],
    )) as { id: string; stock: number }[];
    // The ledger as it stands now, like the stock above — a replay moves nothing,
    // and null when the id names a row that is gone.
    const customer =
      dto.customerId === null
        ? []
        : ((await manager.query(
            `SELECT id, points, total_spend FROM customers
              WHERE tenant_id = $1::uuid AND id = $2`,
            [tenantId, dto.customerId],
          )) as CustomerRow[]);
    const mechanic =
      dto.mechanicId === null
        ? []
        : ((await manager.query(
            `SELECT credit_balance FROM mechanics
              WHERE tenant_id = $1::uuid AND id = $2`,
            [tenantId, dto.mechanicId],
          )) as { credit_balance: string }[]);

    return {
      id: dto.id,
      receiptNo: rows[0].receipt_no,
      total: money(rows[0].total),
      pointsGranted: rows[0].points_granted,
      date: rows[0].date.toISOString(),
      products: stock.map((p) => ({ id: p.id, stock: p.stock })),
      mechanicCreditBalanceAfter:
        mechanic.length === 0 ? null : money(mechanic[0].credit_balance),
      customerAfter: customer.length === 0 ? null : customerAfter(customer[0]),
    };
  }

  /** Inserts the header. Returns the date Postgres stamped on it. */
  private async insertSale(
    manager: EntityManager,
    tenantId: string,
    dto: CreateSale,
    actor: SaleActor,
    receiptNo: string,
    pointsGranted: number,
    shiftId: string | null,
  ): Promise<string> {
    const rows = (await this.mapConstraintErrors(() =>
      manager.query(
        `INSERT INTO sales (
         tenant_id, id, receipt_no, subtotal, discount, total, payment_method,
         customer_id, customer_name, mechanic_id, mechanic_name, mechanic_delta,
         points_granted, user_id, device_id, shift_id)
       VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14::uuid, $15, $16)
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
          dto.mechanicDeltaSatang === null
            ? null
            : fromSatang(dto.mechanicDeltaSatang),
          pointsGranted,
          actor.userId,
          actor.deviceId,
          shiftId,
        ],
      ),
    )) as { date: Date }[];
    return rows[0].date.toISOString();
  }

  /**
   * Turns the two constraint violations a client can actually provoke into the status
   * they deserve. Without this both are `500 INTERNAL_ERROR`, which tells the counter
   * nothing and tells the client nothing it can act on.
   *
   * `23503` is reachable today for an ordinary reason: `customers` and `mechanics`
   * have no write endpoints yet (#17), so a bill naming one that was never imported
   * is a bad request, not a server fault.
   */
  private async mapConstraintErrors<T>(run: () => Promise<T>): Promise<T> {
    try {
      return await run();
    } catch (err) {
      const code = (err as { code?: string })?.code;
      if (code === UNIQUE_VIOLATION) {
        throw new HttpException(
          {
            code: 'SALE_ID_REUSED',
            message: 'A different sale already exists under this id.',
          },
          HttpStatus.CONFLICT,
        );
      }
      if (code === FOREIGN_KEY_VIOLATION) {
        throw new HttpException(
          {
            code: 'BAD_REQUEST',
            message: `Unknown reference on this sale (${(err as { constraint?: string }).constraint ?? 'foreign key'}).`,
          },
          HttpStatus.BAD_REQUEST,
        );
      }
      throw err;
    }
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
    for (const line of dto.items) {
      await manager.query(
        `INSERT INTO sale_items (
           tenant_id, sale_id, line_no, product_id, part_no, name, name_th, qty, price, cost_at_sale)
         VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
        [
          tenantId,
          dto.id,
          // The client's own numbering: it is what the receipt in the customer's hand
          // says. The DTO has already refused a bill where two lines share a number,
          // which would collide on `(tenant_id, sale_id, line_no)`.
          line.lineNo,
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
  return [...byProduct.values()].sort(
    (a, b) => a.firstLineIndex - b.firstLineIndex,
  );
}

/** A `NUMERIC` as `pg` hands it back, normalised to the wire shape. */
function money(numeric: string): string {
  return fromSatang(satangOf(numeric));
}

function customerAfter(row: CustomerRow): CustomerAfter {
  return { id: row.id, points: row.points, totalSpend: money(row.total_spend) };
}
