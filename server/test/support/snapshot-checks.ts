/**
 * #185 — checks on a shop snapshot (`sa_*` + `__meta`), used twice:
 *
 * 1. `checkSnapshotInvariants` reads the JSON alone and verifies the ledgers agree with each
 *    other the way the Drift repositories keep them — the synthetic generator is held to it,
 *    and it doubles as a pre-flight report on the shop's real file.
 * 2. `reconcileImport` runs `01_DATABASE.md §9` step 5 — the six post-import checks — by
 *    comparing what the snapshot says with what the import wrote for one tenant.
 *
 * Money is compared in integer satang, so a `123.45000000000002` in the file and the
 * `NUMERIC(12,2)` `123.45` in Postgres are the same number and a real one-satang
 * difference is not.
 */
import type { DataSource } from 'typeorm';
import { snapshotProductCategory as productCategory } from '../../src/platform/snapshot-category.js';
import { countTombstones, planTombstones, TOMBSTONE_MARK } from '../../src/platform/snapshot-tombstones.js';

type Json = Record<string, any>;

export const sat = (v: unknown): number => Math.round(Number(v ?? 0) * 100);
const list = (v: unknown): Json[] => (Array.isArray(v) ? (v as Json[]).filter((x) => x && typeof x === 'object') : []);

/** `sa_categories` is an array of names; tolerate `{ name }` objects too. */
export const snapshotCategoryNames = (s: Json): string[] =>
  (Array.isArray(s.sa_categories) ? s.sa_categories : [])
    .map((c: unknown) => (typeof c === 'string' ? c : (c as Json | null)?.name))
    .filter((c: unknown): c is string => typeof c === 'string');

/** Every shift in the file: the open drawer (if any) first, then history newest first. */
export const snapshotShifts = (s: Json): Json[] => [
  ...(s.sa_cash_drawer && typeof s.sa_cash_drawer === 'object' ? [s.sa_cash_drawer as Json] : []),
  ...list(s.sa_shift_history),
];

export interface InvariantReport {
  violations: string[];
  /** References the Drift build allows (no foreign keys, hard deletes) but Postgres does not. */
  orphans: Record<string, number>;
  /** What the import does about the orphans (#238/#252): tombstones per table, drops, refusals. */
  tombstones: {
    products: number;
    customers: number;
    mechanics: number;
    unnamed: number;
    returnsWithoutSale: number;
    droppedSuppliers: number;
    missingRefs: number;
  };
}

