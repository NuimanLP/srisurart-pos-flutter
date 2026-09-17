# Handoff: phase-1 DoD checklist evidence trace (#196)

**Date:** 2026-09-16 · **Scope:** `docs/Backend_design/03_ARCHITECTURE.md` §8, "เกณฑ์ปิดเฟส 1
(definition of done)" — the 13 lines that were `- [ ]` before this pass.

This is an audit, not a feature branch: #196 is not closed by this work, and no ticket is
opened here. The brief was to run the real e2e suite (not read test names) and tick a box
only when an actually-run, actually-passing test traces the exact Thai wording of the claim.

## 1. Could the real stack run in this sandbox?

**Yes.** Docker Desktop was available, and a dev-overlay stack (`server/docker-compose.yml` +
`docker-compose.dev.yml`, project `srisurart-pos`) was already running — Postgres on
`127.0.0.1:5432`, `redis-cache` on `6379`, `redis-queue` on `6380` — left up from an earlier
session on this machine. It was reused rather than torn down (CLAUDE.md's own warning: never
`docker compose down -v` on a shared daemon). One pending migration
(`ImportJobs1788652802200`) was applied before the run. The full e2e suite was then run for
real against that Postgres/Redis, not mocked and not skipped as a group.

Commands run, in order, from `server/`:

```
cp .env.example .env
corepack pnpm install
corepack pnpm build
DATABASE_URL=postgres://postgres:dev-only-postgres@127.0.0.1:5432/pos corepack pnpm db:migrate:status
  → "pending migrations exist"
DATABASE_URL=postgres://postgres:dev-only-postgres@127.0.0.1:5432/pos corepack pnpm db:migrate
  → "applied: ImportJobs1788652802200"
TEST_LOG_LEVEL=error corepack pnpm test:e2e
  → Test Files  44 passed | 1 skipped (45)
    Tests  490 passed | 2 skipped (492)
    Duration  333.29s
```

