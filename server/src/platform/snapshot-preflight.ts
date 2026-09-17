/**
 * #239 — pre-flight checks `tenant-import.service.ts` runs on the JSON alone, before any
 * write: `01_DATABASE.md §9` step 2 says stop and decide, never import and hope.
 *
 * Three gaps `#185`'s real-file run found, all the same shape (read `#22`'s lesson): a
 * value the importer would otherwise clamp or default away silently, corrupting the ledger
 * or moving a bill into the wrong day without raising anything. Refusing here, with the
 * offending ids, turns that into a 400 an operator can act on instead of a 500 mid-transaction
 * or a quiet wrong number.
 *
 * Pure: reads only the snapshot, exactly like `snapshot-tombstones.ts` (which this module's
 * caller runs alongside it). No DB access, so every rule here is unit-testable on its own.
 */

type Row = Record<string, unknown>;

const rows = (v: unknown): Row[] =>
  Array.isArray(v) ? (v as unknown[]).filter((x): x is Row => !!x && typeof x === 'object') : [];

// ── 1. Duplicate document numbers ───────────────────────────────────────────────────────
// `receipt_no` / `cn_no` / `po_no` / `quote_no` (and credit payments' own `receipt_no`, a
// different table) are each `UNIQUE (tenant_id, …)` in Postgres (`01_DATABASE.md §5`). The
// generated fallback (`RC-<id>`, …) can never collide across distinct ids, so this only
// fires on an explicit number the file repeats — exactly what the unique index would raise
// as an unnamed 23505 mid-transaction.

export interface DuplicateDocNumber {
  table: string;
  field: string;
  value: string;
  ids: string[];
}

export function planDuplicateDocNumbers(snapshot: Row): DuplicateDocNumber[] {
  const out: DuplicateDocNumber[] = [];
  const scan = (table: string, field: string, xs: Row[], derive: (r: Row, id: string) => string) => {
    const byNumber = new Map<string, Set<string>>();
    for (const r of xs) {
      const id = String(r.id);
      const n = derive(r, id);
      const set = byNumber.get(n) ?? new Set<string>();
      set.add(id);
      byNumber.set(n, set);
    }
    for (const [value, ids] of byNumber) {
      if (ids.size > 1) out.push({ table, field, value, ids: [...ids] });
    }
  };
  scan('sales', 'receiptNo', rows(snapshot.sa_sales), (r, id) => String(r.receiptNo || r.receipt_no || `RC-${id}`));
  scan('returns', 'cnNo', rows(snapshot.sa_returns), (r, id) => String(r.cnNo || r.cn_no || `CN-${id}`));
  scan('purchaseOrders', 'poNo', rows(snapshot.sa_pos), (r, id) => String(r.poNo || r.po_no || `PO-${id}`));
  scan('quotes', 'quoteNo', rows(snapshot.sa_quotes), (r, id) => String(r.quoteNo || r.quote_no || `QT-${id}`));
  scan('creditPayments', 'receiptNo', rows(snapshot.sa_credit_payments), (r, id) => String(r.receiptNo || r.receipt_no || `CP-${id}`));
  return out;
}

// ── 2. Unparseable dates ────────────────────────────────────────────────────────────────
// `parseDate()` in `tenant-import.service.ts` falls back to `new Date()` when a value fails
// to parse, which moves a bill into *import time*. Absent (`null`/`undefined`) is a normal
// default (a field the export omits) and is never flagged — only a value the file actually
// supplies that `new Date(String(v))` cannot read.

export interface BadDate {
  table: string;
  id: string;
  field: string;
  value: unknown;
}

function isBadDate(v: unknown): boolean {
  if (v == null) return false;
  return isNaN(new Date(String(v)).getTime());
}

