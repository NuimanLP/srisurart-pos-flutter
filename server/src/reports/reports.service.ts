import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import { currentRequestContext } from '../common/request-context.js';
import { TenantService } from '../common/database/tenant.service.js';
import type { ReportDateRange } from './reports.dto.js';

export interface ReportSummary {
  totalRevenue: string;
  totalTransactions: number;
  avgTicket: string;
  totalRefunds: string;
  netRevenue: string;
  totalItems: number;
  /** Same formula and flags as `ClosingReport`, over the same bills as `totalRevenue`. */
  grossProfit: string;
  estimatedCostRows: number;
  unknownCostRows: number;
}

/** `GET /reports/closing?shiftId=` — one drawer, keyed by `shift_id` only. */
export interface ClosingReport {
  shiftId: string;
  dateStr: string;
  deviceId: string | null;
  openedAt: string;
  closedAt: string | null;
  startingCash: string;
  cashSales: string;
  cashCreditPayments: string;
  cashRefunds: string;
  drawerIn: string;
  drawerOut: string;
  expectedCash: string;
  /** Null until the shift is closed: there is no count to compare against. */
  physicalCash: string | null;
  variance: string | null;
  grossProfit: string;
  /**
   * How much of `grossProfit` is a guess (ADR-0008). A line whose `cost_at_sale` is
   * null — an imported bill, never backfilled — is costed at today's `products.cost`
   * and counted here; a null line whose product row is gone too is costed at 0 and
   * counted in `unknownCostRows`, so a 100% margin never reads as fact.
   */
  estimatedCostRows: number;
  unknownCostRows: number;
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
  gross_profit: string;
  estimated_cost_rows: number;
  unknown_cost_rows: number;
}

interface ClosingRow {
  id: string;
  date_str: string;
  device_id: string | null;
  opened_at: Date;
  closed_at: Date | null;
  starting_cash: string;
  cash_sales: string;
  cash_credit_payments: string;
  cash_refunds: string;
  drawer_in: string;
  drawer_out: string;
  expected_cash: string;
  physical_cash: string | null;
  variance: string | null;
  gross_profit: string;
  estimated_cost_rows: number;
  unknown_cost_rows: number;
}

/** The one cash method string: `sales.dto.ts`, `returns.dto.ts` and `credit-payments.dto.ts` all accept it. */
const CASH = 'เงินสด';

/**
 * A bill that still counts as money taken and goods sold.
 *
 * A **manual** void (`POST /sales/:id/void`) undoes the bill outright — stock back,
 * ledger reversed, no credit note — so it is excluded. An **auto**-void is what a
 * return of the last unit does (`returns.service.ts`); that bill stays counted and
 * its credit notes subtract, or the refund would be taken off twice. The two are
 * exactly separable because a manual void is refused once any return exists
 * (`SALE_HAS_RETURNS`).
 */
const COUNTED_SALE = `NOT (s.voided AND NOT EXISTS (
  SELECT 1 FROM returns rv
   WHERE rv.tenant_id = $1::uuid AND rv.tenant_id = s.tenant_id AND rv.sale_id = s.id))`;

/**
 * Gross profit over the counted bills and the credit notes chosen by two constant SQL
 * predicates (on `sales s` and `returns r`; never request input) — one shift for the
 * closing report, a date range for the summary, which also takes its revenue, refunds
 * and item totals from `gp_sales`, `gp_returns` and `gp_lines` so every figure in one
 * response comes from one set of bills:
 *
 *   (Σ sales.total − Σ returns.refund_total) ÷ (1 + tax_rate/100)
 *   − Σ sale-line qty × cost + Σ return-line qty × cost
 *
 * Revenue is ex-VAT and after the bill discount. Credit notes net out — with
 * `return_items.cost_at_sale`, which #22 carries from the bill for exactly this
 * (ADR-0008, "การรับคืน"). The Dart closing report and `products_screen.dart`'s
 * "ยอดวันนี้"/"กำไรเดือนนี้" apply this same rule and formula
 * (`closing_report.dart`'s `NetSales`/`computeGrossProfit`/`countedSales`); the
 * client has no return-line cost column, so it takes the original sale line's
 * `costAtSale` for a returned line. Keep the two in step. Cost is `cost_at_sale`, and today's
 * `products.cost` only for null rows. `settings.tax_rate` defaults to 7 like the
 * column and the client.
 */