The one skipped **file** is `test/tx-hold-measure.e2e-spec.ts`
(`describe.skipIf(!process.env.MEASURE_TX_HOLD)`) — an opt-in latency-measurement harness, not
a correctness test; it was not needed for any DoD claim. Output was captured with
`TEST_LOG_LEVEL=error`, so vitest's per-test names were not printed to the log (only the
aggregate summary and the app's own `error`-level log lines survived), but zero failures were
reported and the app's own log lines during the run independently corroborate several of the
tests this audit relies on actually executing (e.g. `PROBE 300 role denials: {"403":300}`
matches `tenant-scope.e2e-spec.ts`'s suspended-shop probe; the `postgres: down` /
`redisCache: up` health payload matches `health-pool.e2e-spec.ts`; the `drawer_entries_type_check`
violation and `DLQ_JOB_FAILED` lines match `import-snapshot.e2e-spec.ts` and
`worker-jobs.e2e-spec.ts`'s negative-path cases). The identity of the 2 individually-skipped
tests was not tracked down; none of the tests cited below are among candidates for that (all
were positively corroborated as ticked/gap by direct source reading, not just by the aggregate
pass count).

**k6 itself was not run.** `docs/Backend_design/03_ARCHITECTURE.md §8.1` (owner decision,
2026-09-15, #257) requires the load test to be measured from **several physical machines**
against the demo VM's nginx, remote-writing into its Prometheus — a single-sandbox run cannot
produce that evidence without contaminating the measurement (the same section explains why a
single source IP hits nginx's own `perip` limiter before the system does). This DoD line stays
unticked; it is a genuine "cannot be proven here" gap, not a coverage gap.

## 2. The trace table

| # | DoD line (paraphrase) | Candidate test(s) | Ran & passed? | Verdict |
|---|---|---|---|---|
| 1 | k6 meets `02_API_SCREENS.md §9` | `test/k6.e2e-spec.ts` (only sets up fixtures + verifies integrity over HTTP; does not run k6 itself) | N/A — real k6 run needs the demo VM + multiple physical machines (§8.1) | **gap — cannot verify here** |
| 2 | Cross-tenant read: 0 rows in **every** case | `test/schema.e2e-spec.ts` ("RLS is enabled and forced on every tenant-scoped table, with one policy each"; "with app.tenant_id unset the app role reads ZERO rows" — on `products` only); `test/security.e2e-spec.ts:204,237` (sales read → 404, sales void → 404) | Ran, passed (both files) | **gap — proven for the RLS *mechanism* and for 2 concrete resources (sales read, sales void); no test loops over every tenant-scoped resource asserting 0 rows "ทุกเคส"** |
| 3 | Import a **real shop's** snapshot, all 6 `01_DATABASE.md §9` checks pass | `test/import-snapshot.e2e-spec.ts:135` ("imports the %s snapshot and passes all six post-import checks", `it.each(['clean','realistic'])`) | Ran, passed — **for the synthetic snapshot only** (`REAL_FILE` env unset) | **gap — not a coverage gap, a precondition gap.** The test itself supports `SNAPSHOT_FILE=<real backup>` and is written for that path, but no real shop file exists to run it against in this environment (never committed, by design). CLAUDE.md's own open-items list already carries this exact line: *"#185: re-run with the real shop file."* |
| 4 | `POST /sales`, 3 short lines → **one** Thai message, all 3 lines | `test/sales.e2e-spec.ts:476` "three short lines come back as three Thai lines in ONE response" | Ran, passed | **TICKED** |
| 5 | Delete a customer with bills → `200` soft-delete, not `500` | `test/people.e2e-spec.ts:177` "soft-deletes a customer with bills, keeps the bill, and hides the tombstone" | Ran, passed | **TICKED** |
| 6 | `POST /platform/tenants` → login + sell for real, no psql | `test/import-snapshot.e2e-spec.ts` (provisions via the real endpoint, then a real `POST /sales` succeeds — but the sale uses a JWT minted directly by the test's `accessToken()` helper, not a real `POST /auth/token` login with the owner credentials the provisioning call just created, and no device is enrolled via `POST /auth/device`); `test/platform.e2e-spec.ts` (provisions, checks audit row, never sells) | Ran, passed (both), but neither exercises the **login** step | **gap — provisioning-then-sell is proven; provisioning-then-*login*-then-sell is not. No test calls `POST /auth/token` with the `ownerUsername`/`ownerPassword` a provisioning call just returned.** |
| 7 | `backoffice` device `POST /sales` → `403 DEVICE_ROLE_FORBIDDEN` | `test/security.e2e-spec.ts:306` "enforces device role guard (backoffice device cannot create sale)" | Ran, passed | **TICKED** |
| 8 | Suspend tenant → next request refused **immediately**, no waiting for token expiry | `test/request-context.e2e-spec.ts:154` "a suspended shop is refused before its tenant is ever named on a transaction" | Ran, passed | **TICKED** — the token used is minted fresh in `beforeEach` (valid, unexpired, correctly signed) and is rejected on its very first use after the tenant is suspended mid-test; this is what proves the rejection is a live status check, not token staleness |
| 9 | Suspend tenant → a job already queued in BullMQ for it must **not run** | `test/queue.e2e-spec.ts:135` "skips job execution without invoking business logic if tenant is suspended" | Ran, passed | **TICKED, with a caveat** — the test calls `TenantJobRunner.runWithTenantContext()` directly with a synthetic `Job` object; it does not `.add()` a job to the real `redis-queue` and let a live Worker dequeue it. The tick stands because every real `@Processor` (`sale-post.processor.ts:35`, `inventory.processor.ts:30`, `maintenance.processor.ts:54,102`, `backup.processor.ts:82`) delegates to this exact same `runWithTenantContext()` call, and `src/common/tenant-door.spec.ts` is an architecture test that statically enforces that every processor does so — so the function-level proof plus the structural proof together cover the claim, but no single test exercises the literal "job sitting in the real queue, worker dequeues it after suspension" path |
| 10 | Kill `redis-cache` → suspended tenant **still rejected** AND a normal tenant **still works** | `test/tenant-scope.e2e-spec.ts:122` "a request the guard refuses takes no connection; a suspended shop is never named" (clears the `t:{tid}:status`/`:plan` cache keys, then proves the suspended half falls back to Postgres correctly) | Ran, passed | **gap** — proves the suspended half under a cache **miss** (keys deleted), which exercises the same `catch`-and-fall-back code path in `src/common/guards/tenant.guard.ts:90-97` as an actual Redis connection error, but (a) no test simulates a real connection failure (`ECONNREFUSED`/timeout) rather than an empty key, and (b) no test proves an **active** tenant still succeeds in the same run — only the suspended half is asserted |
| 11 | `pos` sale × `backoffice` receive + adjust-stock, same product, **200 rounds** → stock matches, no lost update | `test/purchase-orders.e2e-spec.ts:416` "a receipt racing sales on the same product: no deadlock, no 500, stock adds up" (8 sales + 1 receive, no adjust-stock); `test/sales.e2e-spec.ts:581` "200 concurrent bills..." (sales only, no receive/adjust-stock — this is what already-ticked line 3 in the checklist cites) | Ran, passed (both) | **gap** — no test combines all three operation types (`POST /sales`, `/purchase-orders/:id/receive`, `/adjust-stock`) on one product at the specified 200-round scale; the two passing tests each prove a narrower slice |
| 12 | Retire `pos` device w/ open shift → shift closed same tx, old token refresh fails **<15 min**, new device gets new `device_no` **and can sell** | `test/devices.e2e-spec.ts:190` "enrol → device token → login carries did/drole; retirement locks the token out of login and refresh" (refresh fails immediately post-retire — mechanism is device-role-agnostic, confirmed in `src/auth/auth.service.ts:293-298`, which checks `devices.retired_at` by id with no role filter); `test/shifts.e2e-spec.ts:415` "a replacement pos device starts clean after the old one is retired" (same-tx shift close proven earlier in the same file at :361; new device gets a new `device_no`; the replacement device successfully opens a **fresh shift**) | Ran, passed (both) | **gap, closest of the seven** — same-tx shift closure, old-token-refresh-failure, and new-`device_no` are each concretely proven (across two files); "และขายได้" (**and can sell**) is only proxied by the replacement device successfully opening a shift (same `RequireDeviceRole('pos')` gate as `POST /sales`) — no test sends an actual `POST /sales` with the replacement device |
| 13 | `backoffice` login w/ no `deviceToken` → `GET /products` works, `POST /sales` → `403` | Guard code only: `src/common/guards/tenant.guard.ts:82-86` (`drole !== 'pos'` throws when required; `GET /products` carries no `@RequireDeviceRole` at all); analogous test `test/quotes-parked.e2e-spec.ts:281` "a session with no device token cannot issue a QT number" (proves `drole` undefined → `403 DEVICE_ROLE_FORBIDDEN` on a **different** device-role-gated endpoint) | Ran, passed (analogous test) | **gap** — no e2e test performs this literal pair (`GET /products` success + `POST /sales` 403) with a token that has no `did`/`drole` at all; code reading plus one analogous endpoint's test make this the safest of the ungranted claims, but it is not the same assertion |

## 3. What was ticked and why

Five boxes were flipped `- [ ]` → `- [x]` in `docs/Backend_design/03_ARCHITECTURE.md`, each with
a citation appended in the file's existing style (`— **#<issue> [\`<slug>\`] <date>** (...)`),
with no other edit to the line's Thai wording and no other file touched except this one:

1. **3-line insufficient-stock message** — `#20`, PR #75 (`feat/laneA-sales`, merged
   2026-09-11), `server/test/sales.e2e-spec.ts:476`.
2. **Soft-delete a customer with bills → 200** — `#17`, PR #85 (`lane2`, merged 2026-09-12),
   `server/test/people.e2e-spec.ts:177`.
3. **`backoffice` device `POST /sales` → 403 `DEVICE_ROLE_FORBIDDEN`** — `#44` `sec.1`, PR #106
   (merged 2026-09-13), `server/test/security.e2e-spec.ts:306`.
4. **Suspended tenant refused immediately, no wait for token expiry** — `#20`, PR #75,
   `server/test/request-context.e2e-spec.ts:154`.
5. **Suspended tenant's queued job does not run** — `#34` `p9.1`, PR #88
   (`feat/p9.1-bullmq-infra`, merged 2026-09-12), `server/test/queue.e2e-spec.ts:135`
   (see the caveat in row 9 of the table above — ticked on the combination of the direct
   function-level test and the `tenant-door.spec.ts` architecture guarantee, not a live-queue
   integration test).

Every citation was checked against real git history (`git log -S"<exact assert string>" --
<file>`, then `git merge-base --is-ancestor <commit> <merge-commit>` to confirm the PR that
carried it), not guessed.

## 4. What stays open, and why

Eight boxes remain `- [ ]`. Seven are genuine test-coverage gaps; one (row 3, the real-shop
import) is a precondition that has not been met yet, not a missing test:

- **k6 §9** (row 1) — cannot be measured in a single sandbox; needs the demo VM + the
  multi-machine method `§8.1` specifies. Not attempted here.
- **Cross-tenant read, every case** (row 2) — the RLS mechanism is proven structurally for
  every tenant-scoped table, and two concrete resources (sales read, sales void) are proven at
  the HTTP layer, but no single test sweeps every tenant-scoped resource. **Recommended
  follow-up:** a table-driven e2e that, for each entry in `TENANT_SCOPED_TABLES`
  (`src/db/migrations/1788652800001-RowLevelSecurity.ts`), seeds a row for tenant B and asserts
  tenant A's corresponding list/read endpoint returns 0 rows / 404.
- **Import the real shop's file** (row 3) — the test is written and ready
  (`SNAPSHOT_FILE=<path> corepack pnpm test:e2e test/import-snapshot.e2e-spec.ts`); it has just
  never been run against the actual backup, per CLAUDE.md's own open list (`#185`). Not a code
  gap — an operational one for whoever holds the shop's file.
- **Provision → login → sell** (row 6) — provisioning-then-sell is proven; the login step
  (`POST /auth/token` with the credentials provisioning just created) plus device enrolment
  (`POST /auth/device`) before the sale is not. **Recommended follow-up:** extend
  `import-snapshot.e2e-spec.ts`'s or `platform.e2e-spec.ts`'s tenant-creation flow with a real
  `/auth/token` call using the returned `ownerUsername`/`ownerPassword`, then enrol a `pos`
  device and sell with *that* session, not a directly-minted JWT.
- **Kill `redis-cache`, both halves** (row 10) — only the suspended half is proven, and only
  under a cache-key-miss, not a genuine connection failure. **Recommended follow-up:** a test
  that makes the cache client throw on `.get`/`.set` (as `test/cache-stampede.e2e-spec.ts:86`
  already does for the products-list cache) for the **tenant-status** key specifically, and
  asserts both a suspended tenant is rejected and an active tenant's request still succeeds.
- **200-round mixed concurrency** (row 11) — the two operation-type pairs that exist (sales-vs-
  receive at 8 requests; sales-alone at 200) don't compose into the specified scenario.
  **Recommended follow-up:** widen `purchase-orders.e2e-spec.ts`'s existing race test to include
  `/adjust-stock` calls and raise the count to 200 total requests across all three endpoints on
  one product.
- **Retire-and-replace, "and can sell"** (row 12) — the weakest of the seven gaps; every other
  clause is proven. **Recommended follow-up:** append one `POST /sales` call with the
  replacement device's token to the end of `shifts.e2e-spec.ts`'s existing "a replacement pos
  device starts clean after the old one is retired" test.
- **No-deviceToken backoffice session** (row 13) — guard code supports the claim and an
  analogous endpoint (`POST /quotes`) is tested the same way, but no test uses the literal pair
  named in the DoD line. **Recommended follow-up:** in `test/catalogue.e2e-spec.ts` or a new
  file, mint a token via `accessToken({ tenantId, userId, role })` with no `deviceId`/`deviceRole`
  and assert `GET /products` → 200, `POST /sales` → 403 `DEVICE_ROLE_FORBIDDEN`.

No new GitHub issues were opened for these follow-ups per the task's instructions — they are
listed here for whoever picks up the remaining DoD lines.

## 5. Self-review

Applied `karpathy-guidelines` before editing: the only file touched is
`docs/Backend_design/03_ARCHITECTURE.md`, and the only edits are `- [ ]` → `- [x]` plus an
appended citation on 5 lines — no rewriting of the surrounding checklist, no touching the 8
lines that stay open, no touching any other section of the file. `git diff main --
docs/Backend_design/03_ARCHITECTURE.md` was checked line-by-line before finalizing: exactly 5
lines changed, each preserving its original Thai wording verbatim.

Re-scrutinized every tick against the "not an adjacent claim" bar before finalizing (see the
per-row caveats above for rows 9 and 12's near-misses, which were checked hardest since they
sit closest to the gap/tick boundary and were the most tempting to over-credit).
