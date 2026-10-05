import { describe, expect, it } from 'vitest';
import { parseCreateCreditPayment } from './credit-payments.dto.js';
import { testId } from '../../test/support/test-ids.js';

describe('parseCreateCreditPayment', () => {
  const body = (over: Record<string, unknown> = {}) => ({
    amount: '500.00',
    paymentMethod: 'เงินสด',
    ...over,
  });

  it('reads the amount as satang and keeps the method verbatim', () => {
    const dto = parseCreateCreditPayment(body({ note: 'จ่ายงวดแรก' }));
    expect(dto.amountSatang).toBe(50_000);
    expect(dto.paymentMethod).toBe('เงินสด');
    expect(dto.note).toBe('จ่ายงวดแรก');
    expect(dto.allowOverpayment).toBe(false);
  });

  it.each(['เงินสด', 'โอน/QR'])('accepts %s', (method) => {
    expect(
      parseCreateCreditPayment(body({ paymentMethod: method })).paymentMethod,
    ).toBe(method);
  });

  it('refuses a missing method rather than assuming cash', () => {
    // The whole point of the column: a transfer counted as cash makes the closing
    // report show a shortfall the size of the transfer, every day.
    const { paymentMethod: _omitted, ...withoutMethod } = body();
    expect(() => parseCreateCreditPayment(withoutMethod)).toThrow(
      /paymentMethod is required/,
    );
  });

  it('refuses a near-miss on a method instead of recording an unknown one', () => {
    for (const bad of ['เงินสด ', 'โอน', 'โอน/qr', 'เครดิตช่าง', 'cash', '']) {
      expect(() =>
        parseCreateCreditPayment(body({ paymentMethod: bad })),
      ).toThrow(/paymentMethod must be one of|paymentMethod is required/);
    }
  });

  it('refuses an amount that is zero, negative, or not money', () => {
    // `credit_payments.amount` is CHECK (amount > 0): without this the row raises a
    // 23514 and surfaces as a 500, and a negative one would *raise* the tab.
    for (const bad of ['0', '0.00', '-100.00', -1, 0]) {
      expect(() => parseCreateCreditPayment(body({ amount: bad }))).toThrow(
        /amount must be greater than zero/,
      );
    }
    for (const bad of [undefined, null, '', 'abc', '1.005', {}]) {
      expect(() => parseCreateCreditPayment(body({ amount: bad }))).toThrow(
        /amount is required|amount must be an amount/,
      );
    }
  });

  it('takes the client id when sent, and refuses an empty or non-UUID one', () => {
    expect(parseCreateCreditPayment(body()).id).toBeNull();
    expect(parseCreateCreditPayment(body({ id: testId('cp-1') })).id).toBe(testId('cp-1'));
    for (const bad of ['', '  ', 42, 'cp-1', testId('cp-1').toUpperCase()]) {
      expect(() => parseCreateCreditPayment(body({ id: bad }))).toThrow(
        /id must be a lowercase UUID/,
      );
    }
  });

  it('treats an empty note as no note', () => {
    expect(parseCreateCreditPayment(body({ note: '' })).note).toBeNull();
    expect(parseCreateCreditPayment(body()).note).toBeNull();
  });

  it('takes allowOverpayment only as a real boolean', () => {
    expect(
      parseCreateCreditPayment(body({ allowOverpayment: true }))
        .allowOverpayment,
    ).toBe(true);
    // '"false"' is truthy in JS — a string here would confirm an overpayment the
    // counter was never shown a dialog for.
    for (const bad of ['true', 'false', 1, 0]) {
      expect(() =>
        parseCreateCreditPayment(body({ allowOverpayment: bad })),
      ).toThrow(/allowOverpayment must be a boolean/);
    }
  });

  it('rejects a body that is not an object', () => {
    for (const bad of [null, 'x', 42, [], undefined]) {
      expect(() => parseCreateCreditPayment(bad)).toThrow(
        /body must be an object/,
      );
    }
  });
});
