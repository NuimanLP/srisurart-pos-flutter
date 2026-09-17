import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { AuditService } from '../audit/audit.service.js';
import { TenantCache } from '../infra/tenant-cache.service.js';
import { newId } from '../common/ids.js';
import { fromSatang, satangOf } from '../common/money.js';
import { currentRequestContext } from '../common/request-context.js';
import { TenantService } from '../common/database/tenant.service.js';
import { returning } from '../common/sql.js';
import { ShiftsService } from '../shifts/shifts.service.js';
import {
  SaleReadsService,
  saleNotFound,
  type SaleWithItems,
} from './sale-reads.service.js';
import { MECHANIC_CREDIT } from './sales.service.js';

/** The bill under its own row lock — everything the void has to undo. */
interface LockedSale {
  voided: boolean;
  shift_id: string | null;
  customer_id: string | null;
  mechanic_id: string | null;
  mechanic_delta: string | null;
  payment_method: string;
  total: string;
  points_granted: number;
}

/** Who is voiding, from the token — plus the reason they provided. */
export interface VoidActor {
  userId: string;
  role: string | undefined;
  deviceId: string;
  reason: string;
  ip?: string;
}

/**
 * The manual void.
 *
 * 🔴 **This endpoint has no equivalent in the old app** — there, a bill is voided only
 * as the automatic consequence of returning every line (`02_API_SCREENS.md §2` lists
 * it under "new, not a port"). #23 asks for it explicitly, so it is built here, but
 * the shop has never had a "void" button and should see one before it ships.
 */
@Injectable()
export class VoidService {
  constructor(
    private readonly reads: SaleReadsService,
    private readonly audit: AuditService,
    private readonly shifts: ShiftsService,
    private readonly cache: TenantCache,
    private readonly tenants: TenantService,
  ) {}

  /**
   * The void itself.
   */
  void(saleId: string, actor: VoidActor): Promise<SaleWithItems> {
    return this.tenants.runTx(() => this.voidIn(saleId, actor));
  }

  private async voidIn(
    saleId: string,
    actor: VoidActor,
  ): Promise<SaleWithItems> {
    const { tenantId, manager } = currentRequestContext();

    // Locked, because two clerks voiding the same bill would otherwise both restore
    // its stock and the shop would gain inventory it never had. The ledger columns
    // ride along on that lock: the reversal has to subtract the figures this bill
    // actually wrote, and it reads them under the same lock that makes it exclusive.
    const rows = (await manager.query(
      `SELECT voided, shift_id, customer_id, mechanic_id, mechanic_delta,
              payment_method, total, points_granted
         FROM sales WHERE tenant_id = $1::uuid AND id = $2 FOR UPDATE`,
      [tenantId, saleId],
    )) as LockedSale[];
    if (rows.length === 0) throw saleNotFound();
    if (rows[0].voided) {
      throw new HttpException(
        { code: 'SALE_VOIDED', message: 'Bill already voided' },
        HttpStatus.CONFLICT,
      );
    }

    const returned = (await manager.query(
      `SELECT count(*)::int AS n FROM returns WHERE tenant_id = $1::uuid AND sale_id = $2`,
      [tenantId, saleId],
    )) as { n: number }[];
    if (returned[0].n > 0) {
      // Part of this bill has already been credited back; voiding the whole thing
      // would restore that stock twice. The credit note is the record that stands.
      throw new HttpException(
        {
          code: 'SALE_HAS_RETURNS',
          message:
            'This bill already has a credit note against it and cannot be voided.',
        },
        HttpStatus.CONFLICT,
      );
    }

    const sale = rows[0];
    // Only a bill from this device's open drawer (owner's decision on #94, 2026-09-13).
    // The closing report is computed by `shift_id` and leaves voided bills out, so
    // voiding a bill from a closed shift would rewrite a drawer already counted, while
    // the drawer the money actually left shows no outflow. An older bill — another
    // shift, another device's, or an imported one with no shift — is undone by a credit
    // note, which lands in the current drawer. After `SALE_VOIDED`/`SALE_HAS_RETURNS`,
    // so a retry of a void that already committed still says so once the drawer has
    // closed; an `Idempotency-Key` replay never reaches this method at all. `FOR SHARE`
    // (see `requireOpenShiftIdFor`) so a close waits for a void in flight instead of
    // counting a bill this transaction is about to take out of it. Not audited like the
    // PIN denial: the caller has already proved the PIN, and this is a business rule.
    const openShiftId = await this.shifts.requireOpenShiftIdFor(
      manager,
      tenantId,
      actor.deviceId,
    );
    if (sale.shift_id !== openShiftId) {
      throw new HttpException(
        {
          code: 'SALE_NOT_IN_OPEN_SHIFT',
          message:
            'This bill is not from the open shift and cannot be voided. Issue a credit note instead.',
        },
        HttpStatus.CONFLICT,
      );
    }

    // 🔴 The mechanic's row lock is taken here, before the first product row.
    // `sales.service.ts` locks mechanic → products → doc_counters; a void that
    // reached the mechanic after the products would close the cycle and deadlock
    // against a concurrent bill for the same mechanic sharing one product. The
    // customer is deliberately left to `reverseLedger`, after the stock, because
    // that is where the sale path takes it too.
    await this.lockMechanic(manager, tenantId, sale.mechanic_id);

    await this.restoreStock(manager, tenantId, saleId);
    await this.reverseLedger(manager, tenantId, sale);
    // #32: stock put back and the ledger reversed — drop those cached pages after commit.
    this.cache.invalidateAfterCommit(tenantId, 'products');
    if (sale.customer_id !== null) this.cache.invalidateAfterCommit(tenantId, 'customers');
    if (sale.mechanic_id !== null) this.cache.invalidateAfterCommit(tenantId, 'mechanics');

    const voided = returning<{ voided_at: Date }>(
      await manager.query(
        `UPDATE sales SET voided = TRUE, voided_at = now()
          WHERE tenant_id = $1::uuid AND id = $2
      RETURNING voided_at`,
        [tenantId, saleId],
      ),
    );

    await this.audit.log(manager, {
      tenantId,
      userId: actor.userId,
      deviceId: actor.deviceId,
      action: 'sale.void',
      entity: 'sales',
      entityId: saleId,
      after: {
        voidedAt: voided[0].voided_at.toISOString(),
        reason: actor.reason,
      },
      ip: actor.ip,
    });

    return this.reads.byId(saleId);
  }

