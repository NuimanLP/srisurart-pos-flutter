# Server transactions, tenancy and lock order

> Moved verbatim from `CLAUDE.md` on 2026-10-23 (docs review R9). These rules still bind; `CLAUDE.md`'s index says when to read this file.
> Scope: `server/src/common/`, `TenantService`, any write touching sales/mechanic/products/doc_counters/customer.

**Transactions & tenancy (`server/src/common/`, `TenantService`):**
- The transaction lives in the request **handler**, never in middleware/guard/
  interceptor (ADR-0003 amendment, **Accepted**, in force since `tx.4`).
  `TenantService.runTx(fn)` takes **no tenant-id argument** — that's what makes it safe;
  never reintroduce a `runTx(tid, fn)` signature.
- **No component may take a second pool connection inside one request.** A global guard
  reading `tenants.plan` on a cold cache did this once and deadlocked the pool at
  `DB_POOL_SIZE` concurrent requests (#162). `Promise.all([runTx(a), runTx(b)])` has the
  same shape — fold sibling calls into one `runTx`.
- A void's manager-PIN check runs **ahead of** `runIdempotent`, outside any transaction
  (argon2 is slow); a resent `Idempotency-Key` no longer skips PIN verification.
- Three architecture specs gate this seam — `tenant-door.spec.ts`, `tenant-wrapper.spec.ts`,
  `idempotency-routes.spec.ts` — change them deliberately, never just to turn them green.
  A new write route with no idempotency claim at all is invisible to all three.
- A 25 s **commit-ceiling guard** in `runTx`/`TenantJobRunner` rolls back and throws
  `CommitCeilingExceededError` before `COMMIT`; `pos_app` also gets
  `statement_timeout=25s`. Never set `statement_timeout` ≤ `CLAIM_LOCK_TIMEOUT` (it makes
  `503 IDEMPOTENCY_KEY_IN_FLIGHT` unreachable). A pool holder writing a table clients pull
  by `updated_at` must commit through the guard (tenant export is the only opt-out).

**Lock order (money/stock writes):** `sales` → mechanic → products → `doc_counters` →
customer, with a `shifts` `FOR SHARE` read inserted between the sale and mechanic locks
on void/return paths. Keep this order in any new write touching more than one of these.
