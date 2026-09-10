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
