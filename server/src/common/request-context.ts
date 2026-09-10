import { AsyncLocalStorage } from 'node:async_hooks';
import type { EntityManager } from 'typeorm';

/**
 * The per-request tenant and transaction that every tenant-scoped module reads.
 *
 * ADR-0003 makes `TenantGuard` the ONE component that checks `tenants.status`
 * and does `SET LOCAL app.tenant_id` — a separate tenant interceptor was considered
 * and rejected, because a route that forgot the guard would still get the GUC set
 * and read a suspended tenant's rows. Nothing else may set `app.tenant_id`.
 *
 * A guard cannot be the whole story, though: `canActivate` returns before the
 * handler runs, so it can neither hold this scope open across the handler nor commit
 * afterwards. The wiring is therefore a split, and ADR-0003 is untouched by it
 * because only the guard still touches the tenant:
 *
 *   RequestContextMiddleware  opens the transaction and this scope for the whole request
 *   TenantGuard               checks `tenants.status` and `SET LOCAL app.tenant_id` on
 *                             that manager — the one component allowed to, per ADR-0003
 *   TransactionInterceptor    commits on success, rolls back on error, before the
 *                             response is sent
 *
 * `currentRequestContext()` fails closed twice over: outside the scope, and inside it
 * before the guard has named a tenant. A route that forgot the guard therefore cannot
 * reach tenant data — it gets an exception, not someone else's rows.
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
   * goes through it, or it lands outside the transaction the middleware opened — and
   * outside `SET LOCAL`, which is transaction-scoped, RLS sees no tenant at all.
   */
  manager: EntityManager;
}

/** What the middleware opens: a transaction with no tenant named on it yet. */
interface MutableRequestContext {
  tenantId: string | null;
  manager: EntityManager;
}

const storage = new AsyncLocalStorage<MutableRequestContext>();

/**
 * Runs `fn` with a fresh request scope carrying `manager`'s transaction.
 * `RequestContextMiddleware` calls this; the tenant is named later, by the guard.
 */
export function runInRequestContext<T>(
  ctx: { tenantId?: string; manager: EntityManager },
  fn: () => Promise<T>,
): Promise<T> {
  return storage.run({ tenantId: ctx.tenantId ?? null, manager: ctx.manager }, fn);
}

/** The current request's context, or throws — never a silent default tenant. */
export function currentRequestContext(): RequestContext {
  const ctx = requireScope();
  if (ctx.tenantId === null) {
    throw new Error(
      'Request context has no tenant. TenantGuard names it; this route ran without the guard.',
    );
  }
  return { tenantId: ctx.tenantId, manager: ctx.manager };
}

/**
 * The request's transaction before a tenant is known — for the two components that
 * run either side of the guard: the guard itself (which needs the manager to do
 * `SET LOCAL`) and the interceptor that commits it. Nothing else may use it, because
 * a query through it before the guard runs sees no tenant at all under RLS.
 */
export function currentRequestTransaction(): EntityManager | undefined {
  return storage.getStore()?.manager;
}

/** Names the tenant on the current request. `TenantGuard` only (ADR-0003). */
export function setRequestTenant(tenantId: string): void {
  requireScope().tenantId = tenantId;
}

function requireScope(): MutableRequestContext {
  const ctx = storage.getStore();
  if (!ctx) {
    throw new Error(
      'No request context. Tenant-scoped work must run inside runInRequestContext(), ' +
        'which RequestContextMiddleware establishes; this route ran without it.',
    );
  }
  return ctx;
}