export function checkSnapshotInvariants(s: Json): InvariantReport {
  const v: string[] = [];
  const products = list(s.sa_products);
  const sales = list(s.sa_sales);
  const returns = list(s.sa_returns);
  const customers = list(s.sa_customers);
  const mechanics = list(s.sa_mechanics);
  const payments = list(s.sa_credit_payments);
  const movements = list(s.sa_movements);

  // Unique ids and document numbers, per store.
  const unique = (label: string, xs: Json[], key: string) => {
    const seen = new Set<string>();
    for (const x of xs) {
      const k = String(x[key]);
      if (seen.has(k)) v.push(`${label}: duplicate ${key} ${k}`);
      seen.add(k);
    }
  };
  unique('products', products, 'id');
  unique('products', products.map((p) => ({ partNo: String(p.partNo).toLowerCase() })), 'partNo');
  unique('sales', sales, 'id');
  unique('sales', sales, 'receiptNo');
  unique('returns', returns, 'cnNo');
  unique('purchase orders', list(s.sa_pos), 'poNo');
  unique('quotes', list(s.sa_quotes), 'quoteNo');
  unique('credit payments', payments, 'receiptNo');
  unique('movements', movements, 'id');

  const counts = (s.__meta?.recordCounts ?? {}) as Record<string, number>;
  const stores: Record<string, unknown> = {
    products: s.sa_products, customers: s.sa_customers, sales: s.sa_sales, purchaseOrders: s.sa_pos,
    movements: s.sa_movements, suppliers: s.sa_suppliers, mechanics: s.sa_mechanics, quotes: s.sa_quotes,
    returns: s.sa_returns, creditPayments: s.sa_credit_payments, shiftHistory: s.sa_shift_history,
    parked: s.sa_parked, categories: s.sa_categories,
  };
  for (const [k, store] of Object.entries(stores)) {
    if (counts[k] != null && counts[k] !== (Array.isArray(store) ? store.length : 0)) v.push(`__meta.recordCounts.${k} is ${counts[k]}, store has ${Array.isArray(store) ? store.length : 0}`);
  }

  // Sales: arithmetic and points.
  const saleById = new Map(sales.map((x) => [String(x.id), x]));
  for (const x of sales) {
    const lines = list(x.items);
    const subtotal = lines.reduce((t, i) => t + sat(i.price) * Number(i.qty), 0);
    if (subtotal !== sat(x.subtotal)) v.push(`sale ${x.receiptNo}: subtotal ${x.subtotal} ≠ Σ lines ${subtotal / 100}`);
    if (Math.max(0, sat(x.subtotal) - sat(x.discount)) !== sat(x.total)) v.push(`sale ${x.receiptNo}: total ≠ subtotal − discount`);
    if (Number(x.pointsGranted ?? 0) !== Math.floor(Number(x.total) / 10)) v.push(`sale ${x.receiptNo}: pointsGranted ≠ floor(total/10)`);
    if (x.paymentMethod === 'เครดิตช่าง' && !x.mechanicId) v.push(`sale ${x.receiptNo}: credit sale without a mechanic`);
    if (lines.some((i) => !(Number(i.qty) > 0))) v.push(`sale ${x.receiptNo}: a line with qty ≤ 0`);
  }

  // Returns: never more than sold, discount pro-rated, full return voids the bill.
  const refundedBySale = new Map<string, Map<string, number>>();
  for (const r of returns) {
    const sale = saleById.get(String(r.saleId));
    if (!sale) { v.push(`return ${r.cnNo}: sale ${r.saleId} is not in the file`); continue; }
    const subtotal = list(r.items).reduce((t, i) => t + Number(i.price) * Number(i.qty), 0);
    const discount = Math.round(subtotal * (Number(sale.subtotal) > 0 ? Number(sale.discount) / Number(sale.subtotal) : 0) * 100) / 100;
    if (sat(subtotal) !== sat(r.refundSubtotal) || sat(subtotal - discount) !== sat(r.refundTotal)) v.push(`return ${r.cnNo}: refund arithmetic does not match the bill's discount ratio`);
    const done = refundedBySale.get(String(r.saleId)) ?? new Map<string, number>();
    refundedBySale.set(String(r.saleId), done);
    for (const i of list(r.items)) done.set(String(i.productId), (done.get(String(i.productId)) ?? 0) + Number(i.qty));
  }
  for (const [saleId, done] of refundedBySale) {
    const sale = saleById.get(saleId)!;
    let soldTotal = 0;
    const sold = new Map<string, number>();
    for (const i of list(sale.items)) {
      sold.set(String(i.productId), (sold.get(String(i.productId)) ?? 0) + Number(i.qty));
      soldTotal += Number(i.qty);
    }
    for (const [pid, q] of done) if (q > (sold.get(pid) ?? 0)) v.push(`sale ${sale.receiptNo}: refunded ${q} of ${pid}, sold ${sold.get(pid) ?? 0}`);
    const refundedTotal = [...done.values()].reduce((t, q) => t + q, 0);
    if (Boolean(sale.voided) !== refundedTotal >= soldTotal) v.push(`sale ${sale.receiptNo}: voided=${sale.voided} but ${refundedTotal}/${soldTotal} units returned`);
  }
  for (const x of sales) if (x.voided && !refundedBySale.has(String(x.id))) v.push(`sale ${x.receiptNo}: voided with no return (the Drift build has no manual void)`);

  // Stock = Σ movements − Σ sold + Σ returned (Drift's saveSale / createReturn log no movement).
  const stockFlow = new Map<string, number>();
  const add = (pid: unknown, q: number) => stockFlow.set(String(pid), (stockFlow.get(String(pid)) ?? 0) + q);
  for (const m of movements) add(m.productId, Number(m.delta));
  for (const x of sales) for (const i of list(x.items)) add(i.productId, -Number(i.qty));
  for (const r of returns) for (const i of list(r.items)) add(i.productId, Number(i.qty));
  for (const p of products) {
    if (!(Number(p.stock) >= 0)) v.push(`product ${p.partNo}: stock ${p.stock} < 0`);
    if ((stockFlow.get(String(p.id)) ?? 0) !== Number(p.stock)) v.push(`product ${p.partNo}: stock ${p.stock} ≠ movements − sold + returned (${stockFlow.get(String(p.id)) ?? 0})`);
  }

  // Customers: points and spend are the sum of their bills less their credit notes.
  for (const c of customers) {
    let points = 0;
    let spend = 0;
    for (const x of sales) if (x.customerId === c.id) { points += Number(x.pointsGranted ?? 0); spend += sat(x.total); }
    for (const r of returns) {
      const sale = saleById.get(String(r.saleId));
      if (!sale || sale.customerId !== c.id) continue;
      const ratio = Number(sale.total) > 0 ? Number(r.refundTotal) / Number(sale.total) : 0;
      const base = Number(sale.pointsGranted) > 0 ? Number(sale.pointsGranted) : Math.floor(Number(sale.total) / 10);
      points -= Math.floor(base * ratio);
      spend -= sat(r.refundTotal);
    }
    if (points !== Number(c.points)) v.push(`customer ${c.code}: points ${c.points} ≠ ledger ${points}`);
    if (Math.abs(spend - sat(c.totalSpend)) > 1) v.push(`customer ${c.code}: totalSpend ${c.totalSpend} ≠ ledger ${spend / 100}`);
  }

  // Mechanics: balance = credit bills − payments − credit notes taken off the tab.
  for (const m of mechanics) {
    let bal = 0;
    for (const x of sales) if (x.mechanicId === m.id && x.paymentMethod === 'เครดิตช่าง') bal += sat(x.total);
    for (const p of payments) if (p.mechanicId === m.id) bal -= sat(p.amount);
    for (const r of returns) if (r.mechanicId === m.id && r.refundMethod === 'หักจากเครดิต') bal -= sat(r.refundTotal);
    if (bal < 0) v.push(`mechanic ${m.code}: payments exceed credit bills (Drift's clamp at 0 fired)`);
    if (Math.abs(bal - sat(m.creditBalance)) > 1) v.push(`mechanic ${m.code}: creditBalance ${m.creditBalance} ≠ ledger ${bal / 100}`);
  }

  // Shifts and drawer entries.
  for (const sh of snapshotShifts(s)) {
    for (const e of list(sh.entries)) {
      if (e.type !== 'in' && e.type !== 'out') v.push(`shift ${sh.date}: entry type ${e.type}`);
      if (!(Number(e.amount) > 0)) v.push(`shift ${sh.date}: entry amount ${e.amount} ≤ 0`);
    }
  }

  // What Postgres will refuse and Drift never did.
  const productIds = new Set(products.map((p) => String(p.id)));
  const customerIds = new Set(customers.map((c) => String(c.id)));
  const mechanicIds = new Set(mechanics.map((m) => String(m.id)));
  const categoryNames = new Set(snapshotCategoryNames(s));
  const orphans: Record<string, number> = {
    'movements → missing product': movements.filter((m) => !productIds.has(String(m.productId))).length,
    'suppliers → missing product': list(s.sa_suppliers).filter((x) => !productIds.has(String(x.productId))).length,
    'sales → missing customer': sales.filter((x) => x.customerId != null && !customerIds.has(String(x.customerId))).length,
    'sales → missing mechanic': sales.filter((x) => x.mechanicId != null && !mechanicIds.has(String(x.mechanicId))).length,
    'credit payments → missing mechanic': payments.filter((p) => !mechanicIds.has(String(p.mechanicId))).length,
    'products → category not in sa_categories': products.filter((p) => !categoryNames.has(productCategory(p))).length,
  };
  const plan = planTombstones(s);
  const tombstones = {
    ...countTombstones(plan),
    unnamed: plan.unnamed.length,
    returnsWithoutSale: plan.returnsWithoutSale.length,
    droppedSuppliers: plan.droppedSuppliers.length,
    missingRefs: plan.missingRefs.length,
  };
  return { violations: v, orphans, tombstones };
}

