import { BadRequestException } from '@nestjs/common';

/**
 * Money crosses the wire as a string (`"1234.50"`, 02_API_SCREENS.md §1.1) and is
 * `NUMERIC` in Postgres. In between it is **integer satang** here — never a float,
 * because a bill is a sum of many lines and `0.1 + 0.2` is how a receipt total ends
 * up a satang off the paper the customer is holding.
 */
export function toSatang(value: unknown, field: string): number {
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw badMoney(field, value);
    return Math.round(value * 100);
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