export function planUnparseableDates(snapshot: Row): BadDate[] {
  const out: BadDate[] = [];
  const check = (table: string, id: string, field: string, v: unknown) => {
    if (isBadDate(v)) out.push({ table, id, field, value: v });
  };

  for (const c of rows(snapshot.sa_customers)) {
    const id = String(c.id);
    check('customers', id, 'createdAt', c.createdAt ?? c.created_at);
    check('customers', id, 'deletedAt', c.deletedAt ?? c.deleted_at);
  }
  for (const m of rows(snapshot.sa_mechanics)) {
    const id = String(m.id);
    check('mechanics', id, 'createdAt', m.createdAt ?? m.created_at);
    check('mechanics', id, 'deletedAt', m.deletedAt ?? m.deleted_at);
  }
  for (const p of rows(snapshot.sa_products)) {
    // Products carry no `deletedAt` in any real export today (the client schema has no such
    // column — CLAUDE.md, #55) — checked anyway so a future export that adds one is covered
    // from day one instead of silently importing as live.
    check('products', String(p.id), 'deletedAt', p.deletedAt ?? p.deleted_at);
  }
  for (const s of rows(snapshot.sa_sales)) {
    const id = String(s.id);
    check('sales', id, 'date', s.date);
    check('sales', id, 'voidedAt', s.voidedAt ?? s.voided_at);
  }
  for (const r of rows(snapshot.sa_returns)) check('returns', String(r.id), 'date', r.date);
  for (const po of rows(snapshot.sa_pos)) {
    const id = String(po.id);
    check('purchaseOrders', id, 'createdAt', po.createdAt ?? po.created_at);
    check('purchaseOrders', id, 'receivedAt', po.receivedAt ?? po.received_at);
    check('purchaseOrders', id, 'cancelledAt', po.cancelledAt ?? po.cancelled_at);
  }
  for (const q of rows(snapshot.sa_quotes)) {
    const id = String(q.id);
    check('quotes', id, 'date', q.date);
    check('quotes', id, 'validUntil', q.validUntil ?? q.valid_until);
    check('quotes', id, 'convertedAt', q.convertedAt ?? q.converted_at);
  }
  for (const m of rows(snapshot.sa_movements)) check('movements', String(m.id), 'date', m.date);
  for (const cp of rows(snapshot.sa_credit_payments)) check('creditPayments', String(cp.id), 'date', cp.date);

  const shifts: Array<{ sh: Row; idx: number }> = [
    ...(snapshot.sa_cash_drawer && typeof snapshot.sa_cash_drawer === 'object' ? [{ sh: snapshot.sa_cash_drawer as Row, idx: 0 }] : []),
    ...rows(snapshot.sa_shift_history).map((sh, i) => ({ sh, idx: i + 1 })),
  ];
  for (const { sh, idx } of shifts) {
    // A shift in the file carries no `id` (`01_DATABASE.md §9`'s trap) — labelled by date,
    // falling back to its position, so a violation is still findable in the file.
    const label = String(sh.id ?? sh.date ?? sh.dateStr ?? sh.date_str ?? `#${idx}`);
    check('shifts', label, 'openedAt', sh.openedAt ?? sh.opened_at);
    check('shifts', label, 'closedAt', sh.closedAt ?? sh.closed_at);
    check('shifts', label, 'archivedAt', sh.archivedAt ?? sh.archived_at);
    for (const [j, entry] of rows(sh.entries).entries()) {
      check('drawerEntries', `${label}:${String(entry.id ?? j)}`, 'createdAt', entry.createdAt ?? entry.created_at);
    }
  }
  rows(snapshot.sa_parked).forEach((ps, i) => check('parkedSales', String(ps.id ?? `#${i}`), 'parkedAt', ps.parkedAt ?? ps.parked_at));

  return out;
}

// ── 3. Validate-then-clamp ──────────────────────────────────────────────────────────────
// `#22`'s lesson, restated for import: `tenant-import.service.ts` used to write
// `Math.max(0, …)` / `Math.max(1, …)` straight over unvalidated input — a negative balance,
// a negative point total, a negative `minStock`, or a sale/return/PO/quote line's `qty` of
// zero, negative, non-integer, or missing all silently became 0 or 1. That changes stock
// arithmetic and the mechanic/customer ledgers with no error at all. A clamp on unvalidated
// input converts a loud corruption into a quiet one — refuse here instead; the importer's own
// clamps now run only on values this function has already accepted.
//
// `products.stock` is not here: it already has its own pre-flight refusal in
// `tenant-import.service.ts` (kept as-is, first found by #185 before this module existed).

export interface ClampViolation {
  table: string;
  id: string;
  field: string;
  value: unknown;
  rule: string;
}

function asNumber(v: unknown): number {
  return typeof v === 'number' ? v : parseFloat(String(v));
}

