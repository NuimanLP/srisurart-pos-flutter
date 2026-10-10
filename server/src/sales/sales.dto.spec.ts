import { describe, expect, it } from 'vitest';
import { parseCreateSale, parseSaleQuoteId, replayPaymentAccountId } from './sales.dto.js';
import { testId } from '../../test/support/test-ids.js';

describe('parseCreateSale — paymentMethod', () => {
  /** A body that is otherwise valid, so only `paymentMethod` is under test. */
  const bodyWith = (paymentMethod: unknown) => ({
    id: testId('s1'),
    subtotal: '10.00',
    discount: '0.00',
    total: '10.00',
    paymentMethod,
    items: [{ productId: testId('p1'), name: 'x', qty: 1, price: '10.00' }],
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
    id: testId('s1'),
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
          { productId: testId('p1'), name: 'x', qty: 1, price: '1000.00' },
          { productId: testId('p1'), name: 'x', qty: 1, price: '-1000.00' },
        ]),
      ),
    ).toThrow(/items\[1\]\.price must not be negative/);
  });

  it('still accepts a zero-price line (a giveaway is not a refund)', () => {
    const sale = parseCreateSale(
      bodyWithLines([{ productId: testId('p1'), name: 'x', qty: 1, price: '0.00' }]),
    );
    expect(sale.items[0].priceSatang).toBe(0);
  });
});

describe('parseCreateSale — overrideCreditLimit', () => {
  const bodyWith = (overrideCreditLimit: unknown) => ({
    id: testId('s1'),
    subtotal: '10.00',
    discount: '0.00',
    total: '10.00',
    paymentMethod: 'เครดิตช่าง',
    mechanicId: testId('m1'),
    overrideCreditLimit,
    items: [{ productId: testId('p1'), name: 'x', qty: 1, price: '10.00' }],
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

describe('parseCreateSale — push-only fields (#411)', () => {
  it('never reads `date` or `soldOffline` from a body: only /sync/push sets them', () => {
    // 08 §10/§12: an online bill is dated by the server's now() and is never an
    // offline bill. A body carrying either — a skewed till clock, a crafted request —
    // must not backdate the bill or make it voidable through `sale.void_offline`.
    const sale = parseCreateSale({
      id: testId('s1'),
      subtotal: '10.00',
      discount: '0.00',
      total: '10.00',
      paymentMethod: 'เงินสด',
      items: [{ productId: testId('p1'), name: 'x', qty: 1, price: '10.00' }],
      date: '2020-01-01T00:00:00.000Z',
      soldOffline: true,
    });
    expect(sale).not.toHaveProperty('date');
    expect(sale).not.toHaveProperty('soldOffline');
  });
});

describe('quoteId (#27, owner 2026-10-03)', () => {
  const body = (quoteId: unknown) => ({
    id: testId('s1'),
    subtotal: '10.00',
    discount: '0.00',
    total: '10.00',
    paymentMethod: 'เงินสด',
    quoteId,
    items: [{ productId: testId('p1'), name: 'x', qty: 1, price: '10.00' }],
  });

  it('is read only by parseSaleQuoteId — parseCreateSale (also the /sync/push replay) ignores it', () => {
    expect(parseSaleQuoteId(body(testId('q1')))).toBe(testId('q1'));
    expect(parseCreateSale(body(testId('q1')))).not.toHaveProperty('quoteId');
  });

  it('is optional, and a non-string is a 400', () => {
    expect(parseSaleQuoteId(body(undefined))).toBeNull();
    expect(parseSaleQuoteId(body(null))).toBeNull();
    expect(() => parseSaleQuoteId(body(42))).toThrow(/quoteId must be a lowercase UUID/);
  });
});

describe('parseCreateSale — paymentAccountId (QR accounts, contract §3)', () => {
  const bodyWith = (extra: Record<string, unknown>) => ({
    id: testId('s1'),
    subtotal: '10.00',
    discount: '0.00',
    total: '10.00',
    paymentMethod: 'โอน/QR',
    items: [{ productId: testId('p1'), name: 'x', qty: 1, price: '10.00' }],
    ...extra,
  });

  it('is null when absent, null or empty', () => {
    expect(parseCreateSale(bodyWith({})).paymentAccountId).toBeNull();
    expect(parseCreateSale(bodyWith({ paymentAccountId: null })).paymentAccountId).toBeNull();
    expect(parseCreateSale(bodyWith({ paymentAccountId: '' })).paymentAccountId).toBeNull();
    // …on any method.
    expect(parseCreateSale(bodyWith({ paymentMethod: 'เงินสด', paymentAccountId: null })).paymentAccountId).toBeNull();
  });

  it('keeps a UUID on a โอน/QR bill', () => {
    expect(parseCreateSale(bodyWith({ paymentAccountId: testId('pa1') })).paymentAccountId).toBe(testId('pa1'));
  });

  it('refuses an account on any other payment method (400)', () => {
    for (const paymentMethod of ['เงินสด', 'เครดิตช่าง']) {
      expect(() => parseCreateSale(bodyWith({ paymentMethod, paymentAccountId: testId('pa1') }))).toThrow(
        /paymentAccountId is only allowed when paymentMethod is โอน\/QR/,
      );
    }
  });

  it('refuses a malformed id as INVALID_ID', () => {
    expect(() => parseCreateSale(bodyWith({ paymentAccountId: 'pa1' }))).toThrow(
      /paymentAccountId must be a lowercase UUID/,
    );
  });
});

describe('replayPaymentAccountId — a /sync/push replay never refuses for the account', () => {
  it('keeps a UUID on a โอน/QR bill', () => {
    expect(replayPaymentAccountId({ paymentMethod: 'โอน/QR', paymentAccountId: testId('pa1') })).toBe(testId('pa1'));
  });

  it('drops it to null on another method, a malformed id, or none', () => {
    expect(replayPaymentAccountId({ paymentMethod: 'เงินสด', paymentAccountId: testId('pa1') })).toBeNull();
    expect(replayPaymentAccountId({ paymentMethod: 'โอน/QR', paymentAccountId: 'pa1' })).toBeNull();
    expect(replayPaymentAccountId({ paymentMethod: 'โอน/QR', paymentAccountId: 42 })).toBeNull();
    expect(replayPaymentAccountId({ paymentMethod: 'โอน/QR' })).toBeNull();
  });
});
