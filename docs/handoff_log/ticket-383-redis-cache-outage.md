# Ticket #383 — `test.redis-cache-outage` (รอบสอง): พิสูจน์ด้วย cache ที่ล่มจริง ไม่ใช่ `vi.spyOn`

**Date**: 2026-09-22
**Lane**: C (`team/3`, `PattaraponKitcharoen`)
**Branch**: `feat/383-redis-cache-outage`
**Base**: `origin/main`
**Spec references**: [`03_ARCHITECTURE.md §8`](../Backend_design/03_ARCHITECTURE.md) (DoD line for the `redis-cache` outage box), [`ADR-0003`](../Backend_design/adr/0003-tenant-lifecycle.md) §5 (status falls through to Postgres on cache miss/failure, no fail-open/fail-closed), [`session-2026-09-22-196-reaudit.md`](session-2026-09-22-196-reaudit.md) (the re-audit that untucked this DoD box and opened #383)

---

## Root cause

The `§8` DoD line *"ดับ `redis-cache` แล้วร้านที่ `suspended` ยังถูกปฏิเสธ และร้านปกติยังใช้งานได้"* was ticked on 2026-09-17 citing `server/test/tenant-scope.e2e-spec.ts:186`, but the 2026-09-22 re-audit found that test proved something else entirely:

```ts
// before — tenant-scope.e2e-spec.ts:186 (removed in this PR)
vi.spyOn(cache, 'get').mockRejectedValue(new Error('connect ECONNREFUSED 127.0.0.1:6379'));
vi.spyOn(cache, 'set').mockRejectedValue(new Error('connect ECONNREFUSED 127.0.0.1:6379'));
const activeRes = await http().get('/api/v1/tx4-probe').set('Authorization', `Bearer ${token}`);
```

Two problems, both named in the issue:

1. **Mocking the client's own methods is not a real outage.** It proves the guard's `catch`
   block runs, never what actually happens when `redis-cache` is unreachable. The case that
   genuinely differs — a connection that **hangs** rather than rejects (ioredis believes the
   socket is fine and every command would wait forever without `commandTimeout`, #140) — is
   invisible to a mocked rejection: a `mockRejectedValue` settles immediately, so it can never
   exercise the timeout path at all.
2. **It hit `/api/v1/tx4-probe`**, an internal test-only route, not `GET /products` +
   `POST /sales` **with a real stock decrement**, which is what #294's own AC and ADR-0003 §5's
   surrounding context are about.

What the old test *did* prove — "the guard catches a cache exception and falls through to
Postgres" — has real value, but it is not this DoD line.

## What changed

**New file** `server/test/redis-cache-outage.e2e-spec.ts` (269 lines): two `describe` blocks,
each booting its own app instance (via `createTestApp()`) against a genuinely broken
`REDIS_CACHE_URL` — no `vi.spyOn` anywhere in the file:

1. **"connection refused"** (`:137`–`:195`) — `REDIS_CACHE_URL` points at a port opened and
   closed immediately before boot (`closedPort()`, `:36`), so every Redis command ioredis makes
   rejects with a real `ECONNREFUSED`.
2. **"connected but silent until timeout"** (`:201`–`:269`) — a real `net.Server`
   (`fakeRedis()`, shared from `test/support/fake-redis.ts`) speaks just enough RESP to get
   ioredis to `ready` (refuses `HELLO`, answers `INFO`, `OK`s the rest — the same technique
   `src/infra/redis-command-timeout.spec.ts` uses for the #140 unit coverage, now factored into
   one shared helper both files import), then goes silent. The app's own client is allowed to
   reach `ready` first (`untilReady(cache)`, `:230`) before the fake stops answering, so this is
   specifically the "open socket, no reply" case `commandTimeout` exists for — not "never
   connects at all", which the first describe block already covers. `REDIS_COMMAND_TIMEOUT_MS`
   is overridden to `300` for this app only, so the suite's several guarded requests (each
   paying one full command timeout per Redis call once the fake goes quiet) stay fast; #140's
   own unit spec already proves the timeout mechanism works at any value.

Both scenarios run the same shared assertion (`assertActiveSellsAndSuspendedIsRejectedAtOnce`,
`:57`–`:135`) against a real HTTP app:

- `GET /products` → `200`, the seeded product is in the list.
- `POST /sales` → `201`, and `stock` is read from Postgres **before and after** the sale
  (`10 → 9`) — not just the status code.
- The **same** `Idempotency-Key` is replayed immediately after: `201` again, an identical
  body, and stock still `9` — proving `IdempotencyService`'s own Redis-touching replay path
  (`readCache`/`writeCache`, a fail-open mechanism entirely separate from `TenantGuard`'s and
  `TenantCache`'s) also survives the outage, not just the first-time-claim path a fresh key
  alone would exercise.
- The tenant is then flipped to `suspended` directly in Postgres, and the **very next**
  request gets `403 TENANT_SUSPENDED` — with `redis-cache` still down, `TenantGuard` reads
  `tenants.status` fresh from Postgres on every single request (its own cache write also fails
  silently), so there is nothing stale to wait out and no token-expiry window to worry about.

**Edited** `server/test/tenant-scope.e2e-spec.ts`: removed the mocked-method test at the old
`:186` (it hit `/api/v1/tx4-probe` and only ever `vi.spyOn`'d `cache.get`/`cache.set`) and left
a comment pointing at the new file. Nothing else in that file changed — `cache` is still used
by three other tests in it.

**New file** `server/test/support/fake-redis.ts`: the fake-Redis TCP server
(`parseCommand`/`reply`/`fakeRedis`/`untilReady`) factored out of
`src/infra/redis-command-timeout.spec.ts`, which now imports it too, so the one RESP-parsing
implementation only needs fixing in one place if it's ever wrong.

No production code changed — this is a test-only fix, matching the shape #384 took for the
sibling DoD box.

## Self-review pass

Ran `/code-review` (high effort) against this branch before opening the PR. One CONFIRMED and
three PLAUSIBLE findings survived verification, all fixed in the same PR:

- **CONFIRMED** — both `afterAll` hooks called `app.close()`, which triggers
  `RedisModule.onModuleDestroy`'s `cache.quit()`; but with `enableOfflineQueue: false`, ioredis
  rejects a command outright when the client isn't currently writable *before* `quit()`'s own
  `disconnect()` branch is ever reached. The "refused" client never reaches `ready` at all, and
  the "hung" client is later cut off by `fake.close()` — either way, `quit()` alone never clears
  `retryStrategy`'s reconnect timer, so the client kept retrying a dead target forever in the
  background for the rest of the single-process `pnpm test:e2e` run
  (`fileParallelism: false`). Fixed by calling `cache.disconnect()` explicitly in both
  `afterAll` hooks before `app.close()`.
- **PLAUSIBLE** — the fake-Redis server was a byte-for-byte duplicate of
  `src/infra/redis-command-timeout.spec.ts`'s own copy. Fixed by extracting
  `test/support/fake-redis.ts` and having both files import it.
- **PLAUSIBLE** — every `POST /sales` used a fresh `Idempotency-Key`, so
  `IdempotencyService`'s own Redis-outage handling (a fail-open path separate from
  `TenantGuard`'s) was never exercised — only a *replayed* key reaches it. Fixed by replaying
  the same key right after the first sale and asserting an identical `201` with no second
  stock decrement (see "What changed" above).
- **PLAUSIBLE** — both `afterAll` hooks ran their cleanup as a bare sequential `await` chain
  with no `try`/`finally`, so a throw partway through (e.g. from `resetTenant`) would skip
  `app.close()`/`fake.close()` entirely. Fixed by wrapping the DB cleanup in `try` and moving
  `app.close()`/`fake.close()` into `finally`.

One finding was reported but left unfixed: a low-probability TOCTOU race in `closedPort()`
(the OS could theoretically rebind the freed port before the app connects) — accepted as the
established convention for "guaranteed free port" tricks elsewhere in this suite, with no
cheaper fix available.

All of the above were re-verified: `redis-cache-outage.e2e-spec.ts` 2/2, full `pnpm test:e2e`
607/607 (2 pre-existing skips), full `pnpm test` 412/412, lint and typecheck clean.

## Falsification

Per the lane's working agreement (`09_PHASE2_LANES.md §10`), sabotaged the mechanism the new
test actually depends on — `TenantGuard`'s fail-open `catch` around the cache read
(`server/src/common/guards/tenant.guard.ts`) — to confirm the new assertions catch a broken
path rather than passing vacuously:

```diff
- try {
-   status = await this.redisCache.get(cacheKey);
- } catch (err) {
-   this.logger.warn(`Redis cache error reading tenant status: ${err}`);
-   status = null;
- }
+ status = await this.redisCache.get(cacheKey);
```

Result: **both** describe blocks failed at the first assertion —
`AssertionError: expected 500 to be 200` on `GET /products` — because with no `catch`, the
rejected/timed-out `redisCache.get` call now throws out of the guard instead of falling
through to Postgres. Reverted immediately after confirming the red run; `git diff` on
`tenant.guard.ts` is empty in the committed state.

## Verification results

- `vitest run --config ./vitest.config.e2e.ts test/redis-cache-outage.e2e-spec.ts` — **2/2
  passed** (~5.9s for both outage scenarios together)
- `vitest run --config ./vitest.config.e2e.ts test/tenant-scope.e2e-spec.ts` — **4/4 passed**
  (regression on the edited file)
- `vitest run --config ./vitest.config.e2e.ts test/redis-cache-outage.e2e-spec.ts
  test/tenant-scope.e2e-spec.ts test/cache-invalidation.e2e-spec.ts
  test/cache-hit-no-connection.e2e-spec.ts` — **37/37 passed** together
- `pnpm test:e2e` (full suite) — **607 passed, 2 skipped** (pre-existing skips, unrelated)
- `pnpm test` (unit suite) — **412/412 passed**
- `pnpm lint` — clean (oxlint, exit 0)
- `pnpm typecheck` — clean (`tsc --noEmit`, exit 0)

## Docs updated in the same PR

- `docs/Backend_design/03_ARCHITECTURE.md §8` — the `redis-cache` outage DoD line ticked back
  to `[x]`, citing `redis-cache-outage.e2e-spec.ts` and the specific line numbers of both
  outage mechanisms.
- `CLAUDE.md` — DoD count corrected from "17 boxes, 15 ticked, 2 open" to "17 boxes, 16 ticked,
  1 open"; the one still open is `#380` (k6). `#383` is no longer listed as open.
- `server/src/infra/redis-command-timeout.spec.ts` — now imports the fake-Redis helper from
  `test/support/fake-redis.ts` instead of carrying its own copy (see "Self-review pass").

## Not in scope

`#380` (the three-laptop k6 run) is the one remaining `§8` box and a separate ticket entirely
— not touched here.
