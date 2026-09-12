import { Injectable } from '@nestjs/common';
import { currentRequestContext } from '../common/request-context.js';
import type { ReportDateRange } from './reports.dto.js';

export interface ReportSummary {
  totalRevenue: string;
  totalTransactions: number;
  avgTicket: string;
  totalRefunds: string;
  netRevenue: string;
  totalItems: number;
}

export interface ProductSales {
  productId: string;
  partNo: string;
  name: string;
  qty: number;
  revenue: string;
}

export interface CategorySales {
  category: string;
  qty: number;
  revenue: string;
}

export interface StockValue {
  productCount: number;
  totalUnits: number;
  totalValue: string;
}

export interface LowStockProduct {
  id: string;
  partNo: string;
  name: string;
  nameTH: string;
  category: string;
  brand: string;
  stock: number;
  minStock: number;
}

interface SummaryRow {
  total_revenue: string;
  total_transactions: number;
  average_ticket: string;
  total_refunds: string;
  net_revenue: string;
  total_items: number;
}

interface ProductSalesRow {
  product_id: string;
  part_no: string;
  name: string;
  quantity: number;
  revenue: string;
}

interface CategorySalesRow {
  category: string;
  quantity: number;
  revenue: string;
}

interface StockValueRow {
  product_count: number;
  total_units: number;
  total_value: string;
}

interface LowStockRow {
  id: string;
  part_no: string;
  name: string;
  name_th: string;
  category: string;
  brand: string;
  stock: number;
  min_stock: number;
}

/**
 * The local-time bounds shared by every dated report. The `tenants` row has no
 * RLS, while every business-table CTE below still carries both RLS and an
 * explicit `tenant_id = $1` predicate.
 */
const BOUNDS = `bounds AS (
  SELECT CASE WHEN $2::text IS NULL THEN '-infinity'::timestamptz
              ELSE $2::date::timestamp AT TIME ZONE timezone END AS from_at,
         CASE WHEN $3::text IS NULL THEN 'infinity'::timestamptz
              ELSE $3::date::timestamp AT TIME ZONE timezone END AS to_at
    FROM tenants
   WHERE id = $1::uuid
)`;

/**
 * Positive sale lines and negative credit-note lines. Returns are filtered on
 * their own date, matching the client: a part sold last month and returned today
 * reduces today's quantity and revenue.
 */
const ITEM_EVENTS = `
sale_events AS (
  SELECT si.product_id, si.part_no, si.name, si.qty,
         (si.qty * si.price)::numeric AS revenue
    FROM bounds b
    JOIN sales s
      ON s.tenant_id = $1::uuid
     AND s.date >= b.from_at AND s.date < b.to_at
    JOIN sale_items si
      ON si.tenant_id = $1::uuid
     AND si.tenant_id = s.tenant_id AND si.sale_id = s.id
),
return_events AS (
  SELECT ri.product_id, sl.part_no, COALESCE(sl.name, ri.name) AS name,
         -ri.qty AS qty, -(ri.qty * ri.price)::numeric AS revenue
    FROM bounds b
    JOIN returns r
      ON r.tenant_id = $1::uuid
     AND r.date >= b.from_at AND r.date < b.to_at
    JOIN return_items ri
      ON ri.tenant_id = $1::uuid
     AND ri.tenant_id = r.tenant_id AND ri.return_id = r.id
    LEFT JOIN LATERAL (
      SELECT si.part_no, si.name
        FROM sale_items si
       WHERE si.tenant_id = $1::uuid
         AND si.tenant_id = r.tenant_id AND si.sale_id = r.sale_id
         AND si.product_id = ri.product_id AND si.price = ri.price
       ORDER BY si.line_no
       LIMIT 1
    ) sl ON TRUE
),
item_events AS (
  SELECT product_id, part_no, name, qty, revenue FROM sale_events
  UNION ALL
  SELECT product_id, part_no, name, qty, revenue FROM return_events
)`;