export function planClampViolations(snapshot: Row): ClampViolation[] {
  const out: ClampViolation[] = [];

  const nonNegative = (table: string, id: string, field: string, v: unknown) => {
    if (v == null) return; // absent → the importer's own default (0), not a clamp on a real value
    const n = asNumber(v);
    if (!Number.isFinite(n) || n < 0) out.push({ table, id, field, value: v, rule: 'must be ≥ 0' });
  };
  const positiveInteger = (table: string, id: string, field: string, v: unknown) => {
    const n = asNumber(v);
    if (!Number.isFinite(n) || !Number.isInteger(n) || n < 1) {
      out.push({ table, id, field, value: v ?? null, rule: 'must be a positive whole number' });
    }
  };
  // #239 review (money fields `round2()` turns NaN into 0 for, with no pre-flight check at
  // all): `finite` covers every one of them — a value the file supplies that is not a number
  // silently became 0 with no error, corrupting a price, a total or a balance. `nonNegMoney`/
  // `positiveMoney` add the stricter rule where Postgres has a real `CHECK` on the column
  // (`1788652800000-InitialSchema.ts`): `products.price/cost >= 0`, `po_items.cost >= 0`,
  // `credit_payments.amount > 0`, `drawer_entries.amount > 0`. Everywhere else (supplier
  // costs, sale/return totals, `mechanicDelta`, mechanic running totals, shift cash) has no
  // `CHECK`, so only non-finite is refused — `mechanicDelta` in particular is negative by
  // design (a discount given), and refusing that would reject ordinary bills.
  const finite = (table: string, id: string, field: string, v: unknown) => {
    if (v == null) return;
    if (!Number.isFinite(asNumber(v))) out.push({ table, id, field, value: v, rule: 'must be a finite number' });
  };
  const nonNegMoney = (table: string, id: string, field: string, v: unknown) => {
    if (v == null) return;
    const n = asNumber(v);
    if (!Number.isFinite(n)) out.push({ table, id, field, value: v, rule: 'must be a finite number' });
    else if (n < 0) out.push({ table, id, field, value: v, rule: 'must be ≥ 0' });
  };
  const positiveMoney = (table: string, id: string, field: string, v: unknown) => {
    if (v == null) return;
    const n = asNumber(v);
    if (!Number.isFinite(n)) out.push({ table, id, field, value: v, rule: 'must be a finite number' });
    else if (n <= 0) out.push({ table, id, field, value: v, rule: 'must be > 0' });
  };

  for (const p of rows(snapshot.sa_products)) {
    const id = String(p.id);
    nonNegative('products', id, 'minStock', p.minStock ?? p.min_stock);
    nonNegMoney('products', id, 'price', p.price);
    nonNegMoney('products', id, 'cost', p.cost);
  }
  for (const sup of rows(snapshot.sa_suppliers)) {
    const id = String(sup.id);
    finite('suppliers', id, 'unitCost', sup.unitCost ?? sup.unit_cost);
    finite('suppliers', id, 'freight', sup.freight);
  }
  for (const c of rows(snapshot.sa_customers)) {
    const id = String(c.id);
    nonNegative('customers', id, 'points', c.points);
    finite('customers', id, 'totalSpend', c.totalSpend ?? c.total_spend);
  }
  for (const m of rows(snapshot.sa_mechanics)) {
    const id = String(m.id);
    nonNegative('mechanics', id, 'creditBalance', m.creditBalance ?? m.credit_balance);
    finite('mechanics', id, 'creditLimit', m.creditLimit ?? m.credit_limit);
    finite('mechanics', id, 'totalSales', m.totalSales ?? m.total_sales);
    finite('mechanics', id, 'totalCredit', m.totalCredit ?? m.total_credit);
    finite('mechanics', id, 'totalDiscount', m.totalDiscount ?? m.total_discount);
    finite('mechanics', id, 'totalMarkup', m.totalMarkup ?? m.total_markup);
  }

  for (const s of rows(snapshot.sa_sales)) {
    const id = String(s.id);
    nonNegative('sales', id, 'pointsGranted', s.pointsGranted ?? s.points_granted);
    finite('sales', id, 'subtotal', s.subtotal);
    finite('sales', id, 'discount', s.discount);
    finite('sales', id, 'total', s.total);
    // Negative by design: a mechanic markup/discount delta, never `CHECK`-constrained.
    finite('sales', id, 'mechanicDelta', s.mechanicDelta ?? s.mechanic_delta);
    rows(s.items).forEach((item, i) => {
      const lineId = `${id}:${i + 1}`;
      positiveInteger('saleItems', lineId, 'qty', item.qty);
      finite('saleItems', lineId, 'price', item.price);
      finite('saleItems', lineId, 'costAtSale', item.costAtSale ?? item.cost);
    });
  }
  for (const r of rows(snapshot.sa_returns)) {
    const id = String(r.id);
    finite('returns', id, 'refundSubtotal', r.refundSubtotal ?? r.refund_subtotal);
    finite('returns', id, 'refundDiscount', r.refundDiscount ?? r.refund_discount);
    finite('returns', id, 'refundTotal', r.refundTotal ?? r.refund_total);
    rows(r.items).forEach((item, i) => {
      const lineId = `${id}:${i + 1}`;
      positiveInteger('returnItems', lineId, 'qty', item.qty);
      finite('returnItems', lineId, 'price', item.price);
    });
  }
  for (const po of rows(snapshot.sa_pos)) {
    const id = String(po.id);
    rows(po.items).forEach((item, i) => {
      const lineId = `${id}:${i + 1}`;
      positiveInteger('poItems', lineId, 'qty', item.qty);
      nonNegMoney('poItems', lineId, 'cost', item.cost);
    });
  }
  for (const q of rows(snapshot.sa_quotes)) {
    const id = String(q.id);
    finite('quotes', id, 'subtotal', q.subtotal);
    finite('quotes', id, 'discount', q.discount);
    finite('quotes', id, 'total', q.total);
    rows(q.items).forEach((item, i) => {
      const lineId = `${id}:${i + 1}`;
      positiveInteger('quoteItems', lineId, 'qty', item.qty);
      finite('quoteItems', lineId, 'price', item.price);
    });
  }
  for (const cp of rows(snapshot.sa_credit_payments)) {
    positiveMoney('creditPayments', String(cp.id), 'amount', cp.amount);
  }

  const shiftsForMoney: Array<{ sh: Row; idx: number }> = [
    ...(snapshot.sa_cash_drawer && typeof snapshot.sa_cash_drawer === 'object' ? [{ sh: snapshot.sa_cash_drawer as Row, idx: 0 }] : []),
    ...rows(snapshot.sa_shift_history).map((sh, i) => ({ sh, idx: i + 1 })),
  ];
  for (const { sh, idx } of shiftsForMoney) {
    const label = String(sh.id ?? sh.date ?? sh.dateStr ?? sh.date_str ?? `#${idx}`);
    finite('shifts', label, 'startingCash', sh.startingCash ?? sh.starting_cash);
    finite('shifts', label, 'physicalCash', sh.physicalCash ?? sh.physical_cash);
    rows(sh.entries).forEach((entry, j) => {
      positiveMoney('drawerEntries', `${label}:${String(entry.id ?? j)}`, 'amount', entry.amount);
    });
  }

  if (snapshot.sa_settings && typeof snapshot.sa_settings === 'object') {
    const set = snapshot.sa_settings as Row;
    const qvd = set.quoteValidDays ?? set.quote_valid_days;
    if (qvd != null) {
      const n = asNumber(qvd);
      if (!Number.isFinite(n) || !Number.isInteger(n) || n < 1) {
        out.push({ table: 'settings', id: '-', field: 'quoteValidDays', value: qvd, rule: 'must be a positive whole number' });
      }
    }
    finite('settings', '-', 'taxRate', set.taxRate ?? set.tax_rate);
  }

  return out;
}

/** One line per violation, for a `BadRequestException` message the operator can act on. */
export function describeDuplicate(d: DuplicateDocNumber): string {
  return `${d.table}.${d.field} '${d.value}' is used by ${d.ids.map((id) => `'${id}'`).join(', ')}`;
}
export function describeBadDate(d: BadDate): string {
  return `${d.table}:${d.id}.${d.field} is not a parseable date (${JSON.stringify(d.value)})`;
}
export function describeClamp(c: ClampViolation): string {
  return `${c.table}:${c.id}.${c.field} ${c.rule} (got ${JSON.stringify(c.value)})`;
}
