import { AsyncLocalStorage } from 'node:async_hooks';
import type { EntityManager } from 'typeorm';

/**
 * The per-request tenant and transaction that every tenant-scoped module reads.
 *
 * ADR-0003 makes `TenantGuard` (#4) the ONE component that checks `tenants.status`
 * and does `SET LOCAL app.tenant_id` — a separate tenant interceptor was considered
 * and rejected, because a route that forgot the guard would still get the GUC set
 * and read a suspended tenant's rows. Nothing else may set `app.tenant_id`.
 *
 * A guard cannot be the whole story, though: `canActivate` returns before the
 * handler runs, so it can neither hold this scope open across the handler nor commit
 * afterwards. The wiring #4 has to build is therefore a split, and ADR-0003 is
 * untouched by it because only the guard still touches the tenant:
 *
 *   middleware   `runInRequestContext({ tenantId, manager }, next)` — opens the
 *                transaction and the scope for the whole request
 *   TenantGuard  checks `tenants.status` and `SET LOCAL app.tenant_id` on that
 *                manager — the one component allowed to, per ADR-0003
 *   interceptor  commits on success, rolls back on error, before the response is sent
 *
 * Nothing in `src/` populates this yet: #4 is not built. A module that needs it
 * therefore fails closed — `currentRequestContext()` throws rather than guessing a
 * tenant — so no route can reach tenant data before the guard exists.
 * `test/idempotency.e2e-spec.ts` stands in for the whole chain.
 */
export interface RequestContext {
  /**
   * The tenant this request acts as. Already applied to `manager`'s connection as
   * `app.tenant_id`, so RLS is what actually enforces it; this copy is for writes
   * that must name the tenant in a column.
   */
  tenantId: string;
  /**
   * The request's transactional EntityManager. Every tenant-scoped read and write
   * goes through it, or it lands outside the transaction the guard opened — and
   * outside `SET LOCAL`, which is transaction-scoped, RLS sees no tenant at all.
   */
  manager: EntityManager;
}

const storage = new AsyncLocalStorage<RequestContext>();

/** Runs `fn` with `ctx` as the current request context. #4's TenantGuard calls this. */
export function runInRequestContext<T>(
  ctx: RequestContext,
  fn: () => Promise<T>,
): Promise<T> {
  return storage.run(ctx, fn);
}

/** The current request's context, or throws — never a silent default tenant. */
export function currentRequestContext(): RequestContext {
  const ctx = storage.getStore();
  if (!ctx) {
    throw new Error(
      'No request context. Tenant-scoped work must run inside runInRequestContext(), ' +
        'which TenantGuard (#4) establishes; this route ran without it.',
    );
  }
  return ctx;
}
