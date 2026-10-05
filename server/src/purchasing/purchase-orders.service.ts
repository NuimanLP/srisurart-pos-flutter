import {
  BadRequestException,
  HttpException,
  HttpStatus,
  Injectable,
} from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { AuditService } from '../audit/audit.service.js';
import { newUuid } from '../common/ids.js';
import { fromSatang, satangOf } from '../common/money.js';
import { currentRequestContext } from '../common/request-context.js';
import { TenantService } from '../common/database/tenant.service.js';
import { returning } from '../common/sql.js';
import { DocNumberService } from '../documents/doc-number.service.js';
import { TenantCache } from '../infra/tenant-cache.service.js';
import {
  MOVEMENT_COLUMNS,
  movementOut,
  type MovementOut,
  type MovementRow,
} from '../sales/sales.service.js';
import type { PoCreate, PoStatus } from './purchase-orders.dto.js';
import { jsNumber, weightedAverageCostSatang } from './weighted-average.js';

export interface PoLine {
  lineNo: number;
  partNo: string;
  name: string;
  qty: number;
  cost: string;
}

export interface PurchaseOrder {
  id: string;
  poNo: string;
  supplier: string;
  status: PoStatus;
  createdAt: string;
  receivedAt: string | null;
  cancelledAt: string | null;
  items: PoLine[];
}

/** What `POST /purchase-orders/:id/receive` answers (02_API_SCREENS.md §3.3). */
export interface ReceiveResult {
  poId: string;
  status: 'received';
  receivedAt: string;
  updated: {
    productId: string;
    partNo: string;
    stockAfter: number;
    costAfter: string;
  }[];
  /** Part numbers with no live product — a list for the user, not an error. */
  unmatched: string[];
  /** The ledger rows this receipt wrote, so a client patches rather than re-derives them. */
  movements: MovementOut[];
}

interface PoRow {
  id: string;
  po_no: string;
  supplier: string;
  status: PoStatus;
  created_at: Date;
  received_at: Date | null;
  cancelled_at: Date | null;
}

interface PoLineRow {
  po_id: string;
  line_no: number;
  part_no: string;
  name: string;
  qty: number;
  cost: string;
}

const PO_COLUMNS = `id, po_no, supplier, status, created_at, received_at, cancelled_at`;

const INT4_MAX = 2_147_483_647;

/**
 * Purchase orders (#26), ported from `purchase_orders_repository.dart`.
 *
 * Lock order. Receiving locks the `purchase_orders` row, then every matched product
 * in id order — the same `ORDER BY id FOR UPDATE` the sale path uses. No other path
 * locks a purchase order, and none locks one after a product, so receiving cannot
 * close a cycle with `sale → shift → mechanic → products → doc_counters → customer`:
 * a sale and a receipt touching the same part simply queue on the product row.
 */
@Injectable()
export class PurchaseOrdersService {
  constructor(
    private readonly docNumbers: DocNumberService,
    private readonly cache: TenantCache,
    private readonly audit: AuditService,
    private readonly tenants: TenantService,
  ) {}

  /** Newest first, as `getPOs` orders them, each with its lines. */
  list(query: {
    status?: PoStatus;
    page: number;
    limit: number;
  }): Promise<{ items: PurchaseOrder[]; total: number }> {
    return this.tenants.runTx(() => this.listIn(query));
  }

  private async listIn(query: {
    status?: PoStatus;
    page: number;
    limit: number;
  }): Promise<{ items: PurchaseOrder[]; total: number }> {
    const { tenantId, manager } = currentRequestContext();
    const params: unknown[] = [tenantId];
    let where = 'tenant_id = $1::uuid';
    if (query.status) {
      params.push(query.status);
      where += ` AND status = $${params.length}`;
    }
    const totals = (await manager.query(
      `SELECT count(*)::int AS n FROM purchase_orders WHERE ${where}`,
      params,
    )) as { n: number }[];
    params.push(query.limit, (query.page - 1) * query.limit);
    const rows = (await manager.query(
      `SELECT ${PO_COLUMNS} FROM purchase_orders
        WHERE ${where}
        ORDER BY created_at DESC, id DESC
        LIMIT $${params.length - 1} OFFSET $${params.length}`,
      params,
    )) as PoRow[];
    const lines = await this.linesOf(
      manager,
      tenantId,
      rows.map((r) => r.id),
    );
    return {
      items: rows.map((r) => toPurchaseOrder(r, lines.get(r.id) ?? [])),
      total: totals[0]?.n ?? 0,
    };
  }