const grossProfitCtes = (saleScope: string, returnScope: string): string => `
gp_sales AS (
  SELECT s.tenant_id, s.id, s.total FROM sales s
   WHERE s.tenant_id = $1::uuid AND ${saleScope} AND ${COUNTED_SALE}
),
gp_returns AS (
  SELECT r.tenant_id, r.id, r.refund_total FROM returns r
   WHERE r.tenant_id = $1::uuid AND ${returnScope}
),
gp_lines AS (
  SELECT si.qty, si.cost_at_sale, p.cost AS current_cost
    FROM gp_sales s
    JOIN sale_items si
      ON si.tenant_id = $1::uuid AND si.tenant_id = s.tenant_id AND si.sale_id = s.id
    LEFT JOIN products p ON p.tenant_id = $1::uuid AND p.id = si.product_id
  UNION ALL
  SELECT -ri.qty, ri.cost_at_sale, p.cost
    FROM gp_returns r
    JOIN return_items ri
      ON ri.tenant_id = $1::uuid AND ri.tenant_id = r.tenant_id AND ri.return_id = r.id
    LEFT JOIN products p ON p.tenant_id = $1::uuid AND p.id = ri.product_id
),
gross_profit AS (
  SELECT round(
           (COALESCE((SELECT sum(total) FROM gp_sales), 0)
            - COALESCE((SELECT sum(refund_total) FROM gp_returns), 0))
           / (1 + COALESCE((SELECT tax_rate FROM settings WHERE tenant_id = $1::uuid), 7) / 100)
           - COALESCE((SELECT sum(qty * COALESCE(cost_at_sale, current_cost, 0)) FROM gp_lines), 0),
         2)::numeric(20,2) AS gross_profit,
         (SELECT count(*) FROM gp_lines
           WHERE cost_at_sale IS NULL AND current_cost IS NOT NULL)::int AS estimated_cost_rows,
         (SELECT count(*) FROM gp_lines
           WHERE cost_at_sale IS NULL AND current_cost IS NULL)::int AS unknown_cost_rows
)`;

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
 * reduces today's quantity and revenue. Sale lines come from `COUNTED_SALE` bills
 * only, the set `/reports/summary` uses (#97); credit notes need no filter, since a
 * manually voided bill cannot have one.
 */
const ITEM_EVENTS = `
sale_events AS (
  SELECT si.product_id, si.part_no, si.name, si.qty,
         (si.qty * si.price)::numeric AS revenue
    FROM bounds b
    JOIN sales s
      ON s.tenant_id = $1::uuid
     AND s.date >= b.from_at AND s.date < b.to_at
     AND ${COUNTED_SALE}
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
)
`;

const PRODUCT_ITEM_EVENTS = `
sale_events AS (
  SELECT si.product_id, si.part_no, si.name, si.qty,
         (si.qty * si.price)::numeric AS revenue
    FROM bounds b
    JOIN sales s
      ON s.tenant_id = $1::uuid
     AND s.date >= b.from_at AND s.date < b.to_at
     AND ${COUNTED_SALE}
    JOIN sale_items si
      ON si.tenant_id = $1::uuid
     AND si.product_id = $4
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
     AND ri.product_id = $4
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
)
`;

@Injectable()
export class ReportsService {
  constructor(private readonly tenants: TenantService) {}

  summary(range: ReportDateRange): Promise<ReportSummary> {
    return this.tenants.runTx(() => this.summaryIn(range));
  }

  private async summaryIn(range: ReportDateRange): Promise<ReportSummary> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `WITH ${BOUNDS},
       ${grossProfitCtes(
         's.date >= (SELECT from_at FROM bounds) AND s.date < (SELECT to_at FROM bounds)',
         'r.date >= (SELECT from_at FROM bounds) AND r.date < (SELECT to_at FROM bounds)',
       )},
       sale_totals AS (
         SELECT COALESCE(sum(total), 0)::numeric(20,2) AS revenue,
                count(*)::int AS transactions
           FROM gp_sales
       ),
       return_totals AS (
         SELECT COALESCE(sum(refund_total), 0)::numeric(20,2) AS refunds
           FROM gp_returns
       )
       SELECT s.revenue AS total_revenue,
              s.transactions AS total_transactions,
              CASE WHEN s.transactions = 0 THEN 0
                   ELSE round(s.revenue / s.transactions, 0)
               END::numeric(20,2) AS average_ticket,
              r.refunds AS total_refunds,
              (s.revenue - r.refunds)::numeric(20,2) AS net_revenue,
              -- Sale lines are positive and credit-note lines negative in gp_lines.
              (SELECT COALESCE(sum(qty), 0) FROM gp_lines)::int AS total_items,
              gp.gross_profit, gp.estimated_cost_rows, gp.unknown_cost_rows
         FROM sale_totals s CROSS JOIN return_totals r
         CROSS JOIN gross_profit gp`,
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
      grossProfit: row.gross_profit,
      estimatedCostRows: row.estimated_cost_rows,
      unknownCostRows: row.unknown_cost_rows,
    };
  }

  /**
   * The closing report for one shift, computed **by `shift_id`** — never by a time
   * window, which breaks across midnight and cannot tell two machines apart
   * (`02_API_SCREENS.md §3.11`):
   *
   *   expected = starting_cash + cash sales + mechanics' cash credit payments
   *            − cash refunds + drawer in − drawer out
   *   variance = physical_cash − expected   (null while the shift is not closed)
   *
   * Cash means the method string `'เงินสด'` on each document; transfers and
   * `เครดิตช่าง` / `หักจากเครดิต` never touch the drawer. Readable from both device
   * roles, like `GET /shifts/*`.
   */
  closing(shiftId: string): Promise<ClosingReport> {
    return this.tenants.runTx(() => this.closingIn(shiftId));
  }

  private async closingIn(shiftId: string): Promise<ClosingReport> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `WITH shift AS (
         SELECT id, date_str, device_id, opened_at, closed_at, starting_cash, physical_cash
           FROM shifts
          WHERE tenant_id = $1::uuid AND id = $2
       ),
       cash AS (
         SELECT
           (SELECT COALESCE(sum(s.total), 0) FROM sales s
             WHERE s.tenant_id = $1::uuid AND s.shift_id = $2
               AND s.payment_method = $3 AND ${COUNTED_SALE}) AS cash_sales,
           (SELECT COALESCE(sum(cp.amount), 0) FROM credit_payments cp
             WHERE cp.tenant_id = $1::uuid AND cp.shift_id = $2
               AND cp.payment_method = $3) AS cash_credit_payments,
           (SELECT COALESCE(sum(r.refund_total), 0) FROM returns r
             WHERE r.tenant_id = $1::uuid AND r.shift_id = $2
               AND r.refund_method = $3) AS cash_refunds,
           (SELECT COALESCE(sum(amount) FILTER (WHERE type = 'in'), 0) FROM drawer_entries
             WHERE tenant_id = $1::uuid AND shift_id = $2) AS drawer_in,
           (SELECT COALESCE(sum(amount) FILTER (WHERE type = 'out'), 0) FROM drawer_entries
             WHERE tenant_id = $1::uuid AND shift_id = $2) AS drawer_out
       ),
       ${grossProfitCtes('s.shift_id = $2', 'r.shift_id = $2')},
       expected AS (
         SELECT (sh.starting_cash + c.cash_sales + c.cash_credit_payments
                 - c.cash_refunds + c.drawer_in - c.drawer_out) AS expected_cash
           FROM shift sh CROSS JOIN cash c
       )
       SELECT sh.id, sh.date_str, sh.device_id, sh.opened_at, sh.closed_at,
              sh.starting_cash,
              c.cash_sales::numeric(20,2) AS cash_sales,
              c.cash_credit_payments::numeric(20,2) AS cash_credit_payments,
              c.cash_refunds::numeric(20,2) AS cash_refunds,
              c.drawer_in::numeric(20,2) AS drawer_in,
              c.drawer_out::numeric(20,2) AS drawer_out,
              e.expected_cash::numeric(20,2) AS expected_cash,
              CASE WHEN sh.closed_at IS NULL THEN NULL ELSE sh.physical_cash END AS physical_cash,
              CASE WHEN sh.closed_at IS NULL THEN NULL
                   ELSE (sh.physical_cash - e.expected_cash)::numeric(20,2) END AS variance,
              gp.gross_profit, gp.estimated_cost_rows, gp.unknown_cost_rows
         FROM shift sh CROSS JOIN cash c CROSS JOIN expected e CROSS JOIN gross_profit gp`,
      [tenantId, shiftId, CASH],
    )) as ClosingRow[];
    // RLS already hides another tenant's shift, and the explicit predicate hides it
    // again: an unknown id and a foreign one are the same 404.
    if (rows.length === 0) {
      throw new HttpException(
        { code: 'SHIFT_NOT_FOUND', message: 'Shift not found' },
        HttpStatus.NOT_FOUND,
      );
    }
    const row = rows[0];
    return {
      shiftId: row.id,
      dateStr: row.date_str,
      deviceId: row.device_id,
      openedAt: row.opened_at.toISOString(),
      closedAt: row.closed_at ? row.closed_at.toISOString() : null,
      startingCash: row.starting_cash,
      cashSales: row.cash_sales,
      cashCreditPayments: row.cash_credit_payments,
      cashRefunds: row.cash_refunds,
      drawerIn: row.drawer_in,
      drawerOut: row.drawer_out,
      expectedCash: row.expected_cash,
      physicalCash: row.physical_cash,
      variance: row.variance,
      grossProfit: row.gross_profit,
      estimatedCostRows: row.estimated_cost_rows,
      unknownCostRows: row.unknown_cost_rows,
    };
  }

  topProducts(range: ReportDateRange, limit: number): Promise<ProductSales[]> {
    return this.tenants.runTx(() => this.topProductsIn(range, limit));
  }

  private async topProductsIn(
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

  byCategory(range: ReportDateRange): Promise<CategorySales[]> {
    return this.tenants.runTx(() => this.byCategoryIn(range));
  }

  private async byCategoryIn(range: ReportDateRange): Promise<CategorySales[]> {
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

  stockValue(): Promise<StockValue> {
    return this.tenants.runTx(() => this.stockValueIn());
  }

  private async stockValueIn(): Promise<StockValue> {
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

  lowStock(
    page: number,
    limit: number,
  ): Promise<{ items: LowStockProduct[]; total: number }> {
    return this.tenants.runTx(() => this.lowStockIn(page, limit));
  }

  private async lowStockIn(
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

  productSales(
    productId: string,
    range: ReportDateRange,
  ): Promise<ProductSales> {
    return this.tenants.runTx(() => this.productSalesIn(productId, range));
  }

  private async productSalesIn(
    productId: string,
    range: ReportDateRange,
  ): Promise<ProductSales> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `WITH ${BOUNDS}, ${PRODUCT_ITEM_EVENTS}
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
