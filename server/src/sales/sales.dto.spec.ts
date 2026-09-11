import { describe, expect, it } from 'vitest';
import { parseCreateSale } from './sales.dto.js';

describe('parseCreateSale — paymentMethod', () => {
  /** A body that is otherwise valid, so only `paymentMethod` is under test. */
  const bodyWith = (paymentMethod: unknown) => ({
    id: 's1',
    subtotal: '10.00',
    discount: '0.00',
    total: '10.00',
    paymentMethod,
    items: [{ productId: 'p1', name: 'x', qty: 1, price: '10.00' }],
  });

  it.each(['เงินสด', 'โอน/QR', 'เครดิตช่าง'])('accepts %s', (method) => {
    expect(parseCreateSale(bodyWith(method)).paymentMethod).toBe(method);
  });

  it('rejects a near-miss on เครดิตช่าง instead of silently recording a cash sale', () => {
    // This is the actual bug: one wrong character or a trailing space used to pass
    // `requiredString` and land in Postgres unrejected, so a credit sale could be
    // recorded as an unrecognised payment method with no CHECK to catch it.
    for (const bad of ['เครดิตช่าง ', ' เครดิตช่าง', 'เครดิตช่าง.', 'เครดิตชาง', 'เครดิต']) {
      expect(() => parseCreateSale(bodyWith(bad))).toThrow(
        /paymentMethod must be one of/,
      );
    }
  });

  it('rejects values that were never real, including the doc comment\'s old ones', () => {
    // '01_DATABASE.md' used to list 'โอน' and 'บัตร' as valid; neither screen has ever
    // produced them ('โอน/QR' is the real transfer literal, and 'บัตร' never existed).
    for (const bad of ['โอน', 'บัตร', 'PromptPay', 'โอนเงิน', 'cash', '', 'เครดิตช่าง1']) {
      expect(() => parseCreateSale(bodyWith(bad))).toThrow(
        /paymentMethod must be one of|paymentMethod is required/,
      );
    }
  });

  it('rejects a missing or non-string paymentMethod the same way as any other required field', () => {
    expect(() => parseCreateSale(bodyWith(undefined))).toThrow(
      /paymentMethod is required/,
    );
    expect(() => parseCreateSale(bodyWith(42))).toThrow(/paymentMethod is required/);
  });
});

describe('parseCreateSale — line price', () => {
  const bodyWithLines = (items: unknown[]) => ({
    id: 's1',
    subtotal: '0.00',
    discount: '0.00',
    total: '0.00',
    paymentMethod: 'เงินสด',
    items,
  });

  it('rejects a negative line price, which no total-level check can see', () => {
    // Two lines that cancel each other out: subtotal, discount and total are all
    // coherent, so `assertMoneyMakesSense` passes, but the bill still deducts 2 units
    // of stock and stores a negative `sale_items.price`.
    expect(() =>
      parseCreateSale(
        bodyWithLines([
          { productId: 'p1', name: 'x', qty: 1, price: '1000.00' },
          { productId: 'p1', name: 'x', qty: 1, price: '-1000.00' },
        ]),
      ),
    ).toThrow(/items\[1\]\.price must not be negative/);
  });

  it('still accepts a zero-price line (a giveaway is not a refund)', () => {
    const sale = parseCreateSale(
      bodyWithLines([{ productId: 'p1', name: 'x', qty: 1, price: '0.00' }]),
    );
    expect(sale.items[0].priceSatang).toBe(0);
  });
});

describe('parseCreateSale — overrideCreditLimit', () => {
  const bodyWith = (overrideCreditLimit: unknown) => ({
    id: 's1',
    subtotal: '10.00',
    discount: '0.00',
    total: '10.00',
    paymentMethod: 'เครดิตช่าง',
    mechanicId: 'm1',
    overrideCreditLimit,
    items: [{ productId: 'p1', name: 'x', qty: 1, price: '10.00' }],
  });

  it('defaults to false when absent, and keeps a real boolean', () => {
    expect(parseCreateSale(bodyWith(undefined)).overrideCreditLimit).toBe(
      false,
    );
    expect(parseCreateSale(bodyWith(null)).overrideCreditLimit).toBe(false);
    expect(parseCreateSale(bodyWith(false)).overrideCreditLimit).toBe(false);
    expect(parseCreateSale(bodyWith(true)).overrideCreditLimit).toBe(true);
  });

  it('rejects anything that is not a boolean — "false" is truthy and would confirm an override', () => {
    for (const bad of ['true', 'false', 1, 0, 'yes', {}]) {
      expect(() => parseCreateSale(bodyWith(bad))).toThrow(
        /overrideCreditLimit must be a boolean/,
      );
    }
  });
});