  get(id: string): Promise<PurchaseOrder> {
    return this.tenants.runTx(() => this.getIn(id));
  }

  private async getIn(id: string): Promise<PurchaseOrder> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT id, po_no, supplier, status, created_at, received_at, cancelled_at
         FROM purchase_orders
        WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, id],
    )) as PoRow[];
    if (rows.length === 0) {
      throw new HttpException(
        { code: 'PO_NOT_FOUND', message: `purchase order ${id} not found` },
        HttpStatus.NOT_FOUND,
      );
    }
    const lines = await this.linesOf(manager, tenantId, [id]);
    return toPurchaseOrder(rows[0], lines.get(id) ?? []);
  }

  /** `savePO`: server-minted id and PO number, status `open`. Touches no stock. */
  create(
    input: PoCreate,
    actor: { deviceId: string },
  ): Promise<PurchaseOrder> {
    return this.tenants.runTx(() => this.createIn(input, actor));
  }

  private async createIn(
    input: PoCreate,
    actor: { deviceId: string },
  ): Promise<PurchaseOrder> {
    const { tenantId, manager } = currentRequestContext();
    const poNo = await this.docNumbers.issue(manager, {
      tenantId,
      deviceId: actor.deviceId,
      docType: 'po',
    });
    const id = newUuid();
    const header = (await manager.query(
      `INSERT INTO purchase_orders (tenant_id, id, po_no, supplier)
            VALUES ($1::uuid, $2, $3, $4)
         RETURNING ${PO_COLUMNS}`,
      [tenantId, id, poNo, input.supplier],
    )) as PoRow[];
    const lines = (await manager.query(
      `INSERT INTO po_items (tenant_id, po_id, line_no, part_no, name, qty, cost)
            SELECT $1::uuid, $2::uuid, l.ord::int, l.part_no, l.name, l.qty, l.cost
              FROM unnest($3::text[], $4::text[], $5::int[], $6::numeric[])
                   WITH ORDINALITY AS l(part_no, name, qty, cost, ord)
         RETURNING po_id, line_no, part_no, name, qty, cost`,
      [
        tenantId,
        id,
        input.items.map((l) => l.partNo),
        input.items.map((l) => l.name),
        input.items.map((l) => l.qty),
        input.items.map((l) => l.cost),
      ],
    )) as PoLineRow[];
    lines.sort((a, b) => a.line_no - b.line_no);
    return toPurchaseOrder(header[0], lines);
  }

  /**
   * `receivePO`, with the status guard the Dart version lacks: the status is read
   * under `FOR UPDATE` inside this transaction, so two receipts racing with different
   * idempotency keys run one after the other and the second sees `received`.
   *
   * Lines are applied in line order, each against the stock and cost the previous
   * line left — exactly the Dart loop, so a PO naming one part on two lines lands on
   * the same average, rounded step by step. The product row and its ledger row are
   * then written once per product: `uq_movements_ref (tenant_id, type, ref_id,
   * product_id)` allows one `receive` row per product per PO, and that index is also
   * what makes a double receipt impossible at the database even if this guard broke.
   */
  receive(
    id: string,
    actor: { userId: string; deviceId?: string },
  ): Promise<ReceiveResult> {
    return this.tenants.runTx(() => this.receiveIn(id, actor));
  }

  private async receiveIn(
    id: string,
    actor: { userId: string; deviceId?: string },
  ): Promise<ReceiveResult> {
    const { tenantId, manager } = currentRequestContext();
    const po = await this.lockPo(manager, tenantId, id);
    if (po.status === 'received') throw poAlreadyReceived();
    if (po.status === 'cancelled') throw poCancelled();

    const lines = (
      await this.linesOf(manager, tenantId, [id])
    ).get(id) ?? [];

    // Matched by part number the way uniqueness is enforced (`uq_products_partno_ci`:
    // `lower(part_no)` among live products), and compared by Postgres, not by JS
    // `toLowerCase`, which disagrees with `lower()` outside ASCII. The join hands back
    // the line's own spelling, so the match needs no second case-fold here.
    const partNos = [...new Set(lines.map((l) => l.part_no))];
    const locked = (await manager.query(
      `SELECT p.id, p.part_no, p.name, p.cost, p.stock, l.key
         FROM products p
         JOIN unnest($2::text[]) AS l(key) ON lower(p.part_no) = lower(l.key)
        WHERE p.tenant_id = $1::uuid AND p.deleted_at IS NULL
        ORDER BY p.id
          FOR UPDATE OF p`,
      [tenantId, partNos],
    )) as {
      id: string;
      part_no: string;
      name: string;
      cost: string;
      stock: number;
      key: string;
    }[];

    interface Running {
      id: string;
      partNo: string;
      name: string;
      stockBefore: number;
      costBefore: number;
      stock: number;
      cost: number;
      delta: number;
    }
    const byKey = new Map<string, Running>();
    const byId = new Map<string, Running>();
    for (const row of locked) {
      let state = byId.get(row.id);
      if (!state) {
        const cost = satangOf(String(row.cost));
        state = {
          id: row.id,
          partNo: row.part_no,
          name: row.name,
          stockBefore: row.stock,
          costBefore: cost,
          stock: row.stock,
          cost,
          delta: 0,
        };
        byId.set(row.id, state);
      }
      byKey.set(row.key, state);
    }

    const unmatched: string[] = [];
    for (const line of lines) {
      const state = byKey.get(line.part_no);
      if (!state) {
        unmatched.push(line.part_no);
        continue;
      }
      if (state.stock + line.qty > INT4_MAX) {
        throw new BadRequestException(
          `receiving ${line.part_no} would take stock past ${INT4_MAX}`,
        );
      }
      state.cost = weightedAverageCostSatang(
        state.stock,
        state.cost,
        line.qty,
        satangOf(line.cost),
      );
      state.stock += line.qty;
      state.delta += line.qty;
    }

    const touched = [...byId.values()]
      .filter((s) => s.delta > 0)
      .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    const movements: MovementOut[] = [];
    for (const s of touched) {
      await manager.query(
        `UPDATE products SET stock = $3, cost = $4, updated_at = clock_timestamp()
          WHERE tenant_id = $1::uuid AND id = $2`,
        [tenantId, s.id, s.stock, fromSatang(s.cost)],
      );
      const rows = returning<MovementRow>(
        await manager.query(
          `INSERT INTO movements (
             tenant_id, id, product_id, part_no, name, delta, type, note, stock_after, ref_id)
           VALUES ($1::uuid, $2, $3, $4, $5, $6, 'receive', $7, $8, $9)
         RETURNING ${MOVEMENT_COLUMNS}`,
          [
            tenantId,
            newUuid(),
            s.id,
            s.partNo,
            s.name,
            s.delta,
            // Verbatim from `purchase_orders_repository.dart`.
            `PO ${po.po_no} จาก ${po.supplier} · ทุนใหม่ ฿${jsNumber(s.cost)}`,
            s.stock,
            id,
          ],
        ),
      );
      movements.push(movementOut(rows[0]));
    }

    const marked = returning<{ received_at: Date }>(
      await manager.query(
        `UPDATE purchase_orders SET status = 'received', received_at = now()
          WHERE tenant_id = $1::uuid AND id = $2
      RETURNING received_at`,
        [tenantId, id],
      ),
    );

    const updated = touched.map((s) => ({
      productId: s.id,
      partNo: s.partNo,
      stockAfter: s.stock,
      costAfter: fromSatang(s.cost),
    }));

    // #43: a receipt rewrites the average cost every profit report rests on, so who
    // did it — and what the products were before — is recorded with the change.
    await this.audit.log(manager, {
      tenantId,
      userId: actor.userId,
      deviceId: actor.deviceId,
      action: 'po.receive',
      entity: 'purchase_order',
      entityId: id,
      before: {
        products: touched.map((s) => ({
          id: s.id,
          stock: s.stockBefore,
          cost: fromSatang(s.costBefore),
        })),
      },
      after: { products: updated, unmatched },
    });

    if (touched.length > 0) {
      this.cache.invalidateAfterCommit(tenantId, 'products');
    }

    return {
      poId: id,
      status: 'received',
      receivedAt: marked[0].received_at.toISOString(),
      updated,
      unmatched,
      movements,
    };
  }

  /**
   * `cancelPO`. A received PO is refused: its stock and cost have already moved, and
   * a `cancelled` label on it would say they had not. Cancelling a cancelled PO
   * answers it unchanged.
   */
  cancel(id: string): Promise<PurchaseOrder> {
    return this.tenants.runTx(() => this.cancelIn(id));
  }

  private async cancelIn(id: string): Promise<PurchaseOrder> {
    const { tenantId, manager } = currentRequestContext();
    let po = await this.lockPo(manager, tenantId, id);
    if (po.status === 'received') throw poAlreadyReceived();
    if (po.status === 'open') {
      po = returning<PoRow>(
        await manager.query(
          `UPDATE purchase_orders SET status = 'cancelled', cancelled_at = now()
            WHERE tenant_id = $1::uuid AND id = $2
        RETURNING ${PO_COLUMNS}`,
          [tenantId, id],
        ),
      )[0];
    }
    const lines = await this.linesOf(manager, tenantId, [id]);
    return toPurchaseOrder(po, lines.get(id) ?? []);
  }

  /**
   * `deletePO` — only before receiving (02_API_SCREENS.md §3.3): a received PO is the
   * document the `receive` movements point at. `200` for an absent id, as the Dart
   * no-op and `DELETE /products/:id` answer.
   */
  delete(id: string): Promise<{ id: string; deleted: true }> {
    return this.tenants.runTx(() => this.deleteIn(id));
  }

  private async deleteIn(id: string): Promise<{ id: string; deleted: true }> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT status FROM purchase_orders
        WHERE tenant_id = $1::uuid AND id = $2
          FOR UPDATE`,
      [tenantId, id],
    )) as { status: PoStatus }[];
    if (rows[0]?.status === 'received') throw poAlreadyReceived();
    if (rows.length > 0) {
      // `po_items` goes with it: `ON DELETE CASCADE`.
      await manager.query(
        `DELETE FROM purchase_orders WHERE tenant_id = $1::uuid AND id = $2`,
        [tenantId, id],
      );
    }
    return { id, deleted: true };
  }

  private async lockPo(
    manager: EntityManager,
    tenantId: string,
    id: string,
  ): Promise<PoRow> {
    const rows = (await manager.query(
      `SELECT ${PO_COLUMNS} FROM purchase_orders
        WHERE tenant_id = $1::uuid AND id = $2
          FOR UPDATE`,
      [tenantId, id],
    )) as PoRow[];
    if (rows.length === 0) {
      throw new HttpException(
        { code: 'PO_NOT_FOUND', message: 'Purchase order not found' },
        HttpStatus.NOT_FOUND,
      );
    }
    return rows[0];
  }

  private async linesOf(
    manager: EntityManager,
    tenantId: string,
    poIds: string[],
  ): Promise<Map<string, PoLineRow[]>> {
    const out = new Map<string, PoLineRow[]>();
    if (poIds.length === 0) return out;
    const rows = (await manager.query(
      `SELECT po_id, line_no, part_no, name, qty, cost FROM po_items
        WHERE tenant_id = $1::uuid AND po_id = ANY($2::uuid[])
        ORDER BY po_id, line_no`,
      [tenantId, poIds],
    )) as PoLineRow[];
    for (const row of rows) {
      const list = out.get(row.po_id) ?? [];
      list.push(row);
      out.set(row.po_id, list);
    }
    return out;
  }
}

function poAlreadyReceived(): HttpException {
  // The Thai draft the project owner accepted (02_API_SCREENS.md §8.1).
  return new HttpException(
    { code: 'PO_ALREADY_RECEIVED', message: 'ใบสั่งซื้อนี้รับของแล้ว' },
    HttpStatus.CONFLICT,
  );
}

function poCancelled(): HttpException {
  // No Thai wording exists for this one; English until the shop writes it (§8.1).
  return new HttpException(
    {
      code: 'PO_CANCELLED',
      message: 'This purchase order is cancelled and cannot be received.',
    },
    HttpStatus.CONFLICT,
  );
}

function toPurchaseOrder(row: PoRow, lines: PoLineRow[]): PurchaseOrder {
  return {
    id: row.id,
    poNo: row.po_no,
    supplier: row.supplier,
    status: row.status,
    createdAt: row.created_at.toISOString(),
    receivedAt: row.received_at?.toISOString() ?? null,
    cancelledAt: row.cancelled_at?.toISOString() ?? null,
    items: lines.map((l) => ({
      lineNo: l.line_no,
      partNo: l.part_no,
      name: l.name,
      qty: l.qty,
      cost: fromSatang(satangOf(String(l.cost))),
    })),
  };
}