  /**
   * Takes the mechanic's row lock, in the sale path's lock order, so the ledger
   * reversal below can run after the stock without inverting it.
   *
   * No row is not an error: a mechanic deleted since the bill has nothing to lock
   * and nothing to reverse, and the void still stands.
   */
  private async lockMechanic(
    manager: EntityManager,
    tenantId: string,
    mechanicId: string | null,
  ): Promise<void> {
    if (mechanicId === null) return;
    await manager.query(
      `SELECT id FROM mechanics WHERE tenant_id = $1::uuid AND id = $2 FOR UPDATE`,
      [tenantId, mechanicId],
    );
  }

  /**
   * Undoes what `POST /sales` applied to the customer and the mechanic — the same two
   * statements as `applyCustomer`/`applyMechanic`, with every sign flipped.
   *
   * In **full, never in proportion**: a bill with a credit note against it was already
   * refused above (`SALE_HAS_RETURNS`), so there is no partial refund to share out the
   * way `POST /returns` has to. What the sale added is exactly what comes off.
   *
   * `GREATEST(0, …)` on every running total. `points` and `credit_balance` have a
   * `>= 0` CHECK that would at least raise if this were wrong, but `total_spend`,
   * `total_sales`, `total_discount` and `total_markup` have none — an unclamped
   * subtraction against a figure imported short from the old app goes negative in
   * silence.
   *
   * 🔴 `total_credit` is never written (decision #11): it is the JS app's legacy alias
   * of `total_discount`, the sale path deliberately does not write it, and a void that
   * did would move a column no sale ever moved.
   */
  private async reverseLedger(
    manager: EntityManager,
    tenantId: string,
    sale: LockedSale,
  ): Promise<void> {
    if (sale.customer_id !== null) {
      await manager.query(
        `UPDATE customers
            SET points = GREATEST(0, points - $3),
                total_spend = GREATEST(0, total_spend - $4),
                updated_at = now()
          WHERE tenant_id = $1::uuid AND id = $2`,
        [tenantId, sale.customer_id, sale.points_granted, sale.total],
      );
    }

    if (sale.mechanic_id === null) return;
    // A negative delta was a discount given to the mechanic, a positive one a markup.
    const delta =
      sale.mechanic_delta === null ? 0 : satangOf(sale.mechanic_delta);
    await manager.query(
      `UPDATE mechanics
          SET total_sales = GREATEST(0, total_sales - $3),
              total_discount = GREATEST(0, total_discount - $4),
              total_markup = GREATEST(0, total_markup - $5),
              credit_balance = GREATEST(0, credit_balance - $6),
              updated_at = now()
        WHERE tenant_id = $1::uuid AND id = $2`,
      [
        tenantId,
        sale.mechanic_id,
        sale.total,
        fromSatang(delta < 0 ? -delta : 0),
        fromSatang(delta > 0 ? delta : 0),
        // Only a bill that went on the tab put anything on it.
        sale.payment_method === MECHANIC_CREDIT ? sale.total : '0.00',
      ],
    );
  }

  /**
   * Puts every line back and writes the ledger rows that say so.
   *
   * The customer and mechanic ledger is handled by `reverseLedger`, which runs after
   * this — the sale path updates the customer after the products too, and the void
   * must not invert that order.
   */
  private async restoreStock(
    manager: EntityManager,
    tenantId: string,
    saleId: string,
  ): Promise<void> {
    const items = (await manager.query(
      `SELECT product_id, sum(qty)::int AS qty
         FROM sale_items
        WHERE tenant_id = $1::uuid AND sale_id = $2
        GROUP BY product_id
        ORDER BY product_id`,
      [tenantId, saleId],
    )) as { product_id: string; qty: number }[];

    for (const item of items) {
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
          [tenantId, item.product_id, item.qty],
        ),
      );
      // A soft-deleted product is restored like any other — the goods physically
      // exist again — and `POST /returns` does the same. Only a product with no row
      // at all is skipped, which a sold one cannot be: `movements` has a foreign key
      // to `products` with no cascade and every sale writes a row per product, so
      // deleting one that has ever sold can only ever set `deleted_at`.
      if (updated.length === 0) continue;

      await manager.query(
        `INSERT INTO movements (
           tenant_id, id, product_id, part_no, name, delta, type, stock_after, ref_id)
         VALUES ($1::uuid, $2, $3, $4, $5, $6, 'void', $7, $8)`,
        [
          tenantId,
          newId('mv'),
          item.product_id,
          updated[0].part_no,
          updated[0].name,
          item.qty,
          updated[0].stock,
          // The bare sale id. `uq_movements_ref` is unique on
          // `(tenant_id, type, ref_id, product_id)`, so a credit note against this
          // bill keeps its own slot under type 'return'.
          saleId,
        ],
      );
    }
  }
}

