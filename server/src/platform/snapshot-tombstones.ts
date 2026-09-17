/**
 * #238 — tombstones for rows the shop hard-deleted but history still references.
 *
 * The Drift build has no foreign keys, and every delete is a hard delete. So a real backup
 * holds movements naming a product that is gone, bills naming a customer or mechanic that is
 * gone, and credit payments naming a mechanic that is gone. Postgres has a foreign key on
 * each of those references.
 *
 * Owner decision 2026-09-15, option (a): for every such id the import creates **one
 * soft-deleted row**. The row carries `deleted_at` = import time, the name history already
 * carries (`movements.name/part_no`, `sale_items.name/part_no`, `sales.customer_name`,
 * `sales.mechanic_name`, …) and zero totals. It is marked `import-tombstone` so it can be
 * told apart from a row the shop deleted on the server.
 *
 * A reference with no usable name anywhere in the file cannot become an honest tombstone,
 * and the pre-flight refuses it with the ids listed. A credit note whose bill is missing is
 * refused too (implementer's reasoning, never stated by the owner: inventing a bill would
 * invent money — see `01_DATABASE.md §9` / ADR-0005 addendum 3).
 *
 * Owner decision 2026-09-15 (#252 review): `suppliers.product_id` is also a Postgres FK, but a
 * supplier price row is not history — a product can be added with a supplier price and
 * hard-deleted before it is ever stocked or sold, leaving no name anywhere to tombstone with.
 * Such a row is **dropped**, not forced through the "no usable name" refusal; a supplier row
 * for a product that *is* tombstoned (a movement still names it) is kept.
 *
 * Pure: reads only the snapshot, so the import and the reconcile checks share one plan.
 */

/** The marker: `products.brand`, and the prefix of `customers.code` / `mechanics.code`. */
export const TOMBSTONE_MARK = 'import-tombstone';

export interface ProductTombstone {
  id: string;
  partNo: string;
  name: string;
  nameTh: string;
}

export interface PersonTombstone {
  id: string;
  code: string;
  name: string;
}

export interface TombstonePlan {
  products: ProductTombstone[];
  customers: PersonTombstone[];
  mechanics: PersonTombstone[];
  /** `table:id` references with no usable name anywhere in the file. */
  unnamed: string[];
  /** Credit notes whose bill is not in the file (`returns.sale_id` → `sales`). */
  returnsWithoutSale: string[];
  /**
   * Supplier rows whose product is gone and not otherwise tombstoned (no movement names it
   * either) — dropped, never forced through `unnamed` (#252, owner 2026-09-15).
   */
  droppedSuppliers: string[];
  /**
   * `table:rowId` rows whose own required (NOT NULL in Postgres) reference id is missing or
   * empty in the file — refused here, with the row's own id, instead of `String(undefined)`
   * reaching an INSERT and either matching the wrong row or dying as a 500 (#252 review).
   */
  missingRefs: string[];
}

type Row = Record<string, unknown>;

const rows = (v: unknown): Row[] =>
  Array.isArray(v) ? (v as unknown[]).filter((x): x is Row => !!x && typeof x === 'object') : [];

/** Trimmed display text — for names, not ids: whitespace-only is "no name". */
const text = (v: unknown): string | null => {
  if (v == null) return null;
  const s = String(v).trim();
  return s === '' ? null : s;
};

/**
 * The shared reference-id accessor: the planner and the importer must read the exact same
 * value for the exact same field, or a file that uses snake_case keys (or a padded id) can
 * pass pre-flight as "present" while the importer inserts a different string — the foreign
 * key violation pre-flight exists to catch, surfacing instead as a mid-transaction 500 (#252
 * review). No trim, on either side: an id is either the exact bytes it is, or a different id.
 */
export function fieldId(row: Row, camelKey: string, snakeKey: string): string | null {
  const v = row[camelKey] ?? row[snakeKey];
  if (v == null) return null;
  const s = String(v);
  return s === '' ? null : s;
}

/** Every id in `ids` the file does not contain, in first-seen order. `null` (absent) needs none. */
function missing(ids: Iterable<string | null>, present: Set<string>): string[] {
  const out = new Set<string>();
  for (const id of ids) if (id != null && !present.has(id)) out.add(id);
  return [...out];
}

/** The one row-count summary of a plan's tombstones, shared by the importer's audit/response
 * and the pre-flight reconcile report — never computed twice, differently. */
export function countTombstones(plan: TombstonePlan): { products: number; customers: number; mechanics: number } {
  return {
    products: plan.products.length,
    customers: plan.customers.length,
    mechanics: plan.mechanics.length,
  };
}

