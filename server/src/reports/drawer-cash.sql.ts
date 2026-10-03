import type { EntityManager } from 'typeorm';
import { satangOf } from '../common/money.js';

/**
 * The ONE server rule for the cash a drawer should hold — shared by the closing report
 * (`reports.service.ts` `closingIn`) and the cash-out refusal (`shifts.service.ts`
 * `addEntryIn`, `DRAWER_INSUFFICIENT_CASH`), so the two can never disagree:
 *
 *   expected = starting_cash + cash sales + mechanics' cash credit payments
 *            − cash refunds + drawer in − drawer out
 *
 * Counted **by `shift_id`**, never by a time window (`02_API_SCREENS.md §3.11`) — the
 * owner's single rule since 2026-10-03 (PR #580): every baht taken or paid while a shift
 * is open belongs to it, even past midnight. The Dart client applies the same rule
 * (`ShiftsRepository.drawerCash`); where it has no local shift column (returns, credit
 * payments, a Drift-build sale) it uses the row's date in the shift's
 * `[opened_at, closed_at]`, which is the same row set because every money write here is
 * stamped with the shift open when it commits (`requireOpenShiftIdFor`, `FOR SHARE`, and
 * `close()` waits on it). Both sides run `docs/Backend_design/fixtures/drawer-cash/agreement.json`.
 * Parameters: `$1` tenant id, `$2` shift id, `$3` the cash method string ([CASH]).
 */

/** The one cash method string: `sales.dto.ts`, `returns.dto.ts` and `credit-payments.dto.ts` all accept it. */
export const CASH = 'เงินสด';

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
export const COUNTED_SALE = `NOT (s.voided AND NOT EXISTS (
  SELECT 1 FROM returns rv
   WHERE rv.tenant_id = $1::uuid AND rv.tenant_id = s.tenant_id AND rv.sale_id = s.id))`;

/** `shift AS (…), cash AS (…), expected AS (…)` — CTEs for one shift's drawer. */
export const DRAWER_CASH_CTES = `
shift AS (
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
expected AS (
  SELECT (sh.starting_cash + c.cash_sales + c.cash_credit_payments
          - c.cash_refunds + c.drawer_in - c.drawer_out) AS expected_cash
    FROM shift sh CROSS JOIN cash c
)`;

/**
 * The cash [shiftId]'s drawer should hold right now, in integer satang — the closing
 * report's `expectedCash` for the same shift. Runs on the caller's request manager (no
 * second pool connection). 0 when the shift does not exist.
 */
export async function expectedCashSatangOf(
  manager: EntityManager,
  tenantId: string,
  shiftId: string,
): Promise<number> {
  const rows = (await manager.query(
    `WITH ${DRAWER_CASH_CTES}
     SELECT e.expected_cash::numeric(20,2) AS expected_cash FROM expected e`,
    [tenantId, shiftId, CASH],
  )) as { expected_cash: string }[];
  return rows.length === 0 ? 0 : satangOf(rows[0].expected_cash);
}
