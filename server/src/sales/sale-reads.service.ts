import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { currentRequestContext } from '../common/request-context.js';

/** A bill header as the API hands it back. Money is the wire format, `"1234.50"`. */
export interface SaleHeader {
  id: string;
  receiptNo: string;
  subtotal: string;
  discount: string;
  total: string;
  paymentMethod: string;
  customerId: string | null;
  customerName: string | null;
  mechanicId: string | null;
  mechanicName: string | null;
  mechanicDelta: string | null;
  pointsGranted: number;
  date: string;
  voided: boolean;
  voidedAt: string | null;
  shiftId: string | null;
}

export interface SaleLineOut {
  lineNo: number;
  productId: string;
  partNo: string | null;
  name: string;
  nameTH: string | null;
  qty: number;
  price: string;
  costAtSale: string | null;
}

export interface SaleWithItems extends SaleHeader {
  items: SaleLineOut[];
}

export interface SaleListQuery {
  search?: string;
  receiptNo?: string;
  from?: string;
  to?: string;
  page: number;
  limit: number;
}

interface SaleRow {
  id: string;
  receipt_no: string;
  subtotal: string;
  discount: string;
  total: string;
  payment_method: string;
  customer_id: string | null;
  customer_name: string | null;
  mechanic_id: string | null;
  mechanic_name: string | null;
  mechanic_delta: string | null;
  points_granted: number;
  date: Date;
  voided: boolean;
  voided_at: Date | null;
  shift_id: string | null;
}

const SALE_COLUMNS = `id, receipt_no, subtotal, discount, total, payment_method,
                      customer_id, customer_name, mechanic_id, mechanic_name,
                      mechanic_delta, points_granted, date, voided, voided_at, shift_id`;

/**
 * The read side of selling. Small, but the Returns screen cannot work without
 * `refunded-qty` and nothing else can be checked without list access.
 */
@Injectable()
export class SaleReadsService {
  /** A page of bills, newest first. Never the whole table — this one grows forever. */
  async list(
    query: SaleListQuery,
  ): Promise<{ items: SaleWithItems[]; total: number }> {
    const { tenantId, manager } = currentRequestContext();
    const where: string[] = ['tenant_id = $1::uuid'];
    const params: unknown[] = [tenantId];

    if (query.receiptNo) {
      // The barcode case of this screen: what is printed on the paper a customer
      // brings back is one exact number, and a LIKE would return several bills.
      params.push(query.receiptNo);
      where.push(`receipt_no = $${params.length}`);
    }
    if (query.search) {
      params.push(`%${escapeLike(query.search)}%`);
      where.push(
        `(receipt_no ILIKE $${params.length} ESCAPE '\\' OR customer_name ILIKE $${params.length} ESCAPE '\\')`,
      );
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
      `SELECT count(*)::int AS n FROM sales WHERE ${clause}`,
      params,
    )) as { n: number }[];

    params.push(query.limit, (query.page - 1) * query.limit);
    const rows = (await manager.query(
      `SELECT ${SALE_COLUMNS} FROM sales
        WHERE ${clause}
        ORDER BY date DESC, id DESC
        LIMIT $${params.length - 1} OFFSET $${params.length}`,
      params,
    )) as SaleRow[];

    return {
      items: await this.attachItems(manager, tenantId, rows),
      total: totals[0].n,
    };
  }

  /** One bill with its lines, or `404 SALE_NOT_FOUND`. */
  async byId(id: string): Promise<SaleWithItems> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT ${SALE_COLUMNS} FROM sales WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, id],
    )) as SaleRow[];
    if (rows.length === 0) throw saleNotFound();
    return (await this.attachItems(manager, tenantId, rows))[0];
  }

  /**
   * How much of each product on this bill has already been credited back
   * (`getRefundedQty` in `sales_repository.dart`). This is what makes the over-refund
   * guard visible to staff *before* they submit, rather than as a rejection after.
   */
  async refundedQty(saleId: string): Promise<Record<string, number>> {
    const { tenantId, manager } = currentRequestContext();
    const exists = (await manager.query(
      `SELECT 1 FROM sales WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, saleId],
    )) as unknown[];
    if (exists.length === 0) throw saleNotFound();

    const rows = (await manager.query(
      `SELECT ri.product_id, sum(ri.qty)::int AS qty
         FROM return_items ri
         JOIN returns r ON r.tenant_id = ri.tenant_id AND r.id = ri.return_id
        WHERE ri.tenant_id = $1::uuid AND r.sale_id = $2
        GROUP BY ri.product_id`,
      [tenantId, saleId],
    )) as { product_id: string; qty: number }[];

    return Object.fromEntries(rows.map((r) => [r.product_id, r.qty]));
  }

  /** Loads the lines for every bill in one query, keeping the order they came in. */
  private async attachItems(
    manager: EntityManager,
    tenantId: string,
    rows: SaleRow[],
  ): Promise<SaleWithItems[]> {
    if (rows.length === 0) return [];
    const items = (await manager.query(
      `SELECT sale_id, line_no, product_id, part_no, name, name_th, qty, price, cost_at_sale
         FROM sale_items
        WHERE tenant_id = $1::uuid AND sale_id = ANY($2::text[])
        ORDER BY sale_id, line_no`,
      [tenantId, rows.map((r) => r.id)],
    )) as ({ sale_id: string } & Record<string, unknown>)[];

    const bySale = new Map<string, SaleLineOut[]>();
    for (const item of items) {
      const list = bySale.get(item.sale_id) ?? [];
      list.push({
        lineNo: item.line_no as number,
        productId: item.product_id as string,
        partNo: (item.part_no as string) ?? null,
        name: item.name as string,
        nameTH: (item.name_th as string) ?? null,
        qty: item.qty as number,
        price: item.price as string,
        costAtSale: (item.cost_at_sale as string) ?? null,
      });
      bySale.set(item.sale_id, list);
    }

    return rows.map((row) => ({
      ...toHeader(row),
      items: bySale.get(row.id) ?? [],
    }));
  }
}

export function saleNotFound(): HttpException {
  return new HttpException(
    { code: 'SALE_NOT_FOUND', message: 'Sale not found' },
    HttpStatus.NOT_FOUND,
  );
}

export function toHeader(row: SaleRow): SaleHeader {
  return {
    id: row.id,
    receiptNo: row.receipt_no,
    subtotal: row.subtotal,
    discount: row.discount,
    total: row.total,
    paymentMethod: row.payment_method,
    customerId: row.customer_id,
    customerName: row.customer_name,
    mechanicId: row.mechanic_id,
    mechanicName: row.mechanic_name,
    mechanicDelta: row.mechanic_delta,
    pointsGranted: row.points_granted,
    date: row.date.toISOString(),
    voided: row.voided,
    voidedAt: row.voided_at ? row.voided_at.toISOString() : null,
    shiftId: row.shift_id,
  };
}

/** `%` and `_` in what staff typed are literal characters, not wildcards. */
function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (c) => `\\${c}`);
}
