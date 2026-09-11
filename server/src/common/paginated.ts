import { BadRequestException } from '@nestjs/common';

/** `meta` for a paginated response (02_API_SCREENS.md §1.2). */
export interface PaginationMeta {
  total: number;
  page: number;
  limit: number;
  totalPages: number;
}

/**
 * A page of results. `EnvelopeInterceptor` unwraps it into the envelope's `data` and
 * `meta` — §1.2 puts pagination in `meta`, beside `data`, not inside it.
 *
 * A class rather than a plain shape so the interceptor can recognise it without
 * guessing at object keys: a handler that genuinely returns `{ items, total }` as its
 * payload must not be silently reshaped.
 */
export class Paginated<T> {
  readonly meta: PaginationMeta;

  constructor(
    readonly items: T[],
    page: { total: number; page: number; limit: number },
  ) {
    this.meta = {
      total: page.total,
      page: page.page,
      limit: page.limit,
      totalPages: Math.max(1, Math.ceil(page.total / page.limit)),
    };
  }
}

/** `?page=1&limit=50`, capped at 200 (02_API_SCREENS.md §1.1). */
export const DEFAULT_LIMIT = 50;
export const MAX_LIMIT = 200;
/**
 * `page` needs a ceiling of its own. `limit` is clamped, but the `OFFSET
 * (page - 1) * limit` it feeds is not, so an unbounded page number makes Postgres
 * count past every row in the table only to return nothing.
 */
export const MAX_PAGE = 10_000;

export function positiveInt(
  raw: string | undefined,
  fallback: number,
  field: string,
): number {
  if (raw === undefined) return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1) {
    throw new BadRequestException(`${field} must be a positive integer`);
  }
  return n;
}

/** The `?page=&limit=` pair every list endpoint takes, bounded by both caps. */
export function pageParams(
  page: string | undefined,
  limit: string | undefined,
): { page: number; limit: number } {
  const p = positiveInt(page, 1, 'page');
  if (p > MAX_PAGE) {
    throw new BadRequestException(`page must not exceed ${MAX_PAGE}`);
  }
  return {
    page: p,
    limit: Math.min(positiveInt(limit, DEFAULT_LIMIT, 'limit'), MAX_LIMIT),
  };
}
