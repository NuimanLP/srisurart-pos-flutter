import { BadRequestException } from '@nestjs/common';

/**
 * Money crosses the wire as a string (`"1234.50"`, 02_API_SCREENS.md §1.1) and is
 * `NUMERIC` in Postgres. In between it is **integer satang** here — never a float,
 * because a bill is a sum of many lines and `0.1 + 0.2` is how a receipt total ends
 * up a satang off the paper the customer is holding.
 */
export function toSatang(value: unknown, field: string): number {
  const satang = parse(value, field);
  // `NUMERIC(12,2)` is the widest money column in the schema; anything past it is a
  // `22003` from Postgres several statements later, which surfaces as a 500 instead
  // of the 400 a nonsense amount deserves.
  if (Math.abs(satang) > MAX_SATANG) throw badMoney(field, value);
  return satang;
}

/** `NUMERIC(12,2)` — ten digits before the point. */
const MAX_SATANG = 9_999_999_999_99;

function parse(value: unknown, field: string): number {
  if (typeof value === 'number') {
    // The wire format is a string (§1.1); a number is accepted because clients send
    // them, but under the same two-decimal rule — otherwise `1.005` rounds silently
    // where `"1.005"` is a 400, and the two callers disagree about the same amount.
    if (!Number.isFinite(value)) throw badMoney(field, value);
    const satang = value * 100;
    if (Math.abs(satang - Math.round(satang)) > 1e-6)
      throw badMoney(field, value);
    return Math.round(satang);
  }
  if (typeof value === 'string' && /^-?\d+(\.\d{1,2})?$/.test(value.trim())) {
    return Math.round(Number(value.trim()) * 100);
  }
  throw badMoney(field, value);
}

/** Back to the wire/DB shape: `"1234.50"`. */
export function fromSatang(satang: number): string {
  const sign = satang < 0 ? '-' : '';
  const abs = Math.abs(satang);
  return `${sign}${Math.trunc(abs / 100)}.${String(abs % 100).padStart(2, '0')}`;
}

/**
 * Loyalty points: `floor(total / 10)` (`money.dart` `pointsFor`), computed from the
 * total actually persisted so it cannot drift from what the bill says.
 */
export function pointsFor(totalSatang: number): number {
  return Math.floor(totalSatang / 1000);
}

function badMoney(field: string, value: unknown): BadRequestException {
  return new BadRequestException(
    `${field} must be an amount with at most two decimals, got ${JSON.stringify(value)}`,
  );
}