@Injectable()
export class ReportsService {
  async summary(range: ReportDateRange): Promise<ReportSummary> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `WITH ${BOUNDS},
       sale_totals AS (
         SELECT COALESCE(sum(s.total), 0)::numeric(20,2) AS revenue,
                count(s.id)::int AS transactions
           FROM bounds b
           LEFT JOIN sales s
             ON s.tenant_id = $1::uuid
            AND s.date >= b.from_at AND s.date < b.to_at
       ),
       sale_quantity AS (
         SELECT COALESCE(sum(si.qty), 0)::int AS quantity
           FROM bounds b
           JOIN sales s
             ON s.tenant_id = $1::uuid
            AND s.date >= b.from_at AND s.date < b.to_at
           JOIN sale_items si
             ON si.tenant_id = $1::uuid
            AND si.tenant_id = s.tenant_id AND si.sale_id = s.id
       ),
       return_totals AS (
         SELECT COALESCE(sum(r.refund_total), 0)::numeric(20,2) AS refunds
           FROM bounds b
           LEFT JOIN returns r
             ON r.tenant_id = $1::uuid
            AND r.date >= b.from_at AND r.date < b.to_at
       ),
       return_quantity AS (
         SELECT COALESCE(sum(ri.qty), 0)::int AS quantity
           FROM bounds b
           JOIN returns r
             ON r.tenant_id = $1::uuid
            AND r.date >= b.from_at AND r.date < b.to_at
           JOIN return_items ri
             ON ri.tenant_id = $1::uuid
            AND ri.tenant_id = r.tenant_id AND ri.return_id = r.id
       )
       SELECT s.revenue AS total_revenue,
              s.transactions AS total_transactions,
              CASE WHEN s.transactions = 0 THEN 0
                   ELSE round(s.revenue / s.transactions, 0)
               END::numeric(20,2) AS average_ticket,
              r.refunds AS total_refunds,
              (s.revenue - r.refunds)::numeric(20,2) AS net_revenue,
              (sq.quantity - rq.quantity)::int AS total_items
         FROM sale_totals s CROSS JOIN sale_quantity sq
         CROSS JOIN return_totals r CROSS JOIN return_quantity rq`,
      rangeParams(tenantId, range),
    )) as SummaryRow[];
    const row = rows[0];
    return {
      totalRevenue: row.total_revenue,
      totalTransactions: row.total_transactions,
      avgTicket: row.average_ticket,
      totalRefunds: row.total_refunds,
      netRevenue: row.net_revenue,
      totalItems: row.total_items,
    };
  }

  async topProducts(
    range: ReportDateRange,
    limit: number,
  ): Promise<ProductSales[]> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `WITH ${BOUNDS}, ${ITEM_EVENTS}
       SELECT e.product_id,
              COALESCE(max(e.part_no), max(p.part_no), e.product_id) AS part_no,
              COALESCE(max(e.name), max(p.name), e.product_id) AS name,
              sum(e.qty)::int AS quantity,
              sum(e.revenue)::numeric(20,2) AS revenue
         FROM item_events e
         LEFT JOIN products p
           ON p.tenant_id = $1::uuid AND p.id = e.product_id
        GROUP BY e.product_id
       HAVING sum(e.qty) <> 0 OR sum(e.revenue) <> 0
        ORDER BY quantity DESC, revenue DESC, e.product_id
        LIMIT $4`,
      [...rangeParams(tenantId, range), limit],
    )) as ProductSalesRow[];
    return rows.map(toProductSales);
  }

  async byCategory(range: ReportDateRange): Promise<CategorySales[]> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `WITH ${BOUNDS}, ${ITEM_EVENTS}
       SELECT COALESCE(NULLIF(p.category, ''), 'อื่นๆ') AS category,
              sum(e.qty)::int AS quantity,
              sum(e.revenue)::numeric(20,2) AS revenue
         FROM item_events e
         LEFT JOIN products p
           ON p.tenant_id = $1::uuid AND p.id = e.product_id
          AND p.deleted_at IS NULL
        GROUP BY COALESCE(NULLIF(p.category, ''), 'อื่นๆ')
       HAVING sum(e.qty) <> 0 OR sum(e.revenue) <> 0
        ORDER BY revenue DESC, category`,
      rangeParams(tenantId, range),
    )) as CategorySalesRow[];
    return rows.map((row) => ({
      category: row.category,
      qty: row.quantity,
      revenue: row.revenue,
    }));
  }

  async stockValue(): Promise<StockValue> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT count(*)::int AS product_count,
              COALESCE(sum(stock), 0)::int AS total_units,
              COALESCE(sum(stock * cost), 0)::numeric(20,2) AS total_value
         FROM products
        WHERE tenant_id = $1::uuid AND deleted_at IS NULL`,
      [tenantId],
    )) as StockValueRow[];
    return {
      productCount: rows[0].product_count,
      totalUnits: rows[0].total_units,
      totalValue: rows[0].total_value,
    };
  }

  async lowStock(
    page: number,
    limit: number,
  ): Promise<{ items: LowStockProduct[]; total: number }> {
    const { tenantId, manager } = currentRequestContext();
    const totals = (await manager.query(
      `SELECT count(*)::int AS n
         FROM products
        WHERE tenant_id = $1::uuid AND deleted_at IS NULL AND stock <= min_stock`,
      [tenantId],
    )) as { n: number }[];
    const rows = (await manager.query(
      `SELECT id, part_no, name, name_th, category, brand, stock, min_stock
         FROM products
        WHERE tenant_id = $1::uuid AND deleted_at IS NULL AND stock <= min_stock
        ORDER BY (stock = 0) DESC, stock, part_no, id
        LIMIT $2 OFFSET $3`,
      [tenantId, limit, (page - 1) * limit],
    )) as LowStockRow[];
    return {
      items: rows.map((row) => ({
        id: row.id,
        partNo: row.part_no,
        name: row.name,
        nameTH: row.name_th,
        category: row.category,
        brand: row.brand,
        stock: row.stock,
        minStock: row.min_stock,
      })),
      total: totals[0].n,
    };
  }

  async productSales(
    productId: string,
    range: ReportDateRange,
  ): Promise<ProductSales> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `WITH ${BOUNDS}, ${ITEM_EVENTS}
       SELECT $4::text AS product_id,
              COALESCE(max(e.part_no), max(p.part_no), $4::text) AS part_no,
              COALESCE(max(e.name), max(p.name), $4::text) AS name,
              COALESCE(sum(e.qty), 0)::int AS quantity,
              COALESCE(sum(e.revenue), 0)::numeric(20,2) AS revenue
         FROM (SELECT 1) seed
         LEFT JOIN item_events e ON e.product_id = $4
         LEFT JOIN products p
           ON p.tenant_id = $1::uuid AND p.id = $4`,
      [...rangeParams(tenantId, range), productId],
    )) as ProductSalesRow[];
    return toProductSales(rows[0]);
  }
}

function rangeParams(tenantId: string, range: ReportDateRange): unknown[] {
  return [tenantId, range.from, range.toExclusive];
}

function toProductSales(row: ProductSalesRow): ProductSales {
  return {
    productId: row.product_id,
    partNo: row.part_no,
    name: row.name,
    qty: row.quantity,
    revenue: row.revenue,
  };
}
