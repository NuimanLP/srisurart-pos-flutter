import { describe, expect, it } from 'vitest';
import { fromSatang, pointsFor, toSatang } from './money.js';

describe('money', () => {
  it('parses the wire format into satang', () => {
    expect(toSatang('1234.50', 'total')).toBe(123450);
    expect(toSatang('0.05', 'total')).toBe(5);
    expect(toSatang('100', 'total')).toBe(10000);
    expect(toSatang(-12.5, 'delta')).toBe(-1250);
  });

  it('refuses anything that is not an amount', () => {
    for (const bad of ['1.234', 'abc', '', null, undefined, {}, NaN, Infinity]) {
      expect(() => toSatang(bad, 'total')).toThrow();
    }
  });

  it('round-trips through the wire format', () => {
    expect(fromSatang(123450)).toBe('1234.50');
    expect(fromSatang(5)).toBe('0.05');
    expect(fromSatang(0)).toBe('0.00');
    expect(fromSatang(-1250)).toBe('-12.50');
  });

  it('adds lines without the float drift a receipt would show', () => {
    const lines = Array.from({ length: 10 }, () => toSatang('0.10', 'price'));
    expect(fromSatang(lines.reduce((a, b) => a + b, 0))).toBe('1.00');
  });

  it('grants one point per ten baht, floored (money.dart pointsFor)', () => {
    expect(pointsFor(toSatang('255.00', 't'))).toBe(25);
    expect(pointsFor(toSatang('1400.00', 't'))).toBe(140);
    expect(pointsFor(toSatang('9.99', 't'))).toBe(0);
  });
});
