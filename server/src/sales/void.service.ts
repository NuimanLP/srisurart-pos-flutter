import { HttpException, HttpStatus, Inject, Injectable } from '@nestjs/common';
import { DataSource, type EntityManager } from 'typeorm';
import { AuditService } from '../audit/audit.service.js';
import { AUDIT_DATA_SOURCE } from '../infra/db.module.js';
import { newId } from '../common/ids.js';
import { fromSatang, satangOf } from '../common/money.js';
import { verifyPassword } from '../common/password.js';
import { currentRequestContext } from '../common/request-context.js';
import { returning } from '../common/sql.js';
import {
  SaleReadsService,
  saleNotFound,
  type SaleWithItems,
} from './sale-reads.service.js';
import { MECHANIC_CREDIT } from './sales.service.js';

/** The bill under its own row lock — everything the void has to undo. */
interface LockedSale {
  voided: boolean;
  customer_id: string | null;
  mechanic_id: string | null;
  mechanic_delta: string | null;
  payment_method: string;
  total: string;
  points_granted: number;
}

/** Who is voiding, from the token — plus the PIN they typed, which is not. */
export interface VoidActor {
  userId: string;
  role: string | undefined;
  deviceId: string;
  pin: string;
  ip?: string;
}

/**
 * Only these may void a bill: the counter staff must fetch someone (§4.2 says
 * `manager`; `owner` is included because nothing in this shop's role model puts an
 * owner below a manager — recorded in §4.2 rather than left implicit here).
 */
const ROLES_THAT_MAY_VOID = new Set(['manager', 'owner']);

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
    @Inject(AUDIT_DATA_SOURCE) private readonly auditDs: DataSource,
  ) {}

  async void(saleId: string, actor: VoidActor): Promise<SaleWithItems> {
    const { tenantId, manager } = currentRequestContext();

    await this.assertManagerPin(manager, tenantId, actor, saleId);

    // Locked, because two clerks voiding the same bill would otherwise both restore
    // its stock and the shop would gain inventory it never had. The ledger columns
    // ride along on that lock: the reversal has to subtract the figures this bill
    // actually wrote, and it reads them under the same lock that makes it exclusive.
    const rows = (await manager.query(
      `SELECT voided, customer_id, mechanic_id, mechanic_delta,
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
    // 🔴 The mechanic's row lock is taken here, before the first product row.
    // `sales.service.ts` locks mechanic → products → doc_counters; a void that
    // reached the mechanic after the products would close the cycle and deadlock
    // against a concurrent bill for the same mechanic sharing one product. The
    // customer is deliberately left to `reverseLedger`, after the stock, because
    // that is where the sale path takes it too.
    await this.lockMechanic(manager, tenantId, sale.mechanic_id);

    await this.restoreStock(manager, tenantId, saleId);
    await this.reverseLedger(manager, tenantId, sale);

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
      after: { voidedAt: voided[0].voided_at.toISOString() },
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

  /**
   * `manager` (or `owner`, who outranks one) plus the PIN. The role comes from the
   * token and the PIN from the body: a stolen unlocked terminal is the threat here,
   * so the second factor has to be something the thief has to know, not something the
   * session already carries.
   */
  private async assertManagerPin(
    manager: EntityManager,
    tenantId: string,
    actor: VoidActor,
    saleId: string,
  ): Promise<void> {
    const deny = async (reason: string): Promise<HttpException> => {
      await this.auditDenial(tenantId, actor, saleId, reason);
      return forbidden();
    };

    if (!actor.role || !ROLES_THAT_MAY_VOID.has(actor.role))
      throw await deny('role');

    const rows = (await manager.query(
      `SELECT pin_hash FROM users
        WHERE tenant_id = $1::uuid AND id = $2::uuid AND is_active`,
      [tenantId, actor.userId],
    )) as { pin_hash: string | null }[];

    const pinHash = rows[0]?.pin_hash;
    if (!pinHash) throw await deny('no-pin');
    if (!actor.pin || !(await verifyPassword(actor.pin, pinHash)))
      throw await deny('pin');
  }

  /**
   * Records a refused void.
   *
   * On its **own** connection, because the 403 rolls the request transaction back and
   * an audit row written on it would vanish with the attempt it was recording. This
   * is a four-digit PIN with no per-user rate limit yet (#44); brute-forcing it must
   * not be invisible.
   *
   * 🔴 That connection comes from `AUDIT_DATA_SOURCE`, **not** from the request pool.
   * Taken from the request pool this is a request holding one connection while queuing
   * for a second: measured at `DB_POOL_SIZE=2`, four concurrent denials answered
   * `403,403,500,500` in 5112 ms, the two 500s being unrelated requests whose middleware
   * timed out waiting for a connection these were sitting on. The first denial branch is
   * the role check, so any authenticated cashier can reach it without knowing a PIN.
   *
   * Failing to log must not turn a 403 into a 500, so the write is best-effort — and the
   * connection is only taken on the refusal path, never on the one every request follows.
   */
  private async auditDenial(
    tenantId: string,
    actor: VoidActor,
    saleId: string,
    reason: string,
  ): Promise<void> {
    const qr = this.auditDs.createQueryRunner();
    try {
      await qr.connect();
      await qr.startTransaction();
      // Its own `SET LOCAL`: RLS is forced, and a connection that has not named a
      // tenant cannot insert a tenant-scoped row at all.
      await qr.query(`SELECT set_config('app.tenant_id', $1, true)`, [tenantId]);
      await qr.query(
        `INSERT INTO audit_log (tenant_id, user_id, device_id, action, entity, entity_id, after)
              VALUES ($1::uuid, $2::uuid, $3, 'sale.void.denied', 'sales', $4, $5::jsonb)`,
        [tenantId, actor.userId, actor.deviceId, saleId, JSON.stringify({ reason })],
      );
      await qr.commitTransaction();
    } catch {
      // The refusal itself is what matters; the log is best-effort. Failing to write
      // it must not turn a 403 into a 500.
      if (qr.isTransactionActive) await qr.rollbackTransaction().catch(() => {});
    } finally {
      if (!qr.isReleased) await qr.release().catch(() => {});
    }
  }
}

function forbidden(): HttpException {
  return new HttpException(
    { code: 'FORBIDDEN', message: 'Manager PIN required' },
    HttpStatus.FORBIDDEN,
  );
}
