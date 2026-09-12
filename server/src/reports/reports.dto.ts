import { BadRequestException } from '@nestjs/common';

export interface ReportDateRange {
  /** Local calendar day at which the range starts, inclusive. */
  from: string | null;
  /** Local calendar day immediately after the range, exclusive. */
  toExclusive: string | null;
}

/**
 * Reports use the same lexical keys as the Flutter client: `yyyy-MM-dd` and
 * `yyyy-MM`. The service converts these local calendar boundaries to instants
 * with the tenant's own timezone inside PostgreSQL.
 */
export function reportDateRange(
  fromRaw: string | undefined,
  toRaw: string | undefined,
): ReportDateRange {
  const from = fromRaw ? parseKey(fromRaw, 'from') : null;
  const to = toRaw ? parseKey(toRaw, 'to') : null;
  const start = from?.start ?? null;
  const toExclusive = to?.endExclusive ?? null;

  if (start && toExclusive && start >= toExclusive) {
    throw new BadRequestException('from must not be after to');
  }
  return { from: start, toExclusive };
}

function parseKey(
  raw: string,
  field: string,
): { start: string; endExclusive: string } {
  const day = /^(\d{4})-(\d{2})-(\d{2})$/.exec(raw);
  if (day) {
    const date = checkedDate(
      Number(day[1]),
      Number(day[2]),
      Number(day[3]),
      field,
    );
    return { start: raw, endExclusive: addUtcDays(date, 1) };
  }

  const month = /^(\d{4})-(\d{2})$/.exec(raw);
  if (month) {
    const year = Number(month[1]);
    const monthNumber = Number(month[2]);
    if (monthNumber < 1 || monthNumber > 12) invalidKey(field);
    const start = checkedDate(year, monthNumber, 1, field);
    return {
      start: formatDate(start),
      endExclusive: formatDate(new Date(Date.UTC(year, monthNumber, 1))),
    };
  }

  invalidKey(field);
}

function checkedDate(
  year: number,
  month: number,
  day: number,
  field: string,
): Date {
  const date = new Date(Date.UTC(year, month - 1, day));
  if (
    date.getUTCFullYear() !== year ||
    date.getUTCMonth() !== month - 1 ||
    date.getUTCDate() !== day
  ) {
    invalidKey(field);
  }
  return date;
}

function addUtcDays(date: Date, days: number): string {
  return formatDate(new Date(date.getTime() + days * 86_400_000));
}

function formatDate(date: Date): string {
  return date.toISOString().slice(0, 10);
}

function invalidKey(field: string): never {
  throw new BadRequestException(`${field} must be yyyy-MM-dd or yyyy-MM`);
}