export function planTombstones(snapshot: Row): TombstonePlan {
  const products = rows(snapshot.sa_products);
  const customers = rows(snapshot.sa_customers);
  const mechanics = rows(snapshot.sa_mechanics);
  const sales = rows(snapshot.sa_sales);
  const returns = rows(snapshot.sa_returns);
  const movements = rows(snapshot.sa_movements);
  const suppliers = rows(snapshot.sa_suppliers);
  const payments = rows(snapshot.sa_credit_payments);
  const quotes = rows(snapshot.sa_quotes);

  const unnamed: string[] = [];
  const missingRefs: string[] = [];
  const rowId = (r: Row) => text(r.id) ?? '?';

  // Rows whose own required (NOT NULL) reference id is absent: refused with the row's own id,
  // instead of `String(undefined)` reaching an INSERT.
  for (const m of movements) if (fieldId(m, 'productId', 'product_id') == null) missingRefs.push(`movements:${rowId(m)}`);
  for (const sup of suppliers) if (fieldId(sup, 'productId', 'product_id') == null) missingRefs.push(`suppliers:${rowId(sup)}`);
  for (const p of payments) if (fieldId(p, 'mechanicId', 'mechanic_id') == null) missingRefs.push(`creditPayments:${rowId(p)}`);

  // Products: referenced by movements (the FK Postgres enforces for a tombstone). Names come
  // from every place a product's name was copied: movements and sale/return/quote lines carry
  // part_no too.
  const productIds = new Set(products.map((p) => String(p.id)));
  const productNames = new Map<string, { partNo: string | null; name: string | null; nameTh: string | null }>();
  const learnProduct = (id: string | null, partNo: unknown, name: unknown, nameTh: unknown) => {
    if (id == null || productIds.has(id)) return;
    const known = productNames.get(id) ?? { partNo: null, name: null, nameTh: null };
    productNames.set(id, {
      partNo: known.partNo ?? text(partNo),
      name: known.name ?? text(name),
      nameTh: known.nameTh ?? text(nameTh),
    });
  };
  for (const m of movements) learnProduct(fieldId(m, 'productId', 'product_id'), m.partNo, m.name, null);
  for (const s of sales) for (const i of rows(s.items)) learnProduct(fieldId(i, 'productId', 'product_id'), i.partNo, i.name, i.nameTH);
  for (const r of returns) for (const i of rows(r.items)) learnProduct(fieldId(i, 'productId', 'product_id'), null, i.name, null);
  for (const q of quotes) for (const i of rows(q.items)) learnProduct(fieldId(i, 'productId', 'product_id'), null, i.name, null);

  // Only movements force a product tombstone (or an `unnamed` refusal) — a sale/return/quote
  // line alone needs none (no FK), and neither does a supplier row (#252, below).
  const productTombstones: ProductTombstone[] = [];
  const tombstonedProductIds = new Set<string>();
  for (const id of missing(movements.map((m) => fieldId(m, 'productId', 'product_id')), productIds)) {
    const n = productNames.get(id);
    if (!n?.name) {
      unnamed.push(`products:${id}`);
      continue;
    }
    productTombstones.push({ id, partNo: n.partNo ?? id, name: n.name, nameTh: n.nameTh ?? n.name });
    tombstonedProductIds.add(id);
  }

  // Suppliers (#252, owner 2026-09-15): a price row for a product neither live nor tombstoned
  // is dropped, not forced through `unnamed` — a supplier price is not history, and refusing
  // the whole import over a deleted product's price list is worse than dropping the row. A
  // supplier row for a product a movement still tombstones is kept.
  const droppedSuppliers: string[] = [];
  for (const sup of suppliers) {
    const pid = fieldId(sup, 'productId', 'product_id');
    if (pid == null) continue; // already in missingRefs
    if (productIds.has(pid) || tombstonedProductIds.has(pid)) continue;
    droppedSuppliers.push(rowId(sup));
  }

  // Returns its own unnamed ids rather than reaching into the outer `unnamed` array — the
  // caller decides where they land (#252 review).
  const people = (
    table: 'customers' | 'mechanics',
    present: Row[],
    refs: Array<string | null>,
    names: Array<[string | null, unknown]>,
  ): { tombstones: PersonTombstone[]; unnamed: string[] } => {
    const ids = new Set(present.map((x) => String(x.id)));
    const nameOf = new Map<string, string>();
    for (const [id, name] of names) {
      const value = text(name);
      if (id != null && value != null && !nameOf.has(id)) nameOf.set(id, value);
    }
    const tombstonesOut: PersonTombstone[] = [];
    const unnamedOut: string[] = [];
    for (const id of missing(refs, ids)) {
      const name = nameOf.get(id);
      if (!name) {
        unnamedOut.push(`${table}:${id}`);
        continue;
      }
      tombstonesOut.push({ id, code: `${TOMBSTONE_MARK}:${id}`, name });
    }
    return { tombstones: tombstonesOut, unnamed: unnamedOut };
  };

  const customersResult = people(
    'customers',
    customers,
    sales.map((s) => fieldId(s, 'customerId', 'customer_id')),
    sales.map((s): [string | null, unknown] => [fieldId(s, 'customerId', 'customer_id'), s.customerName]),
  );
  const mechanicsResult = people(
    'mechanics',
    mechanics,
    [...sales.map((s) => fieldId(s, 'mechanicId', 'mechanic_id')), ...payments.map((p) => fieldId(p, 'mechanicId', 'mechanic_id'))],
    [
      ...sales.map((s): [string | null, unknown] => [fieldId(s, 'mechanicId', 'mechanic_id'), s.mechanicName]),
      ...returns.map((r): [string | null, unknown] => [fieldId(r, 'mechanicId', 'mechanic_id'), r.mechanicName]),
    ],
  );
  const customerTombstones = customersResult.tombstones;
  const mechanicTombstones = mechanicsResult.tombstones;
  unnamed.push(...customersResult.unnamed, ...mechanicsResult.unnamed);

  const saleIds = new Set(sales.map((s) => String(s.id)));
  const returnsWithoutSale = returns
    .filter((r) => {
      const sid = fieldId(r, 'saleId', 'sale_id');
      return sid == null || !saleIds.has(sid);
    })
    .map((r) => rowId(r));

  return {
    products: productTombstones,
    customers: customerTombstones,
    mechanics: mechanicTombstones,
    unnamed,
    returnsWithoutSale,
    droppedSuppliers,
    missingRefs,
  };
}
