import { describe, expect, it } from 'vitest';
import { planTombstones, TOMBSTONE_MARK } from './snapshot-tombstones.js';

// #238 (owner decision 2026-09-15, option a): what a hard-deleted reference becomes.
describe('planTombstones', () => {
  it('names a product tombstone from the history that references it', () => {
    const plan = planTombstones({
      sa_products: [{ id: 'p-live' }],
      sa_movements: [
        { id: 'mv1', productId: 'p-gone', partNo: 'BP-9', name: 'Brake Pad', delta: 5 },
        { id: 'mv2', productId: 'p-live', partNo: 'X', name: 'x', delta: 1 },
      ],
      sa_sales: [{ id: 's1', items: [{ productId: 'p-gone', partNo: 'BP-9', name: 'Brake Pad', nameTH: 'ผ้าเบรก', qty: 1 }] }],
      sa_suppliers: [{ id: 'sp1', productId: 'p-gone' }],
    });
    expect(plan.products).toEqual([{ id: 'p-gone', partNo: 'BP-9', name: 'Brake Pad', nameTh: 'ผ้าเบรก' }]);
    expect(plan.unnamed).toEqual([]);
  });

  it('only tombstones references with a foreign key (a sale line alone needs none)', () => {
    const plan = planTombstones({ sa_sales: [{ id: 's1', items: [{ productId: 'p-gone', name: 'x', qty: 1 }] }] });
    expect(plan.products).toEqual([]);
  });

  it('names customers from bills and mechanics from bills or credit notes, marked by code', () => {
    const plan = planTombstones({
      sa_customers: [],
      sa_mechanics: [],
      sa_sales: [
        { id: 's1', customerId: 'c-gone', customerName: 'Test Customer', items: [] },
        { id: 's2', mechanicId: 'm-gone', mechanicName: null, items: [] },
      ],
      sa_returns: [{ id: 'r1', saleId: 's2', mechanicId: 'm-gone', mechanicName: 'Test Mechanic', items: [] }],
      sa_credit_payments: [{ id: 'cp1', mechanicId: 'm-gone', amount: 100 }],
    });
    expect(plan.customers).toEqual([{ id: 'c-gone', code: `${TOMBSTONE_MARK}:c-gone`, name: 'Test Customer' }]);
    expect(plan.mechanics).toEqual([{ id: 'm-gone', code: `${TOMBSTONE_MARK}:m-gone`, name: 'Test Mechanic' }]);
  });

  it('reports a reference with no usable name, and a credit note with no bill', () => {
    const plan = planTombstones({
      sa_mechanics: [],
      sa_credit_payments: [{ id: 'cp1', mechanicId: 'm-nameless', amount: 100 }],
      sa_movements: [{ id: 'mv1', productId: 'p-nameless', partNo: 'X-1', name: '  ' }],
      sa_sales: [],
      sa_returns: [{ id: 'r-orphan', saleId: 's-gone', items: [] }],
    });
    expect(plan.unnamed).toEqual(['products:p-nameless', 'mechanics:m-nameless']);
    expect(plan.returnsWithoutSale).toEqual(['r-orphan']);
    expect(plan.mechanics).toEqual([]);
  });

  // #252 review: the id side of every reference is read the same way whether the file uses
  // camelCase or snake_case — a mismatch there let a file pass pre-flight while the importer
  // inserted a different string and hit the foreign key it was supposed to catch.
  it('reads a required reference id from snake_case the same as camelCase', () => {
    const plan = planTombstones({
      sa_products: [{ id: 'p-live' }],
      sa_movements: [{ id: 'mv1', product_id: 'p-gone', partNo: 'BP-9', name: 'Brake Pad' }],
      sa_customers: [],
      sa_sales: [{ id: 's1', customer_id: 'c-gone', customerName: 'Test Customer', items: [] }],
    });
    expect(plan.products.map((p) => p.id)).toEqual(['p-gone']);
    expect(plan.customers).toEqual([{ id: 'c-gone', code: `${TOMBSTONE_MARK}:c-gone`, name: 'Test Customer' }]);
  });

  it('does not trim ids — a padded reference is a different id from the live one, not the same after trimming', () => {
    const plan = planTombstones({
      sa_products: [{ id: 'p1' }],
      sa_movements: [{ id: 'mv1', productId: 'p1 ', partNo: 'BP-1', name: 'Brake Pad' }],
    });
    expect(plan.products).toEqual([{ id: 'p1 ', partNo: 'BP-1', name: 'Brake Pad', nameTh: 'Brake Pad' }]);
  });

  it('refuses in pre-flight a row missing its own required reference id, never String(undefined)', () => {
    const plan = planTombstones({
      sa_movements: [{ id: 'mv-bad', name: 'x' }],
      sa_suppliers: [{ id: 'sp-bad' }],
      sa_credit_payments: [{ id: 'cp-bad', amount: 50 }],
    });
    expect(plan.missingRefs).toEqual(['movements:mv-bad', 'suppliers:sp-bad', 'creditPayments:cp-bad']);
  });

  // #252 (owner, 2026-09-15): a supplier price row for a product the file never stocked or
  // sold — added, priced, then hard-deleted — has no name anywhere to tombstone with. It is
  // dropped rather than forcing the whole import through the "no usable name" refusal.
  it('drops a supplier row for a product that is gone and otherwise unreferenced', () => {
    const plan = planTombstones({
      sa_products: [{ id: 'p-live' }],
      sa_suppliers: [{ id: 'sp1', productId: 'p-orphan' }],
    });
    expect(plan.droppedSuppliers).toEqual(['sp1']);
    expect(plan.products).toEqual([]);
    expect(plan.unnamed).toEqual([]);
  });

  it('keeps a supplier row when its product is tombstoned by a movement', () => {
    const plan = planTombstones({
      sa_products: [{ id: 'p-live' }],
      sa_movements: [{ id: 'mv1', productId: 'p-gone', partNo: 'BP-9', name: 'Brake Pad' }],
      sa_suppliers: [{ id: 'sp1', productId: 'p-gone' }],
    });
    expect(plan.droppedSuppliers).toEqual([]);
    expect(plan.products.map((p) => p.id)).toEqual(['p-gone']);
  });
});
