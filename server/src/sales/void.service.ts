import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import { DataSource, type EntityManager } from 'typeorm';
import { AuditService } from '../audit/audit.service.js';
import { newId } from '../common/ids.js';
import { verifyPassword } from '../common/password.js';
import { currentRequestContext } from '../common/request-context.js';
import { returning } from '../common/sql.js';
import {
  SaleReadsService,
  saleNotFound,
  type SaleWithItems,
} from './sale-reads.service.js';

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

/** Keeps a void's ledger row out of the slot a credit note wants (`uq_movements_ref`). */
export const VOID_REF_PREFIX = 'void:';

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
    private readonly ds: DataSource,
  ) {}

  async void(saleId: string, actor: VoidActor): Promise<SaleWithItems> {
    const { tenantId, manager } = currentRequestContext();

    await this.assertManagerPin(manager, tenantId, actor, saleId);

    // Locked, because two clerks voiding the same bill would otherwise both restore
    // its stock and the shop would gain inventory it never had.
    const rows = (await manager.query(
      `SELECT id, voided FROM sales WHERE tenant_id = $1::uuid AND id = $2 FOR UPDATE`,
      [tenantId, saleId],
    )) as { id: string; voided: boolean }[];
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

    await this.restoreStock(manager, tenantId, saleId);

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
   * Puts every line back and writes the ledger rows that say so.
   *
   * 🔴 **The customer and mechanic ledger is deliberately untouched.** #20 does not
   * apply those effects yet — they are #21, blocked on the #11 decision — so there is
   * nothing on a bill written by this server to reverse, and reversing anyway would
   * drive points and credit balances negative. When #21 lands it must extend this
   * method, and #11 has to be settled by a human before either can be right.
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
      // A product deleted since the sale has no row to credit back. The void still
      // stands — the money is what matters — but the stock cannot be restored to
      // something that is gone, and inventing the row would be worse.
      if (updated.length === 0) continue;

      await manager.query(
        `INSERT INTO movements (
           tenant_id, id, product_id, part_no, name, delta, type, stock_after, ref_id)
         VALUES ($1::uuid, $2, $3, $4, $5, $6, 'return', $7, $8)`,
        [
          tenantId,
          newId('mv'),
          item.product_id,
          updated[0].part_no,
          updated[0].name,
          item.qty,
          updated[0].stock,
          // `void:` prefix, not the bare sale id. `uq_movements_ref` is unique on
          // `(tenant_id, type, ref_id, product_id)`, and a credit note against this
          // bill would naturally use the sale id as its own ref — the two would
          // collide as a 500. `movements.type` has no 'void' value to use instead
          // without a migration, which belongs to the schema lane.
          `${VOID_REF_PREFIX}${saleId}`,
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
   * not be invisible. Failing to log must not turn a 403 into a 500, so the write is
   * best-effort — the connection is only taken on the refusal path, never on the one
   * every request follows.
   */
  private async auditDenial(
    tenantId: string,
    actor: VoidActor,
    saleId: string,
    reason: string,
  ): Promise<void> {
    const qr = this.ds.createQueryRunner();
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
