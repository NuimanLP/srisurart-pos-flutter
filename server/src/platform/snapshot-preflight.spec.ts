import { describe, expect, it } from 'vitest';
import { planClampViolations, planDuplicateDocNumbers, planUnparseableDates } from './snapshot-preflight.js';

// #239 AC 1-3: each pre-flight gap gets its own unit test, on the pure scan alone.
describe('planDuplicateDocNumbers', () => {
  it('names two sales that share a receipt number, with both ids', () => {
    const out = planDuplicateDocNumbers({
      sa_sales: [
        { id: 's1', receiptNo: 'RC01-2569-01-0001' },
        { id: 's2', receiptNo: 'RC01-2569-01-0001' },
      ],
    });
    expect(out).toEqual([{ table: 'sales', field: 'receiptNo', value: 'RC01-2569-01-0001', ids: ['s1', 's2'] }]);
  });

  it('never flags two different ids that both omit the number (their fallbacks differ)', () => {
    const out = planDuplicateDocNumbers({ sa_sales: [{ id: 's1' }, { id: 's2' }] });
    expect(out).toEqual([]);
  });

  it('a repeated id with the same number is one row twice, not a duplicate', () => {
    const out = planDuplicateDocNumbers({
      sa_sales: [
        { id: 's1', receiptNo: 'RC01-2569-01-0001' },
        { id: 's1', receiptNo: 'RC01-2569-01-0001' },
      ],
    });
    expect(out).toEqual([]);
  });

  it('checks returns, purchase orders, quotes and credit payments independently', () => {
    const out = planDuplicateDocNumbers({
      sa_returns: [{ id: 'r1', cnNo: 'CN1' }, { id: 'r2', cnNo: 'CN1' }],
      sa_pos: [{ id: 'po1', poNo: 'PO1' }, { id: 'po2', poNo: 'PO1' }],
      sa_quotes: [{ id: 'q1', quoteNo: 'QT1' }, { id: 'q2', quoteNo: 'QT1' }],
      sa_credit_payments: [{ id: 'cp1', receiptNo: 'CP1' }, { id: 'cp2', receiptNo: 'CP1' }],
    });
    expect(out.map((d) => d.table)).toEqual(['returns', 'purchaseOrders', 'quotes', 'creditPayments']);
  });

  it('a sale and a credit payment sharing the same receipt number is not a collision (different tables)', () => {
    const out = planDuplicateDocNumbers({
      sa_sales: [{ id: 's1', receiptNo: 'X-1' }],
      sa_credit_payments: [{ id: 'cp1', receiptNo: 'X-1' }],
    });
    expect(out).toEqual([]);
  });
});

describe('planUnparseableDates', () => {
  it('flags a sale date that does not parse', () => {
    const out = planUnparseableDates({ sa_sales: [{ id: 's1', date: 'not-a-date' }] });
    expect(out).toEqual([{ table: 'sales', id: 's1', field: 'date', value: 'not-a-date' }]);
  });

  it('never flags an absent date — the importer defaults it, no error', () => {
    const out = planUnparseableDates({ sa_sales: [{ id: 's1' }], sa_customers: [{ id: 'c1' }] });
    expect(out).toEqual([]);
  });

  it('flags an unparseable deletedAt on a customer or mechanic', () => {
    const out = planUnparseableDates({
      sa_customers: [{ id: 'c1', deletedAt: 'yesterday-ish' }],
      sa_mechanics: [{ id: 'm1', deleted_at: 'ยังไม่ลบ' }],
    });
    expect(out).toEqual([
      { table: 'customers', id: 'c1', field: 'deletedAt', value: 'yesterday-ish' },
      { table: 'mechanics', id: 'm1', field: 'deletedAt', value: 'ยังไม่ลบ' },
    ]);
  });

  it('checks a shift by its date label (shifts carry no id) and its nested drawer entries', () => {
    const out = planUnparseableDates({
      sa_cash_drawer: { date: '2026-06-01', openedAt: 'not-a-date' },
      sa_shift_history: [{ date: '2026-05-31', closedAt: 'ไม่ใช่วันที่', entries: [{ id: 'de1', createdAt: '0000-99-99' }] }],
    });
    expect(out).toEqual([
      { table: 'shifts', id: '2026-06-01', field: 'openedAt', value: 'not-a-date' },
      { table: 'shifts', id: '2026-05-31', field: 'closedAt', value: 'ไม่ใช่วันที่' },
      { table: 'drawerEntries', id: '2026-05-31:de1', field: 'createdAt', value: '0000-99-99' },
    ]);
  });

  it('accepts a real ISO date string, the shape every export writes', () => {
    const out = planUnparseableDates({ sa_sales: [{ id: 's1', date: '2026-06-01T00:00:00.000Z' }] });
    expect(out).toEqual([]);
  });
});

