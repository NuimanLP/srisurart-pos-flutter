import { BadRequestException } from '@nestjs/common';
import {
  parseQuoteConvert,
  parseQuoteCreate,
  parseQuoteFilter,
  parseQuotePatch,
  parsePurgeOlderThanDays,
} from './quotes.dto.js';

const body = (over: Record<string, unknown> = {}) => ({
  subtotal: '150.00',
  total: '150.00',
  items: [{ productId: 'p1', name: 'x', qty: 1, price: '150.00' }],
  ...over,
});

describe('parseQuoteCreate', () => {
  it('reads a Checkout quote, defaulting discount and keeping an empty customer name', () => {
    const q = parseQuoteCreate(body({ customerName: '' }));
    expect(q.discountSatang).toBe(0);
    expect(q.customerName).toBe('');
    expect(q.validDays).toBeNull();
    expect(q.items[0]).toEqual({
      lineNo: 1,
      productId: 'p1',
      name: 'x',
      qty: 1,
      priceSatang: 15000,
    });
  });

  it('keeps a line with no product as null', () => {
    const q = parseQuoteCreate(
      body({ items: [{ name: 'special', qty: 1, price: '150.00' }] }),
    );
    expect(q.items[0].productId).toBeNull();
  });

  it.each([
    ['no lines', { items: [] }],
    ['a negative price', { items: [{ name: 'x', qty: 1, price: '-1.00' }] }],
    ['a zero qty', { items: [{ name: 'x', qty: 0, price: '1.00' }] }],
    ['a discount past the subtotal', { discount: '200.00' }],
    ['validDays of 0', { validDays: 0 }],
    ['a converted status', { status: 'converted' }],
  ])('refuses %s', (_label, over) => {
    expect(() => parseQuoteCreate(body(over))).toThrow(BadRequestException);
  });
});

describe('parseQuotePatch', () => {
  it('takes header text only', () => {
    expect(parseQuotePatch({ notes: 'n', customerPhone: null })).toEqual({
      notes: 'n',
      customerPhone: null,
    });
  });

  it.each(['status', 'convertedSaleId', 'items', 'total'])(
    'refuses %s',
    (field) => {
      expect(() => parseQuotePatch({ [field]: 'x' })).toThrow(
        BadRequestException,
      );
    },
  );
});

describe('parseQuoteConvert', () => {
  it('reads the sale party', () => {
    expect(
      parseQuoteConvert({ id: 's1', paymentMethod: 'เงินสด' }),
    ).toMatchObject({
      id: 's1',
      paymentMethod: 'เงินสด',
      overrideCreditLimit: false,
    });
  });

  it('refuses lines or money in the body', () => {
    expect(() =>
      parseQuoteConvert({ id: 's1', paymentMethod: 'เงินสด', items: [] }),
    ).toThrow(BadRequestException);
  });
});

describe('parseQuoteFilter', () => {
  it('maps all and blank to no filter, and refuses anything else', () => {
    expect(parseQuoteFilter('all')).toBeUndefined();
    expect(parseQuoteFilter(undefined)).toBeUndefined();
    expect(parseQuoteFilter('expired')).toBe('expired');
    expect(() => parseQuoteFilter('cancelled')).toThrow(BadRequestException);
  });
});

describe('parsePurgeOlderThanDays', () => {
  it('defaults to 90 when the body or the field is absent', () => {
    expect(parsePurgeOlderThanDays(undefined)).toBe(90);
    expect(parsePurgeOlderThanDays({})).toBe(90);
    expect(parsePurgeOlderThanDays({ olderThanDays: null })).toBe(90);
  });

  it('passes a valid integer through unchanged', () => {
    expect(parsePurgeOlderThanDays({ olderThanDays: 1 })).toBe(1);
    expect(parsePurgeOlderThanDays({ olderThanDays: 30 })).toBe(30);
    expect(parsePurgeOlderThanDays({ olderThanDays: 36_500 })).toBe(36_500);
  });

  it.each([
    ['a word', 'abc'],
    ['a numeric string', '30'],
    ['NaN', Number.NaN],
    ['zero', 0],
    ['a negative', -5],
    ['a fraction', 1.5],
    ['past the int-safe cap', 36_501],
    ['Infinity', Number.POSITIVE_INFINITY],
  ])('refuses %s with 400 instead of clamping it', (_label, olderThanDays) => {
    expect(() => parsePurgeOlderThanDays({ olderThanDays })).toThrow(
      BadRequestException,
    );
  });

  it('refuses a body that is not an object', () => {
    expect(() => parsePurgeOlderThanDays([])).toThrow(BadRequestException);
  });
});