export interface ReconcileRow {
  item: string;
  expected: string | number;
  actual: string | number;
  ok: boolean;
}

/**
 * `01_DATABASE.md §9` step 5, for one tenant. Queries run on a connection that bypasses
 * RLS (the owner / superuser) and always filter by `tenant_id` themselves.
 */
export async function reconcileImport(db: DataSource, tenantId: string, s: Json): Promise<ReconcileRow[]> {
  const rows: ReconcileRow[] = [];
  const row = (item: string, expected: string | number, actual: string | number) =>
    rows.push({ item, expected, actual, ok: String(expected) === String(actual) });
  const one = async (sql: string) => (await db.query(sql, [tenantId]))[0] as Json;

  // 1. SUM(sales.total)
  const salesSum = list(s.sa_sales).reduce((t, x) => t + sat(x.total), 0);
  row('SUM(sales.total) satang', salesSum, Number((await one(`SELECT COALESCE(SUM(total * 100), 0)::bigint AS v FROM sales WHERE tenant_id = $1`)).v));

  // 2. SUM(products.stock)
  const stockSum = list(s.sa_products).reduce((t, p) => t + Number(p.stock ?? 0), 0);
  row('SUM(products.stock)', stockSum, Number((await one(`SELECT COALESCE(SUM(stock), 0)::bigint AS v FROM products WHERE tenant_id = $1`)).v));

  // 3. COUNT(*) of every table the snapshot feeds.
  const shifts = snapshotShifts(s);
  const itemCount = (store: unknown) => list(store).reduce((t, x) => t + list(x.items).length, 0);
  // #238: hard-deleted rows history still references come back as soft-deleted tombstones.
  const plan = planTombstones(s);
  const tombstoned: Record<string, number> = countTombstones(plan);
  // #252: a supplier row for a product neither live nor tombstoned is dropped, not imported.
  const dropped: Record<string, number> = { suppliers: plan.droppedSuppliers.length };
  const expectedCounts: Record<string, number> = {
    products: list(s.sa_products).length + tombstoned.products,
    suppliers: list(s.sa_suppliers).length - dropped.suppliers,
    customers: list(s.sa_customers).length + tombstoned.customers,
    mechanics: list(s.sa_mechanics).length + tombstoned.mechanics,
    sales: list(s.sa_sales).length,
    sale_items: itemCount(s.sa_sales),
    returns: list(s.sa_returns).length,
    return_items: itemCount(s.sa_returns),
    credit_payments: list(s.sa_credit_payments).length,
    purchase_orders: list(s.sa_pos).length,
    po_items: itemCount(s.sa_pos),
    quotes: list(s.sa_quotes).length,
    quote_items: itemCount(s.sa_quotes),
    movements: list(s.sa_movements).length,
    shifts: shifts.length,
    drawer_entries: shifts.reduce((t, sh) => t + list(sh.entries).length, 0),
    parked_sales: list(s.sa_parked).length,
    settings: s.sa_settings ? 1 : 0,
  };
  const dbCounts: Record<string, number> = {};
  for (const [table, n] of Object.entries(expectedCounts)) {
    dbCounts[table] = Number((await one(`SELECT count(*)::int AS v FROM ${table} WHERE tenant_id = $1`)).v);
    row(`COUNT(${table})`, n, dbCounts[table]);
  }
  // …and against the file's own `__meta.recordCounts`, which the app wrote when it exported:
  // a store truncated between export and import shows up here even when the lists agree.
  const recordCounts = (s.__meta?.recordCounts ?? {}) as Record<string, number>;
  const metaTables: Record<string, string> = {
    products: 'products', customers: 'customers', mechanics: 'mechanics', suppliers: 'suppliers',
    sales: 'sales', returns: 'returns', creditPayments: 'credit_payments', purchaseOrders: 'purchase_orders',
    quotes: 'quotes', movements: 'movements', parked: 'parked_sales',
  };
  for (const [key, table] of Object.entries(metaTables)) {
    if (recordCounts[key] != null) {
      row(
        `__meta.recordCounts.${key} (+ tombstones − dropped) vs COUNT(${table})`,
        recordCounts[key] + (tombstoned[table] ?? 0) - (dropped[table] ?? 0),
        dbCounts[table],
      );
    }
  }
  // #252: the dropped supplier rows are truly gone, not merely uncounted.
  if (plan.droppedSuppliers.length > 0) {
    const remaining = (
      await db.query(`SELECT count(*)::int AS v FROM suppliers WHERE tenant_id = $1 AND id = ANY($2)`, [tenantId, plan.droppedSuppliers])
    )[0] as Json;
    row('dropped supplier rows absent from the DB', 0, Number(remaining.v));
  }
  if (recordCounts.shiftHistory != null) {
    row('__meta.recordCounts.shiftHistory + cashDrawer vs COUNT(shifts)', recordCounts.shiftHistory + (recordCounts.cashDrawer ?? 0), dbCounts.shifts);
  }
  // Categories: provisioning seeds five, and a product may name a category the list lost,
  // which §9 says to create. Every name the file uses must exist. A seed the file never names
  // is informational only — a shop that deleted a seed category must not fail the check.
  const wanted = new Set<string>([...snapshotCategoryNames(s), ...list(s.sa_products).map(productCategory)]);
  const have = new Set<string>((await db.query(`SELECT name FROM categories WHERE tenant_id = $1`, [tenantId])).map((r: Json) => String(r.name)));
  row('categories named by the file, missing in DB', 0, [...wanted].filter((c) => !have.has(c)).length);
  rows.push({ item: '(info) categories in DB the file never named — provisioning seed', expected: '-', actual: [...have].filter((c) => !wanted.has(c)).length, ok: true });

  // The tombstones themselves: soft-deleted, marked, exactly the planned number, and no
  // resurrection — the live rows are exactly the file's.
  const marked: Record<string, string> = {
    products: `deleted_at IS NOT NULL AND brand = '${TOMBSTONE_MARK}'`,
    customers: `deleted_at IS NOT NULL AND code LIKE '${TOMBSTONE_MARK}:%'`,
    mechanics: `deleted_at IS NOT NULL AND code LIKE '${TOMBSTONE_MARK}:%'`,
  };
  for (const [table, where] of Object.entries(marked)) {
    const n = Number((await one(`SELECT count(*)::int AS v FROM ${table} WHERE tenant_id = $1 AND ${where}`)).v);
    row(`tombstones in ${table} (soft-deleted, marked)`, tombstoned[table], n);
    const live = Number((await one(`SELECT count(*)::int AS v FROM ${table} WHERE tenant_id = $1 AND deleted_at IS NULL`)).v);
    row(`live ${table} (deleted_at IS NULL) = the file's`, list(s[`sa_${table}`]).filter((x) => x.deletedAt == null).length, live);
  }

  // 4. Every customer's points and total spend.
  const dbCustomers = new Map<string, Json>((await db.query(`SELECT id, points, total_spend FROM customers WHERE tenant_id = $1`, [tenantId])).map((r: Json) => [String(r.id), r]));
  const badCustomers = list(s.sa_customers).filter((c) => {
    const d = dbCustomers.get(String(c.id));
    return !d || Number(d.points) !== Number(c.points ?? 0) || sat(d.total_spend) !== sat(c.totalSpend);
  });
  row('customers whose points/total_spend differ', 0, badCustomers.length);

  // 5. Every mechanic's credit_balance, and SUM(credit_payments.amount).
  const dbMechanics = new Map<string, Json>((await db.query(`SELECT id, credit_balance FROM mechanics WHERE tenant_id = $1`, [tenantId])).map((r: Json) => [String(r.id), r]));
  const badMechanics = list(s.sa_mechanics).filter((m) => sat(dbMechanics.get(String(m.id))?.credit_balance ?? NaN) !== sat(m.creditBalance));
  row('mechanics whose credit_balance differs', 0, badMechanics.length);
  row('SUM(credit_payments.amount) satang', list(s.sa_credit_payments).reduce((t, p) => t + sat(p.amount), 0),
    Number((await one(`SELECT COALESCE(SUM(amount * 100), 0)::bigint AS v FROM credit_payments WHERE tenant_id = $1`)).v));

  // 6. The latest shift's drawer: starting_cash + in − out.
  // Never silently skipped: a file with no shift expects no shift in the DB.
  const latest = [...shifts].sort((a, b) => Date.parse(String(b.openedAt)) - Date.parse(String(a.openedAt)))[0];
  const drawer = (sh: Json) => sat(sh.startingCash) + list(sh.entries).reduce((t, e) => t + (e.type === 'in' ? 1 : -1) * sat(e.amount), 0);
  const d = await one(
    `SELECT s.date_str, s.starting_cash * 100
            + COALESCE((SELECT SUM(CASE WHEN e.type = 'in' THEN e.amount ELSE -e.amount END) * 100
                          FROM drawer_entries e WHERE e.tenant_id = s.tenant_id AND e.shift_id = s.id), 0) AS v
       FROM shifts s WHERE s.tenant_id = $1
      ORDER BY s.opened_at DESC LIMIT 1`,
  );
  row(
    'latest shift: date_str and drawer (starting_cash + in − out) satang',
    latest ? `${latest.date} ${drawer(latest)}` : 'no shift',
    d ? `${d.date_str} ${Number(d.v)}` : 'no shift',
  );
  return rows;
}