describe('planClampViolations', () => {
  it('refuses a negative mechanic credit balance instead of letting it clamp to zero', () => {
    const out = planClampViolations({ sa_mechanics: [{ id: 'm1', creditBalance: -50 }] });
    expect(out).toEqual([{ table: 'mechanics', id: 'm1', field: 'creditBalance', value: -50, rule: 'must be ≥ 0' }]);
  });

  it('refuses negative customer points and a negative product minStock', () => {
    const out = planClampViolations({
      sa_customers: [{ id: 'c1', points: -1 }],
      sa_products: [{ id: 'p1', minStock: -2 }],
    });
    expect(out).toEqual([
      { table: 'products', id: 'p1', field: 'minStock', value: -2, rule: 'must be ≥ 0' },
      { table: 'customers', id: 'c1', field: 'points', value: -1, rule: 'must be ≥ 0' },
    ]);
  });

  it('never flags an absent balance/points/minStock — the importer defaults it to zero', () => {
    const out = planClampViolations({ sa_mechanics: [{ id: 'm1' }], sa_customers: [{ id: 'c1' }], sa_products: [{ id: 'p1' }] });
    expect(out).toEqual([]);
  });

  it('refuses a sale line qty of zero, negative, non-integer or missing — all of which used to silently become 1', () => {
    const out = planClampViolations({
      sa_sales: [{ id: 's1', items: [{ qty: 0 }, { qty: -1 }, { qty: 1.5 }, {}, { qty: 2 }] }],
    });
    expect(out).toEqual([
      { table: 'saleItems', id: 's1:1', field: 'qty', value: 0, rule: 'must be a positive whole number' },
      { table: 'saleItems', id: 's1:2', field: 'qty', value: -1, rule: 'must be a positive whole number' },
      { table: 'saleItems', id: 's1:3', field: 'qty', value: 1.5, rule: 'must be a positive whole number' },
      { table: 'saleItems', id: 's1:4', field: 'qty', value: null, rule: 'must be a positive whole number' },
    ]);
  });

  it('checks return, PO and quote line qty the same way', () => {
    const out = planClampViolations({
      sa_returns: [{ id: 'r1', items: [{ qty: 0 }] }],
      sa_pos: [{ id: 'po1', items: [{ qty: -1 }] }],
      sa_quotes: [{ id: 'q1', items: [{ qty: 'many' }] }],
    });
    expect(out.map((c) => c.table)).toEqual(['returnItems', 'poItems', 'quoteItems']);
  });

  it('refuses a non-positive settings.quoteValidDays but accepts an absent one', () => {
    expect(planClampViolations({ sa_settings: { quoteValidDays: 0 } })).toEqual([
      { table: 'settings', id: '-', field: 'quoteValidDays', value: 0, rule: 'must be a positive whole number' },
    ]);
    expect(planClampViolations({ sa_settings: { shopName: 'x' } })).toEqual([]);
  });

  // #239 review issue 3: `round2()` in `tenant-import.service.ts` turned a present-but-
  // unparseable money value into a silent 0 — no clamp rule caught it. `finite` refuses any
  // such value; `nonNegMoney`/`positiveMoney` add the stricter rule on the fields Postgres
  // itself `CHECK`s (`1788652800000-InitialSchema.ts`: products.price/cost,
  // po_items.cost >= 0; credit_payments.amount, drawer_entries.amount > 0).
  it('refuses a sale total that does not parse as a number', () => {
    const out = planClampViolations({ sa_sales: [{ id: 's1', total: 'corrupt' }] });
    expect(out).toEqual([{ table: 'sales', id: 's1', field: 'total', value: 'corrupt', rule: 'must be a finite number' }]);
  });

  it('never flags an absent sale subtotal/discount/total/mechanicDelta — the importer defaults them', () => {
    expect(planClampViolations({ sa_sales: [{ id: 's1' }] })).toEqual([]);
  });

  it('accepts a negative mechanicDelta (a mechanic discount is negative by design)', () => {
    expect(planClampViolations({ sa_sales: [{ id: 's1', mechanicDelta: -25 }] })).toEqual([]);
  });

  it('refuses a negative product price/cost, not just a non-finite one', () => {
    const out = planClampViolations({ sa_products: [{ id: 'p1', price: -1, cost: 'x' }] });
    expect(out).toEqual([
      { table: 'products', id: 'p1', field: 'price', value: -1, rule: 'must be ≥ 0' },
      { table: 'products', id: 'p1', field: 'cost', value: 'x', rule: 'must be a finite number' },
    ]);
  });

  it('refuses a credit payment amount that is zero, negative or unparseable (Postgres CHECK amount > 0)', () => {
    expect(planClampViolations({ sa_credit_payments: [{ id: 'cp1', amount: 0 }] })).toEqual([
      { table: 'creditPayments', id: 'cp1', field: 'amount', value: 0, rule: 'must be > 0' },
    ]);
    expect(planClampViolations({ sa_credit_payments: [{ id: 'cp2', amount: 'NaN' }] })).toEqual([
      { table: 'creditPayments', id: 'cp2', field: 'amount', value: 'NaN', rule: 'must be a finite number' },
    ]);
  });

  it('refuses an unparseable supplier unitCost/freight, a customer totalSpend and a mechanic running total', () => {
    expect(planClampViolations({ sa_suppliers: [{ id: 'sup1', unitCost: 'x', freight: 'y' }] })).toEqual([
      { table: 'suppliers', id: 'sup1', field: 'unitCost', value: 'x', rule: 'must be a finite number' },
      { table: 'suppliers', id: 'sup1', field: 'freight', value: 'y', rule: 'must be a finite number' },
    ]);
    expect(planClampViolations({ sa_customers: [{ id: 'c1', totalSpend: 'x' }] })).toEqual([
      { table: 'customers', id: 'c1', field: 'totalSpend', value: 'x', rule: 'must be a finite number' },
    ]);
    expect(planClampViolations({ sa_mechanics: [{ id: 'm1', totalDiscount: 'x' }] })).toEqual([
      { table: 'mechanics', id: 'm1', field: 'totalDiscount', value: 'x', rule: 'must be a finite number' },
    ]);
  });

  it('refuses an unparseable return refund total and a return/sale/quote line price', () => {
    expect(planClampViolations({ sa_returns: [{ id: 'r1', refundTotal: 'x', items: [{ qty: 1, price: 'y' }] }] })).toEqual([
      { table: 'returns', id: 'r1', field: 'refundTotal', value: 'x', rule: 'must be a finite number' },
      { table: 'returnItems', id: 'r1:1', field: 'price', value: 'y', rule: 'must be a finite number' },
    ]);
  });

  it('refuses a negative or unparseable PO line cost (Postgres CHECK cost >= 0)', () => {
    const out = planClampViolations({ sa_pos: [{ id: 'po1', items: [{ qty: 1, cost: -5 }] }] });
    expect(out).toEqual([{ table: 'poItems', id: 'po1:1', field: 'cost', value: -5, rule: 'must be ≥ 0' }]);
  });

  it('refuses an unparseable shift startingCash/physicalCash and a non-positive drawer entry amount', () => {
    const out = planClampViolations({
      sa_cash_drawer: { date: '2026-06-01', startingCash: 'x' },
      sa_shift_history: [{ date: '2026-05-31', physicalCash: 'y', entries: [{ id: 'de1', amount: 0 }] }],
    });
    expect(out).toEqual([
      { table: 'shifts', id: '2026-06-01', field: 'startingCash', value: 'x', rule: 'must be a finite number' },
      { table: 'shifts', id: '2026-05-31', field: 'physicalCash', value: 'y', rule: 'must be a finite number' },
      { table: 'drawerEntries', id: '2026-05-31:de1', field: 'amount', value: 0, rule: 'must be > 0' },
    ]);
  });

  it('refuses an unparseable settings.taxRate but accepts an absent one', () => {
    expect(planClampViolations({ sa_settings: { taxRate: 'x' } })).toEqual([
      { table: 'settings', id: '-', field: 'taxRate', value: 'x', rule: 'must be a finite number' },
    ]);
    expect(planClampViolations({ sa_settings: { shopName: 'x' } })).toEqual([]);
  });
});
