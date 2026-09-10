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
