# Srisurart Autopart POS — Flutter (Project Knowledge Base)

Flutter migration of a Thai auto-parts shop POS, ported from the React-in-browser +
localStorage app (the "Srisurart Autopart Design System" repo; origin
github.com/NuimanLP/Sri-SuRat_Store). The shipped client is **offline-first**: Drift/SQLite +
flutter_bloc + go_router. Thai-first UI with EN labels. Targets **Android/iOS + Web**.
Since 2026-09-04 `main` is the **multi-tenant client + backend + CI/CD** line (see below); the
offline-first-only build is preserved on `POC_sample_offline_first`.

> **🔒 Read first — private operating instructions (machine-local, NOT in this repo).**
> Also read these from the local toolkit folder `D:\Beestation\A_Tooling\claude-portable\`:
> - `CLAUDE.md` — global working guidelines for this machine.
> - `skills-for-claude.md` — skill-routing table (trigger → skill); invoke via the Skill tool.
>
> These live **outside** this repo on purpose and must stay private. Do **NOT** copy, paste,
> summarize, or commit their contents here — only this pointer belongs in the repo.

---

## 🌿 Branch strategy (set 2026-09-04)

The repo now carries **two lines of work**. Know which one you are on before you change anything.

| Branch | What it is | Status |
|---|---|---|
| **`main`** | **The multi-tenant line** — Flutter **client** + NestJS **backend** + **CI/CD**, per `docs/Backend_design/` (Architecture C phase 1 = A, tenancy model T1) | **Active.** All new work lands here. |
| **`POC_sample_offline_first`** | Frozen **proof-of-concept snapshot** of the offline-first, Drift-only build (branched from `main` at `4dae2f0`) | Reference only. Do not build on it. |

**What this means in practice:**
- `main` grows a **server** (NestJS + PostgreSQL + Redis + BullMQ + Nginx) and **pipelines**
  (`.github/workflows/`) alongside the existing Flutter app — it is no longer a Flutter-only repo.
- **PostgreSQL becomes the source of truth**; Drift drops to a read cache / offline shell, and the
  transactional invariants (`saveSale`, `createReturn`, `receivePO`, shifts) move **server-side**.
  The Dart repositories stay the behavioural reference for those rules — port them, don't reinvent.
- `POC_sample_offline_first` preserves the offline-first build exactly as the shop runs it today,
  so the phase-1 rule **"the shop keeps running the Drift build, no cutover"** stays testable.
- The offline-first design is **not abandoned** — it returns as **phase 2** (outbox + `offlineOk`
  + a single `role='pos'` writer per tenant, ADR-0004). The POC branch is its starting point.

> Read `docs/Backend_design/adr/README.md` before writing backend code, and remember:
> **where a doc contradicts an ADR, the ADR wins.**

---

## ⚠️ CRITICAL — build path constraint (non-ASCII breaks codegen)

Dart's **`build_runner`** (Drift codegen) and the LSP-based **`flutter analyze`** CANNOT run
on a filesystem path containing **non-ASCII characters** (e.g. the Thai folder `ร้านศรี`) — the
AOT compiler mangles the path to `???????` and fails: *"Unable to write file …build.dart.aot"*.
A Windows junction does NOT help (build_runner canonicalizes to the real path).

What works on a non-ASCII path: `flutter create`, `pub get`, `dart analyze`, `flutter test`,
`flutter build`. What breaks: `build_runner`, `flutter analyze`.

**Consequences / rules:**
- This repo may be **stored** at `D:\Beestation\ร้านศรี\Flutter` (BeeStation sync). The
  generated `*.g.dart` files are **committed**, so it still **builds / runs / tests** there.
- To run **`build_runner`** (required after ANY change to Drift tables / `@DriftDatabase` /
  `database.dart`), first **copy or `git clone` the repo to an ASCII path** (e.g.
  `C:\srisurart_pos`), run codegen there, then commit the regenerated `*.g.dart`.
- **Always use `dart analyze`**, NEVER `flutter analyze`.

### Build / test commands

### Frontend (Flutter)
```bash
cd frontend
flutter pub get
dart analyze                              # NOT flutter analyze
flutter test                              # unit + repository + smoke tests
flutter build web --no-tree-shake-icons   # web build (replaces POS.html on the shop PC)
dart run build_runner build               # ONLY after Drift schema changes — ASCII path only
```

### Backend (NestJS)
```bash
cd server
pnpm install
pnpm lint && pnpm typecheck
pnpm test
pnpm test:e2e
```

---

## Architecture (layered: data → domain → presentation)

```
frontend/
  lib/
    core/
      router/app_router.dart   ← GoRouter + AppRoutes (the 11 routes). ShellRoute → AppShell.
      theme/                   ← navy/orange brand, Sarabun (Thai) + Barlow type
      utils/                   ← newId/docNo (ids.dart), baht/round2/pointsFor (money.dart),
                                 csvSafe (csv_safe.dart)
    data/
      db/tables.dart           ← 21 Drift tables (20 ported sa_* stores + #24's credit-payment outbox)
      db/database.dart         ← AppDatabase (@DriftDatabase) + seed data + AppDatabase.open()
      db/database.g.dart       ← GENERATED (committed). Regenerate ONLY on an ASCII path.
      repositories/            ← one repo per domain; transactional services mirror db.js
      repositories/api/        ← #56: ApiSales/ApiReturns/ApiShifts — same interfaces,
                                 server is the truth, Drift rows patched from the response
                                 (ADR-0010). Opt-in: --dart-define=USE_API_WRITES=true
    domain/models/aggregates.dart  ← SaleWithItems/… read aggregates + input DTOs (SaleInput…)
    presentation/
      repositories/repository_providers.dart ← flutter_bloc RepositoryProvider tree (13 repos
                                 + AuthRepository/ApiClient); `useApi` swaps in the #56 API repos
      blocs/                    ← Cubits (ThemeMode, FontScale, PendingQuote, Cart)
      screens/                  ← 11 screens, 1:1 with the JS screens
      widgets/                  ← shared UI kit + AppShell nav + sub-views (receipt, A4 quote,
                                  label printer, closing report)
    app.dart / main.dart       ← MaterialApp.router + MultiRepositoryProvider/MultiBlocProvider
  test/                        ← repo unit tests (per transactional rule) + route smoke tests
CONTRACT.md                    ← THE binding spec: tables, repo signatures, providers, routes,
                                screen→sub-view ownership, Thai-string rules. Read it first.
```

`AppDatabase.open()` uses `drift_flutter` for the app; tests use `NativeDatabase.memory()`.

---

## Data layer = a faithful port of `pos/db.js` (invariants preserved)

The legacy `pos/db.js` is the behavioural source of truth. Each repository preserves its rules,
using Drift **`transaction(() async {…})`** for atomicity (a throw rolls everything back — the
idiomatic replacement for the JS snapshot/rollback):

- **saveSale** — pre-validate stock (exact Thai `สต็อกไม่พอ…` error); strict decrement (NO
  clamp-to-0 on sale; underflow throws); `pointsGranted = (total/10).floor()`; update customer
  spend+points and mechanic stats (credit when `paymentMethod == เครดิตช่าง`).
- **createReturn** — over-refund guard (qty ≤ sold − already-refunded); proportional
  discount/points/mechanic reversal; credit-balance reduced ONLY for `หักจากเครดิต`; auto-void
  the parent sale on full return.
- **receivePO** — weighted-average cost `round2((oldQty·oldCost + newQty·newCost)/total)`.
- **openShift** archives the prior shift (never lose a day); `addDrawerEntry` blocked after close.
- **quotes / parked** never touch stock. **adjustStock** DOES clamp at 0 (manual adjustment).
- **snapshot** — `exportSnapshot()` emits the JS `sa_*` + `__meta` backup shape;
  `importLegacyBackup()` atomically imports a JS `DB.exportSnapshot()` JSON (zone→category
  migration, null-as-absent). This is the Phase-2 data-migration path.
- IDs/doc-numbers via `newId/docNo` only; CSV via `csvSafe`.

---

## Migration status (Phase 0–6 complete)

**Done:** scaffold; data layer + unit tests; all 11 screens; shared UI kit + nav; shifts layer;
adversarial scrutiny + fix pass; **web-DB runtime wired** (`flutter run -d chrome` now boots —
see below). App `dart analyze`-clean, tests green, `flutter build web` ok.

**Web DB (done 2026-06-24):** `driftDatabase()` on the web requires a `web:` option pointing at
two assets committed in `web/`: `sqlite3.wasm` (matches the `sqlite3` pub version, 3.3.3) and
`drift_worker.js` (matches the `drift` pub version, 2.34.0). `AppDatabase.open()` passes
`DriftWebOptions(sqlite3Wasm: Uri.parse('sqlite3.wasm'), driftWorker: Uri.parse('drift_worker.js'))`
(ignored on native). **If you bump `drift` or `sqlite3`, re-download the matching assets** from
`github.com/simolus3/{drift,sqlite3.dart}/releases` — a version skew breaks the web DB at boot.

**Riverpod → flutter_bloc migration (done 2026-07-14):** full replacement — DI (13
repositories via `RepositoryProvider`), the 4 stateful controllers (now Cubits:
`ThemeModeCubit`/`FontScaleCubit`/`PendingQuoteCubit`/`CartCubit`), and the 20 one-shot
data loads (now `FutureBuilder`s fed by futures created in `initState`/explicit
`_refresh()`). `flutter_riverpod` fully removed from `pubspec.yaml`. The 12-step plan is
archived (migration complete); the session record is `handoff_log/riverpod-to-bloc.md`.

**CouchDB considered and rejected (2026-09-08).** The professor suggested CouchDB in place of
PostgreSQL; the project owner decided the same day to keep the PostgreSQL line. The reasons
(reading ก is strictly worse than Postgres; reading ข rests on an unproven Flutter-Web
replication spike, gets its stock safety from ADR-0004 rather than the DB, throws away #15 and
the course rubric, and offline-first already returns as phase 2) are recorded in
`docs/Backend_design/adr/0012-couchdb-replaces-postgres.md` (**Rejected**) — start there if the
topic comes back; `06_COUCHDB_REVISION.md` is kept as history only. The 2026-09-08 freeze on
`server/` and #4–#37 is lifted.

**Backend direction changed (2026-08-25) — read `docs/Backend_design/` first.** The team now has
backend help and the stack is fixed by the course/assignment to **NestJS + PostgreSQL + Redis +
BullMQ + Nginx**, with **multi-tenant** (many shops, one database) added to the scope. That
supersedes the Supabase-as-backend decision below on three points: a custom server now exists,
**PostgreSQL becomes the source of truth** (Drift drops to a read cache), and the transactional
invariants move server-side. The package is `docs/Backend_design/` — `00_BASICS.md` (backend
primer), `00_INDEX.md` (map + open decisions), `01_DATABASE.md` (28 tables + DDL + invariants),
`02_API_SCREENS.md` (all 11 screens → endpoints), `03_ARCHITECTURE.md` (3 options + rollout),
`04_QA_SCRUTINY.md` (design review record), and **`adr/` — the binding decision record**
(ADR-0001…0011: tenant provisioning, platform-admin plane, tenant lifecycle, device roles,
data portability, per-tenant rate limit, receipt numbering, cost-at-sale, JWT lifetime,
client write-through cache, monorepo; **ADR-0013** = the CI/CD + deploy toolchain, owning doc
`07_CICD_DEPLOY.md`, glossary in the root `CONTEXT.md`). **Where a doc contradicts an ADR,
the ADR wins.** The 2026-09-04 scrutinize round (3 agents) added binding addenda you must read
before server work: ADR-0004 *"การผูกเครื่อง"* (a device is a server-issued device token via
`POST /devices` + `POST /auth/device`; `did`/`drole` never come from the request body),
ADR-0007 *phase 1 = server issues every document number, phase 2 = the `pos` device issues
RC/CN only*, ADR-0009 *refresh also checks `devices.retired_at`*, ADR-0010 *`ApiRepository`
patches rows only and never calls the Drift transactional services; Drift schema v3
(`Sales.shiftId`, `Shifts.id` TEXT, `Products.offlineOk`) is due before `q1` ends* — **schema v3
landed 2026-09-10 (#53)**. The eight
questions only the shop/project owner can answer are collected at the end of `adr/README.md`.
**Server status (2026-09-07): `server/` exists — #14 `p1` and #15 `p2` are merged to `main`.**
Compose stack with Nginx + NestJS ×3 + Postgres + two Redis + worker + Bull-Board, health
probes, JSON logs; the 27-table schema as TypeORM migrations applied by a one-shot compose
`migrate` job, RLS enabled + forced on every tenant-scoped table, grants to the non-owner
`pos_app` role, the five-category seed; see `server/README.md` *Schema and migrations*.
**#18 `p5.1` (idempotency) is merged to `main`** (PR #51, 2026-09-10) — the `Idempotency-Key` module every money/stock
write goes through, proved against the real Postgres; `server/README.md` *Idempotency* has the
rules and the three error codes it had to add to `02_API_SCREENS.md §8`. It reads the request's
tenant + transaction from `src/common/request-context.ts`, the seam **#4** filled.

**Lane A is merged to `main` — PR #75, 2026-09-11 (`feat/laneA-sales` deleted).** It carries
#4's request-context seam, **#19** (document numbers) and **#20** (`POST /sales`) which it closes, plus
#23 (sale reads + void) and #28 (shifts + drawer) which it deliberately **leaves open**, because
#23's "void reverses ledger effects" is only vacuously true until #21 exists and #28's "every sale
*and return* carries `shift_id`" needs #22. A three-axis review round (Standards / Spec / Scrutinize)
then found and fixed, with measurements rather than argument:
🔴 a reused `Idempotency-Key` on `POST /sales/:id/void` answered **200 with a different bill's
payload**, leaving the targeted bill live and its stock unrestored — the fingerprint was built from
`req.route.path`, which is the *pattern*, so two bills collided; it now uses the concrete path.
🔴 the void-denial audit took a **second connection from the request pool**, so any cashier could
500 unrelated requests (`403,403,500,500` in 5013 ms, and every concurrent read 500 — now `403×4`
in 47 ms via a dedicated `AUDIT_DATA_SOURCE`; **never `ADMIN_DATA_SOURCE`**, which connects as the
owner and so writes audit rows RLS never checks).
Also: a retry of a **voided** bill answered success instead of `409 SALE_VOIDED`; closing a drawer
twice returned `addEntry`'s Thai sentence about a different action; `paymentMethod` was free text.
A second review round before the merge (2026-09-11, three parallel agents: Standards / Spec /
Scrutinize) fixed four more: a **negative `items[].price`** passed every total-level check (now 400);
`?page=` was unbounded (now capped like `?limit=`); a **void wrote `movements.type='return'`**, so
reports counted voids as returns (migration `1788652800003` adds `'void'`, `ref_id` is the bare sale id);
and `server/docker/postgres/init/01-app-role.sh` lacked the executable bit, so Docker Desktop on macOS
never created `pos_app` (CI on Linux was unaffected). #23 and #28 stayed open by design; both
are closed now (#23 by PR #78, #28 by PR #79).
Read `handoff_log/lane-a-review-and-adr0003.md` before picking up Lane A.

**#21 `p5.4` is merged — PR #76, 2026-09-11 (`feat/p5.4-ledger-effects` deleted), after #11 was settled
the same day: `mechanics.total_credit` is the JS app's **legacy alias of `total_discount`** (the mechanics
screen labels it "ลดให้ช่าง"; `saveSale` never wrote it) so **the server never writes it** and
`01_DATABASE.md §7.1` is struck accordingly. `POST /sales` now applies the customer/mechanic ledger
in the same transaction, answers `customerAfter` / `mechanicCreditBalanceAfter`, and turns the
credit-limit dialog into `409 CREDIT_LIMIT_EXCEEDED` (English message; the client owns the Thai
dialog) unless the body carries `overrideCreditLimit: true`, which writes one `audit_log` row.
🔴 **Lock order is now mechanic → products → `doc_counters`** — every bill naming a mechanic takes the
mechanic's row first (a cash bill locking products first would deadlock against a credit bill for the
same mechanic); #22 and #23's void reversal must keep that order. 🔴 The counter path resends the
**same `Idempotency-Key`** with the flag after the 409; it works only because the claim rolls back
with the refused transaction, and an e2e pins it — `tx.3` must preserve that.
Read `docs/handoff_log/lane-a-21-ledger-effects.md` before touching the sale path.

**#22 and #23 are merged — PR #78, 2026-09-11 (`feat/p5.6-void-ledger-reversal` deleted).** `POST /returns`
is the credit-note transaction ported from `returns_repository.dart`, and `POST /sales/:id/void` now
reverses the customer and mechanic ledger, which was #23's one remaining AC (1/2/4/5 shipped with #75).
🔴 **The lock order grew to sale → mechanic → products → `doc_counters` → customer** — `sales` is the
outermost resource because the sale path only INSERTs it; **#28 and #30 must keep that order**.
(#94 and #100 add a `shifts` read `FOR SHARE` between the sale and mechanic locks on the void and return
paths — every return method, since non-cash credit notes still net into a shift's gross profit — shared
locks cannot cycle with the drawer's exclusive lockers, which lock nothing else; see `shifts.service.ts`.)
Migration `1788652800004` adds `return_items.cost_at_sale`, carried from the locked `sale_items` read
(ADR-0008's reasoning, applied to credit notes); #22 also writes `returns.shift_id`, which closes half
of **#28**'s "every sale *and return* carries `shift_id`" — do not rebuild it there.
🔴 **The review found a money bug the port inherited: the refund amount was whatever the client sent.**
`soldByProduct` read `qty` and `cost_at_sale` but never `price`, so a `pos` device could issue a
999,999-baht credit note against a bill that sold the part at 85 — and the `GREATEST(0, …)` clamps
turned the damage silent by flooring a mechanic's tab at 0 instead of raising. The bill now decides the
price (`409 RETURN_PRICE_MISMATCH`, refused not corrected). **The general lesson is in that clamp:
validate input first, then clamp — a clamp on unvalidated input converts a loud corruption into a quiet
one.** The Dart reference has the same hole because there the client *is* the authority; on the server
Postgres is. The same round fixed four more: duplicate lines at different prices over-refunded, a
soft-deleted product was restored by a void but silently skipped by a return (writing no `movements`
row at all), `หักจากเครดิต` was accepted on a bill with no mechanic (`409 REFUND_METHOD_NOT_ALLOWED`),
and `GET /returns` shipped without the `?from=&to=` that `02_API_SCREENS.md §314` specifies.
🔴 **`resetTenant` derived `tenants.code` from `tenantId.slice(0, 8)`** and three suites all began
`eeeeeeee`, so whichever reset second died on `tenants_code_key` — 37 failures that looked like new
code and were not. It uses the whole uuid now.
Read `docs/handoff_log/lane-a-22-23-returns-void.md` before #28 or #30.

**#28 is closed — PR #79, 2026-09-12 (`feat/p6.3-shifts-drawer` deleted), and it needed no new behaviour.**
The whole drawer — `src/shifts/`, the five endpoints, the `shift_id` stamp — shipped inside PR #75
(`6e8080f`); the issue stayed open only because its AC *"every sale **and return** carries
`shift_id`"* could not be true until #22 existed. It does, so closing it was two missing assertions:
the auto-archived shift is visible through `GET /shifts/history` while `GET /shifts/current` answers
the new drawer (the raw columns were checked, the API view was not), and a credit note written with
no drawer open carries a null `shift_id` (the sale path proved that case, the return path did not).
✅ **`closeForRetirement` has its production caller since #144** — `server/src/devices/`
(`POST /devices`, `GET /devices`, `POST /devices/:id/retire`, owner only) retires a device and closes
and archives its drawer in one transaction, lock order **devices (`FOR NO KEY UPDATE`) → shifts**; the
probe controller in `test/shifts.e2e-spec.ts` is gone. `ShiftsService.open` now refuses a retired
device (`FOR SHARE` on its row first), since its access token outlives the retirement by up to 15
minutes. See `server/README.md` *Devices*.
🔴 **A local DB one migration behind reads as a code bug:** this round began with 14 red returns
cases, all 500s, because the dev Postgres had never been given `1788652800004` (#22's
`return_items.cost_at_sale`) — `pnpm db:migrate:status` said *"up to date"* because `dist/` was
stale too. Rebuild before believing it. ~~The `200 concurrent bills` case is the known machine
limit~~ — **falsified by #162:** those 500s (and *ten simultaneous opens*') were a pool
**deadlock**, not a limit. `RateLimitService` (a global guard) read `tenants.plan` on a cold cache
with a second pool connection while the middleware held the first; successes equalled
`DB_POOL_SIZE` exactly. #162 read it on the request transaction (savepoint); since tx.4 (#153) there is none and it is a plain pool read again. Both cases pass
locally at pool 8, and `test/rate-limit-pool.e2e-spec.ts` pins it — see `server/README.md` rule 1.
Read `docs/handoff_log/p6.3-shifts-drawer.md` before #30 or a device slice.

🔴 **ADR-0003 was amended 2026-09-10 and the amendment is in force since `tx.4` (#153, 2026-09-14) — the
transaction lives in the handler.** The addendum's status is **Accepted**. The old split (middleware
opens the transaction, the guard names the tenant on it, an interceptor commits) was never chosen: it
was forced by reading ADR-0003's "status check and `SET LOCAL` in one component" as also binding
*where the transaction lives*. Separating **who decides the tenant** (`TenantGuard`: status check,
then `setRequestTenant()` on the scope `TenantScopeMiddleware` opens for every route) from **who
executes `set_config`** (`TenantService.runTx`, inside the handler) keeps every ADR-0003 guarantee;
`RequestContextMiddleware`, `TransactionInterceptor`, `OWNED_BY_INTERCEPTOR`, `TENANT_ROUTES` and
the `res.on('close')` backstop are deleted, so **a new `TenantGuard` controller needs no config
entry**. The prototype measured the open-transaction hold of 4 concurrent voids at `DB_POOL_SIZE=2`
dropping from 112 ms to 18–28 ms; on `main` that needed `tx.5` (#154) too, which moved the void's
manager-PIN check **ahead of `runIdempotent`** (`VoidService.authorise`: a short `runTx` for
`pin_hash`, then argon2 with no transaction) — longest void transaction ~110 → ~14–22 ms, no more
latency staircase; `POST /sales` went ~19 → ~16.5 ms with `tx.4` (`server/test/tx-hold-measure.e2e-spec.ts`,
`MEASURE_TX_HOLD=1`). 🔴 A done `Idempotency-Key` no longer skips the PIN: a void resent with a PIN
that does not verify is a 403 + `sale.void.denied` row, not the replay.
`onTransactionCommit` now **throws** with no open transaction (outside `runTx`), and the guard and
`RateLimitService.readPlan` read `tenants` on the pool — the request's first connection, never a
second. 🔴 **`runTx` must never take a `tid` argument** — the amendment is only safe because
`runTx(fn)` cannot name a tenant the guard did not authorise; the `TenantService` used to have the
`runTx(tid, fn)` signature (removed by `tx.1` #150), and bringing it back would silently restore
exactly what ADR-0003 banned, failing as a cross-tenant read that raises nothing. 🔴 Sibling
`Promise.all([runTx(a), runTx(b)])` takes two connections at once (the #162 deadlock shape) — fold
them into one `runTx`. The proving prototype is commit `0feaf94` on
`worktree-agent-a1756ff02f223b4eb` (never merge it). The slices are #149 → #154 (parent #142), all
landed. `server/README.md` *The request-context seam* describes the in-force mechanism.

🔴 **The e2e suite cannot tolerate a second concurrent runner on the same database** —
`test/schema.e2e-spec.ts` tears the schema down and re-applies it. CI is safe (one Postgres per job),
two developers sharing a dev database are not; the symptom is a migration dying with
`terminating connection due to administrator command` and document numbers starting mid-series.
**#141:** the e2e `globalSetup` (`server/test/support/e2e-runner-lock.ts`) now takes a Postgres session
advisory lock and a second concurrent run **refuses to start**, naming the holder — it still cannot
*share*, it just no longer corrupts silently (`server/README.md` *The e2e suite*). `synchronize` is never
true anywhere, tests included. Phase-1 backend/CI tickets are assigned by lane: `NuimanLP`
(Lane A), `LomerAlloys` (Lane B), `PattaraponKitcharoen` (Lane C) — see
`handoff_log/merge-p1-p2-lane-assignments.md`. **No cutover is planned for phase 1** — the shop
keeps running this Drift build while the server is developed against a demo tenant. **As of
2026-09-04 this work happens on `main`** (see *Branch strategy* above): the server, the
client's API layer and the CI/CD pipelines all land in this repo.

**CI/CD — levels 1–3 are done (level 3 = both release images on GHCR since 2026-09-10, #69/#70). CD to the faculty VM (Ansible), etcd and Monitoring (Node Exporter + Prometheus + Grafana) are designed in `docs/Backend_design/07_CICD_DEPLOY.md` + ADR-0013 (spec #60) and ticketed #63–#67 under #10 for the teammates — read those before touching `.github/`, `deploy/`, `server/Dockerfile`, `server/docker-compose.yml` or `server/docker/nginx/`.** `.github/workflows/flutter.yml` is the
client gate (`dart analyze`, `flutter test`, `build_runner` no-diff, `flutter build web` + the
web-asset assertion), committed 2026-09-04. Status per level:
1. ✅ **Flutter CI** — done. Runners are ASCII paths, so `build_runner` verification runs in CI —
   the only place the committed `*.g.dart` is ever checked against the schema.
2. ✅ **Backend CI** — `.github/workflows/server.yml` (2026-09-06, #38): four jobs — lint,
   unit, integration, and `audit` (2026-09-09, #44: `pnpm audit --audit-level=high` + Trivy fs
   scan; `flutter.yml` gained `deps-audit` = OSV-Scanner on `pubspec.lock`). A transitive CVE is
   fixed via `pnpm.overrides` in `server/package.json`, never by hand-patching.
   🔴 `.github/dependabot.yml` is **security-updates-only** (`open-pull-requests-limit: 0` on every
   ecosystem). Its first version did weekly version bumps and opened four unwanted PRs (#45–#48,
   all closed) within minutes — routine upgrades are human-timed here, not a weekly interrupt. Integration starts the compose Postgres + both Redis (GitHub service
   containers cannot set the Redis eviction policies), applies the real migrations, then runs
   `test:e2e`; `synchronize` is false even in tests. Path-filtered to `server/**`.
3. ✅ **Release images** — merged 2026-09-10 (#70 `ci.4`, #69 `ci.5`; ADR-0013, 07 §3). On a
   green `main` both workflows push to GHCR tagged `<sha>` + `main`: `server.yml`'s `build-image`
   builds, smoke-runs, **Trivy-scans the image (HIGH/CRITICAL, fixed-only, blocks the push — no
   `.trivyignore` anywhere, by ADR)** and pushes `ghcr.io/nuimanlp/srisurart-pos-server`;
   `flutter.yml`'s `build-web` keeps the downloadable web artefact and pushes the static-only
   `…/srisurart-pos-web` (`deploy/web.Dockerfile`, busybox + `/web`). The base-image CVEs (#44's
   table) are answered in `server/Dockerfile`: base pinned by digest, `apk upgrade`, npm/npx/corepack
   deleted from the runtime stage before `USER node` — Trivy 0 findings vs 13 on the bare base.
   The tarball artefact is gone. **Packages are public from the first push** (verified with an
   anonymous pull; no manual visibility step — #71). `server/docker/nginx/nginx.conf` now serves
   the client at `/` (mime types added, `/api/` routed) and the admin-plane allowlist moved to
   `/api/v1/platform/` — the old `/platform/` block never matched (pre-existing bug).
   🔴 **Bump the base digest, never suppress:** the digest pin + security-only Dependabot means a
   CVE published later reddens the gate on an unrelated `main` push (07 §7).
   **Not built yet (teammates):** Ansible provision/deploy to the `demo` VM with rollback
   (#65 #67), monitoring overlay (#63), etcd + `RuntimeConfigService` (#64 #66). The *production*
   host is still unchosen (due before `q4`).
   🔴 **#40's AC4 was fixed by #39:** `push.paths` meant a `server/`-only commit produced no
   web image and a `frontend/`-only commit no server image, so a full release existed only
   for a commit touching both. Both workflows drop `paths:` from `push` entirely — every
   commit on `main` runs everything.

`server/` and the Flutter client share this repo ([ADR-0011](docs/Backend_design/adr/0011-monorepo.md)),
and their CI is still one-workflow-per-side (`flutter.yml`, `server.yml`) with per-job path
filtering — see the next paragraph for how #39 keeps that from deadlocking a PR.
🔴 **Known trap, fixed by #39:** workflow-level `paths:` meant a `server/`-only PR ran **no**
Flutter jobs at all, so naming those jobs as required status checks on `main` would have
blocked such a PR forever. Both `flutter.yml` and `server.yml` trigger unfiltered on every
`push`/`pull_request`; a `changes` job (`dorny/paths-filter@v4`, pull_request only, with job-level
`permissions: pull-requests: read` since it calls the PR-files API) gates each workflow's own
jobs internally with `if: ${{ !cancelled() && (github.event_name != 'pull_request' ||
needs.changes.outputs.<side> == 'true') }}` — the `!cancelled()` half is load-bearing: plain
`needs: [changes]` implicitly requires `changes` to have *succeeded*, and on push it is skipped
(not failed) by its own `if:`, which would otherwise cascade to skip every gated job on every
push. `integration` in `server.yml` is never gated (it carries the cross-tenant isolation tests —
see `server/README.md` *Checks*). Each workflow ends in one always-reported status job
(`flutter-ci-status`, `server-ci-status`) that `needs` every job in its workflow (`changes`
included) and uses `if: always()` plus an explicit loop over `needs.<job>.result`, passing only
`success`/`skipped` and failing on anything else (`failure`, `cancelled`) — `always()` is safe
*only* paired with that loop; a bare `always()` (or `!cancelled()` on the status job itself, which
GitHub would then skip — and a skipped required check reads as passing — when the whole run is
cancelled) is the false green `07_CICD_DEPLOY.md` §2 rule 4 warns about. These two status jobs are
the only required check for their side. Both workflows' `concurrency.group` on `main` is keyed by
commit SHA (not just `github.ref`) so two quick merges don't have the second evict the first's
in-progress release-image build. Branch protection on GitHub itself is **not yet set** — that is a
repo-settings change intentionally left to the project owner; the required-check table and the
exact `gh api` command are in `docs/Backend_design/07_CICD_DEPLOY.md` §4.

**Where the work lives — GitHub issues (since 2026-09-05).** `docs/Backend_design/` says *what* to
build; the issue tracker says *who builds what, in what order.*
- **#2** — phase-1 program brief: the full child tree plus the ownership table. Read it first.
- **#3 / #7 / #8 / #9 / #10** — parents. They hold shared context and carry **no**
  `ready-for-agent` label; do not implement them directly.
- **#14–#40** — the 27 implementable slices. Each is one PR's worth of work with its own
  acceptance criteria and real "Blocked by" numbers.
- **#11–#13** — decisions only a human can make (labelled `question`). **Never settle one in a
  PR.** #11 (`mechanics.total_credit`) was settled by the project owner on 2026-09-11 — parity, the
  column is a legacy alias and the server never writes it — the design doc and the Dart reference
  disagreed and reading either alone gave a confidently wrong answer. #12 and #13 are still open.

🔴 **Course rule (2026-09-05): every team member must touch frontend, backend *and* CI/CD.** The
old "one backend lane each" split is therefore dead — all three lanes were backend. Work is now
three cross-cutting bundles of **9 backend slices + 1 CI slice + 1 frontend slice**, carried by
the labels `team/1` / `team/2` / `team/3`; the table is in #2. **As of 2026-09-07 the 31 issues
are also assigned to real GitHub handles**, not just labels: `NuimanLP` (`team/1`, transaction
path + #14 compose stack), `LomerAlloys` (`team/2`, schema/catalogue/reports), `PattaraponKitcharoen` (`team/3`,
platform/infra/ops). **The frontend slices were ticketed 2026-09-10:** #52 (parent, task `q1`) → #53 `fe.0` Drift
schema v3 · #54 `fe.1` client auth + device token + the server error strings · #55 `fe.2`
`ApiRepository` reads · #56 `fe.3` `ApiRepository` writes. #53 moved to `team/1` (#2's table
reserved it for `team/2`) because it was the only unblocked slice and #55/#56 both sit behind it.
**#53 is merged (PR #58, 2026-09-10)** — schema v3 is on `main`, so #55/#56 are unblocked.
Both `onUpgrade` hops are covered: `frontend/test/schema_v3_migration_test.dart` (v2 → v3) and
`frontend/test/schema_v1_to_v3_migration_test.dart` (v1 → v3 — the hop the shop can actually
hit, since schema v2 only landed 2026-09-04, so a browser whose IndexedDB predates that is
still v1 and runs `from < 2` and `from < 3` back to back). Both DDL constants are dumps of the
real schema at the commit before each bump — **they are evidence, do not tidy them**.
🔴 **`Products` has no `deletedAt` and `ProductsRepository.delete` is a hard delete**, so
#55's `?updatedSince=` cursor sees creates and edits but is structurally blind to deletions —
**#55 owns that column.** It was deliberately NOT added in #53: ADR-0010 decision 2 moves the
client schema only when the client actually needs the field, and nothing writes it until #55.

**#54 is merged (PR #81) and #56 + #82 are merged and closed (PR #84, `ae4d47b`, 2026-09-12 — `feat/fe3-api-writes` deleted; read `docs/handoff_log/review-merge-fe3-84.md` for the review round that gated it).** `fe.3` is the
money path client-side: `ApiSalesRepository` / `ApiReturnsRepository` / `ApiShiftsRepository` under
`frontend/lib/data/repositories/api/`, each `implements` the concrete Drift class's implicit
interface, hits the server, and **patches Drift rows from the response** (ADR-0010). Reads still
delegate to the Drift instance they hold — those are #55. Wiring is opt-in:
`repositoryProviders(db, useApi: …)` defaults to `const bool.fromEnvironment('USE_API_WRITES')`,
so the shop keeps running the Drift build and `--dart-define=USE_API_WRITES=true` is what a
developer flips. Read `docs/handoff_log/fe3-api-writes.md` before touching the client write path.

Rules the slice establishes, all enforced or pinned:
- 🔴 **An `ApiRepository` never calls a Drift transactional service** — `saveSale` after a `201` is
  a double stock decrement, and a local stock pre-check refuses a bill the server would have taken.
  `frontend/test/api_repository_contract_test.dart` enforces it at the source level. Its first draft
  banned `db.transaction(` outright and red-flagged correct code: a **local-only** transaction after
  the response is how a header row and its FK-bearing lines avoid being half-written. The rule is
  what ADR-0010 §3 actually implies — no Drift transactional service, and **no transaction held open
  across the wire**.
- 🔴 **An `ApiException` must never reach a screen.** Checkout, Returns and the Cash Drawer all
  render a failure as `e.toString().replaceFirst('Exception: ', '')`, so an escaping one prints
  `ApiException(status: 409, code: …)` at the counter. `api_wire.dart`'s `rethrowThai` converts every
  server verdict to the plain `Exception(thaiMessage)` those screens already understand.
- 🔴 **The bill id and `Idempotency-Key` are minted once per cart, not once per call.** The ordinary
  failure is a dropped or timed-out reply for a bill the server committed (`ApiClient` times out
  since #183, but abandons rather than cancels the request); a fresh id and key on the counter's second press defeat **both** server defences at once
  (`existingSale` keys on the client's bill id, `idempotency_keys` on the header) and ring the sale
  up twice. The parked attempt lives in `api_wire.dart`'s **`PendingWrites`**, and all three money
  paths use it — `createReturn` and `addDrawerEntry` did not at first, which is a second refund and
  a wrong closing count respectively; `POST /returns` takes no client id at all, so the header is
  its only defence, and the over-refund guard allows `sold − refunded` and so cannot see a duplicate.
- 🔴 **Only a 4xx is a verdict** (`isVerdict`). A 5xx — nginx's own 502/504 included — and a 429
  leave the write's fate unknown, and `503 IDEMPOTENCY_KEY_IN_FLIGHT` says outright that the
  original is still running. Reading every `ApiException` as an answer is how a committed bill gets
  rung up a second time. An attempt is also closed only **after** the local patch succeeds: a patch
  that throws is as unresolved as a lost socket, and it expires after ten minutes because the
  fingerprint is a value, not an identity.
- 🔴 **Consent is carried, never inferred.** `SaleInput.overrideCreditLimit` exists because the
  first implementation replayed `checkout_screen`'s own credit-limit test against the cached
  mechanic row on a 409 and treated a trip as proof the counter had confirmed. It is not the same
  read — the screen tests the row it captured when its list loaded — so it could override a limit
  nobody was shown a dialog for, and the server then writes an `audit_log` row recording a
  confirmation that never happened. **But removing that must not leave the 409 unanswered:** the
  same staleness means the pre-emptive dialog cannot fire for a mechanic another till has already
  moved, so `checkout_screen` catches `CREDIT_LIMIT_EXCEEDED` and asks again with the *server's*
  `details {creditLimit, creditBalance, newBalance}`. That is what `PosException` is for —
  `rethrowThai` used to erase the code, so no caller could tell one refusal from another; its
  `toString()` is still the bare Thai sentence, so no screen had to change.
- **Money crosses the wire as the string `"1234.50"`** (`wireMoney`, rounded through integer
  satang); timestamps are ISO-8601; a field the response omits leaves its row alone (`keepMoney`).

**#82 is closed by the same branch.** `POST /sales` and `POST /returns` wrote four things they did
not return — `sales.shift_id`, the `movements` rows, `sale_items.cost_at_sale`, and the mechanic's
three running totals — so the client had nowhere honest to get them. All four are returned now
(no migration; `RETURNING` on INSERTs that already existed, no new read, no new lock, lock order
untouched). 🔴 **Anything added to either write result must also be added to `existingSale`**, or a
replayed bill answers null for a shift it really has; the e2e compares the replay's **whole body**
with `toEqual` and pins array order, and the check was falsified rather than trusted. Still open:
`POST /sales/:id/void` does not return its movements — it answers `SaleWithItems`, the shape
`GET /sales/:id` also returns, so that is a design call. A void writes `movements.type = 'void'`
(migration `1788652800003`), never `'return'`.

🔴 **`setState(() => _someFuture = …)` trips a Flutter assertion** — the arrow body *returns* the
Future and `setState` asserts its callback did not. Six pre-existing sites were fixed on this
branch. They were invisible because the shop runs a release web build, where assertions are
compiled out; the `checkout_screen` one sat in the **failed-sale `catch`**, so every refused bill
hit it in any debug build. Write `setState(() { x = …; })`, never the arrow form, **when the
value assigned is a `Future`** — that is the whole rule: `setState(() => _busy = true)` is fine,
and 99 arrow-form sites remain in `frontend/lib` on purpose. A convention broader than its bug is
one nobody follows, which teaches readers to skip the 🔴 markers.

🔴 **An offline fallback may only run when the server never answered.** #55's API
repositories (`data/repositories/api_*.dart`) `extend` their Drift counterpart and fell through to
`super.<write>()` inside a bare `catch (_)`, so a server that *did* answer — a 409, or a 5xx where
the write may well have committed and only the reply was lost — silently re-ran the Drift
transactional service: a second weighted-average cost and a second `movements` row out of
`receivePO`, a second `credit_payments` row, a second quote. All 16 write fallbacks now sit behind
`on ApiException catch (e) { rethrowServerRefusal(e); }`, which converts the refusal to the
`PosException` the screens render; only a transport failure still falls back, which is what keeps
the app working with no server in phase 1. `api_repository_contract_test.dart` enforces it at the
source level over **both** folders — its glob used to be `repositories/api/` only, so #55's files,
which are one level up, were never checked at all.

🔴 **`ApiClient.onSessionExpired` had no listener.** `_executeRefresh` cleared the tokens and
called a hook nobody had set, so a refused refresh left the app in a signed-in state that every
later request 401'd against. `main.dart` now wires it to `AuthCubit.sessionExpired`, which keeps the
device token (ADR-0004 — the machine is still enrolled, only the person is signed out) and emits
`Unauthenticated` with **no** `errorMessage`: at 04:00 the counter needs the login form, not a
dialog about token lifetimes. **The login screen and router redirect landed with #143 (PR #155)** —
`/login` outside the shell, `?from=` return path, active only with `USE_API_WRITES`; the Drift-only
build keeps the plain `appRouter`.
🔴 **Only a 401/403 from `/auth/refresh` ends the session (#161).** A transport failure, 5xx, 429
or unreadable 200 keeps both tokens and fails the original request as a connection error — the
server keeps no refresh denylist (ADR-0009), so the kept token still works after a lost reply. The
old catch-all also parsed the refresh reply flat, missing `EnvelopeInterceptor`'s `data`, so every
*successful* refresh against the real server signed the cashier out.

**#83 is closed** (`team/3`, 2026-09-14 status check; see `docs/handoff_log/ticket-83-server-error-resolver.md`). It was: `ServerErrorResolver` prefers *any* server message containing a Thai
codepoint over its own canonical string, so `returns.service.ts`'s English
`Refund method 'หักจากเครดิต' needs a bill with a mechanic.` wins and the mapped Thai never fires.
Three idempotency codes are unmapped too.

**#24 `p5.7` is merged — PR #92 (credit payments) + PR #93 (shift guards), 2026-09-13.**
`POST /mechanics/:id/credit-payments` — `pos` only, idempotent, a CP number, and migration
`1788652800005` adding `credit_payments.payment_method` + `.shift_id` (nullable, **no default**:
an imported row is neither of our shifts nor necessarily cash). 🔴 **An overpayment is refused,
not clamped:** `409 CREDIT_PAYMENT_EXCEEDS_BALANCE` unless `allowOverpayment: true` (one
`audit_log` row) — `GREATEST(0, …)` on an unvalidated amount is #22's money bug again.
`paymentMethod` is required. The client `id` is a second duplicate defence beside the key, and
the replay check runs **before** the overpayment check or a replayed full settlement is refused.
🔴 **No open drawer, no money (owner's decision 2026-09-13, branch `feat/24-shift-guards`):**
`POST /mechanics/:id/credit-payments` and `POST /sales` now answer `409 NO_OPEN_SHIFT` when the
calling device has no shift with `closed_at IS NULL`, on every payment method — the old "stamp null
and take it" port left that cash in no closing report. `ShiftsService.requireOpenShiftIdFor` reads
the drawer `FOR SHARE` (a close waits for in-flight money; money behind a committed close is
refused). It runs **after** both replay paths (key and client `id`), so a payment or bill committed
while the drawer was open still replays after close; credit payment order is mechanic → replay →
drawer → overpayment → CP number, sale order is `existingSale` → drawer → mechanic → products.
`POST /returns` is covered **for cash only** since #100 (owner, 2026-09-13): a `'เงินสด'` refund with no
open drawer is `409 NO_OPEN_SHIFT` (after the bill guards and the key replay; nothing written, no CN number
consumed); `โอน`/`หักจากเครดิต` are still taken and stamp null. After today's close a cash refund waits for
tomorrow's open — `open()` hands back the closed row. No NOT NULL
migration: imported rows are legitimately null. E2E fixtures open a drawer with `seedOpenShift`.
The same branch fixes the #55 client write, which sent no key, no method, and cast the string
balance to `num` straight into a second local row. 🔴 **The client write is an outbox, not a
Drift fallback:** every payment goes into `pending_credit_payments` (Drift **schema v5**) with
its id + key BEFORE the request, and leaves only when the server answers. No network / 5xx →
`CreditPaymentQueued` (the dialog closes and says so; the balance and `credit_payments` are
patched from the server's reply only). A 4xx during a later flush keeps the row for a person
(banner on the Mechanics screen). AC3 (cash settlements summed by `shift_id`) was closed by #30.
Read `docs/handoff_log/lane-a-24-credit-payments.md` before touching credit payments.

**#30, #95, #97, #94 and #100 are merged — PRs #96, #98, #99, #101, #102, 2026-09-13; #7 (Lane A parent) closed.**
The reports are done, and every cash-moving write is now tied to a drawer:
- `GET /reports/closing?shiftId=` computes expected cash and variance **by `shift_id` only**, plus gross profit
  (`cost_at_sale` first, then `products.cost`, disclosed as `estimatedCostRows` / `unknownCostRows`).
- `GET /reports/summary`, top-products, by-category and product-sales all count the same set of bills
  (`COUNTED_SALE`): a **manual** void is excluded; a bill **auto**-voided by a full return is kept and its
  credit note subtracts.
- Migration `1788652800006` adds `idx_returns_shift`.

🔴 **Reports are live SQL, never snapshotted at close, so a closed shift stays closed only because writes are
refused.** Two project-owner decisions closed the holes:
- **#94 (option A):** `POST /sales/:id/void` works only on a bill from the calling device's open drawer.
  Otherwise the server answers `409 NO_OPEN_SHIFT` or `409 SALE_NOT_IN_OPEN_SHIFT`, and the older bill needs
  a credit note.
- **#100 (option A, cash only):** a `'เงินสด'` refund with no open drawer gets `409 NO_OPEN_SHIFT`.
  `โอน` / `หักจากเครดิต` refunds are still accepted, stamped null.

Every refund reads the drawer `FOR SHARE`. Non-cash credit notes still net into the shift's gross profit,
and an unlocked read raced a close and stamped the **closed** shift's id — pinned by an e2e that holds the
row lock.

After today's close, a cash refund waits for tomorrow's open, because `open()` hands back the closed row.

Still open:
- ~~the Thai wording for `SALE_NOT_IN_OPEN_SHIFT`~~ — chosen by the owner 2026-09-15 (#145, §8.1)
- the Drift build does not enforce any of these drawer rules (the phase-1 divergence #24 accepted)

Read `docs/handoff_log/p7-closing-report-and-shift-guards.md` before touching `server/src/reports/`,
the void path or the returns path.

**Lane B catalogue, purchasing and quotes are merged. #16 → PR #112, #26 → PR #114, #27 → PR #115, all on
2026-09-14. #25 landed as LomerAlloys' PR #116.** Read
`docs/handoff_log/lane-b-catalogue-purchasing-quotes-cache-ops.md` before touching `server/src/products/`,
`purchasing/`, `quotes/`, `parked-sales/`, or the cache. Rules these slices established:
- 🔴 **Sync cursor.** `GET /products?updatedSince=&afterId=` is a keyset on `(updated_at, id)`, and the
  response carries `meta.nextCursor` at microsecond precision. A millisecond timestamp alone skips or
  re-serves rows, because every line of one bill shares the same `now()`. A row stamped at transaction start
  can still commit behind a cursor; until #55 decides a read-back window, that stays an open ADR-0010 bullet.
- 🔴 **Part-number uniqueness is enforced by Postgres, not the app.** Migration `1788652800007` adds
  `uq_products_partno_ci (tenant_id, lower(part_no)) WHERE deleted_at IS NULL`, and error 23505 maps to
  `409 DUPLICATE_PART_NO`. The trigram search index is **not** used under RLS, because `textlike` is not
  leakproof. An `EXPLAIN` run as superuser lies about the plan, so check it as `pos_app`.
- 🔴 **Receive lock order is PO row → products in id order.** The weighted-average cost rounds exact satang
  half-up, which deliberately differs from Dart's float `round2` on half-satang cases (a unit test pins it).
  A part on two PO lines writes **one** combined movement, because of `uq_movements_ref`.
- 🔴 **Quote convert** locks the quote, then runs `SalesService.create` in the same transaction, so a refusal
  rolls back the quote and the idempotency claim. Owner questions are recorded in 02 §3.8: convert is
  all-or-nothing while Checkout edits the cart, and deleting a converted quote is still allowed.
- **Since then:** #32 merged as PR #125 (per-tenant generation tokens, no `KEYS`); #64 merged as PR #113.
  #39 (PR #110) and #63 (PR #111) are merged, but branch protection is still not set (07 §4).
- 🔴 **Stacked PRs don't retarget themselves when their base merges** unless the base branch is deleted. Retarget
  them to `main` before merging, or they land on the dead feature branch.
- 🔴 **Parallel agents against one dev database:**
  - The e2e tests hardcode ports 5432/6379/6380, so serialise migrate and e2e runs behind a lock, and give each
    branch its own migration id.
  - `pnpm db:migrate` needs `DATABASE_URL` set explicitly.
  - A subagent that waits on a background task is never woken, so run e2e in the foreground.

**#123 → PR #130 and #120 → PR #129 are merged (2026-09-14).** Read
`docs/handoff_log/ops-123-120-platform-audit-etcd-watch.md` before touching `server/src/platform/` or
`server/src/config/runtime-config.service.ts`.
- 🔴 **A platform write audits inside its own transaction.** `platform/audit.service.ts` is
  `log(runner, input)` with no default connection; `createTenant`, `updateStatus` and the import pass the
  transaction's `manager`, so an audit failure rolls the write back. `PlatformAuthGuard` now checks
  `platform_admins` (cached `pa:<id>:exists`, 60s) — a future deactivate path must `DEL` that key.
- 🔴 **A value `net.isIP` accepts can still fail Postgres `inet`** (`fe80::1%eth0`). Once the audit is
  inside the transaction, a bad client header rolls back the business write — validate, then insert.
- 🔴 **Every etcd reconnect goes through backoff**, including a stream that ends cleanly, and the counter
  resets only on a delivered event. The first cut reset on HTTP 200 and broke out on `done`, which looped
  2,001 watches in 50 ms in a probe. The watch resumes at the last seen revision + 1.

**#132 → PR #133, #134 → PR #136, #124 → PR #137, #121 → PR #135 and #64 → PR #113 are merged (2026-09-14).**
Read `docs/handoff_log/ops-auth-cache-monitoring-etcd.md` before touching auth rate limits, client IPs,
`TenantCache`, `deploy/ansible/deploy.yml` or the etcd service.
- 🔴 **Nginx must be the only proxy in front of the API.** `configureApp` sets `trust proxy` = **1** (never
  `true`, which trusts the client-written leftmost entry), and `common/client-ip.ts` `clientIp()` takes the
  rightmost `X-Forwarded-For` entry. Put a CDN or a second reverse proxy in front and every client shares one
  login bucket again (#134) — use nginx `real_ip`, not a hop-count bump.
- 🔴 **Login throttles before it spends a connection, and counts before it knows the outcome** (#136, #138 → PR
  #146). The IP lockout runs before `qr.connect()`. `consumeAttempt` is one Lua `INCR` (expiry set in the same
  script), so concurrent attempts cannot all pass a check-then-increment. Every refusal counts — bad/retired
  device token (IP only), unknown/ambiguous/inactive user, suspended tenant, wrong password. A success
  `refundAttempt`s only its own IP attempt (never clears the IP bucket — that was username spraying) and clears
  the username bucket `auth:user:<tenant>:<username>` (tokenless backoffice logins share `-`). Keys are
  `rl:<sha256>:<window>` — the old character-replacing sanitiser made equal-length Thai usernames collide.
  `AuthController` uses `clientIp(req)`. The void manager-PIN path uses `consumeAttempt` too since #154:
  once tx.5 moved argon2 out of the claim's transaction, nothing bounded its old check-then-increment
  (60 of 60 concurrent wrong PINs reached argon2); `test/void-pin-burst.e2e-spec.ts` pins 5.
- 🔴 **The stampede lock is on `GET /products` only**, released in `finally`. `TenantGuard` and `byId` were
  measured at 0.008 / 0.026 ms and deliberately left without one — at 1–7 ms the list lock saves duplicate
  Postgres work, not latency.
- 🔴 **Monitoring never fails a POS deploy.** `deploy.yml`'s POS steps use `pos_compose_files` (no
  `monitoring.yml`); `/health/ready` and `.current_sha` come first, then the copy, prune, pull and `up` of the
  overlay all run in one `block`/`rescue`. Prune compares `relpath`s on both sides — a one-sided `realpath`
  deleted every config file when the playbook ran through a symlinked path. Not yet run on the VM.
- 🔴 **Deploy prerequisite:** `DEMO_ENV_FILE` must gain `ETCD_ROOT_PASSWORD` **and** `GRAFANA_ADMIN_PASSWORD`
  (strong random values, not `.env.example`'s), then re-run `provision.yml`. A missing `ETCD_ROOT_PASSWORD` fails
  the next Ansible deploy at compose interpolation; a missing Grafana password only leaves monitoring down.
  CI is unaffected.
- 🔴 **#67 was closed without its workflow.** `.github/workflows/deploy.yml` has never existed in git history
  (not on `feat/67-auto-deploy` either); #67 is reopened. Deploys are `ansible-playbook` by hand until it lands,
  so 07 §2's "merge → deploy.yml" arrow is design, not fact. An agent building it was stopped by the Claude Code
  permission classifier ("Production Deploy") — it needs the owner's explicit go-ahead.
- **Merged 2026-09-14 (orchestrated round):** #141 → PR #157 (e2e runner lock), #140 → PR #158 (ioredis
  `commandTimeout`, `REDIS_COMMAND_TIMEOUT_MS` default 1000 ms, not on BullMQ connections), #144 → PR #159
  (`src/devices`), #143 → PR #155 (login screen + redirect, `USE_API_WRITES` only), #148 → PR #156.
  🔴 **#156 changes the base compose network (`ip_range` + `gateway`)**: an existing host's network must be
  recreated once — `deploy.yml` stops at a pre-flight check and 07 §7 has the `down --remove-orphans` step
  (never `-v`); dev machines need one `docker compose down` in `server/` too.
- **Merged 2026-09-14 (second round):** #161 → PR #164, #162 → PR #165, #160 → PR #166. Read
  `docs/handoff_log/orchestrated-round-2026-09-14.md`.
  🔴 **Guards count as "inside a request" (#162):** a global guard that takes a second pool connection while the
  middleware holds the first deadlocks the pool at `DB_POOL_SIZE` concurrent requests (10 s stall, then 500s).
  `RateLimitService.getTenantPlan` did that on a cold plan cache (every 5 min in production); #162 read it on the
  request transaction inside a savepoint, and since tx.4 (#153) removed that transaction it is a plain pool read taken
  before any `runTx` — nothing may take a connection before the guards. That — not a machine limit — was `200 concurrent bills`.
  🔴 **Node 24.15.0 on Windows crashes e2e workers (#160)** — `0xC0000409` in libuv's `uv__tcp_try_connect`
  (libuv#5107). Use Node **≥ 24.16.0** on Windows dev machines; e2e setup warns. CI (Linux) is unaffected.
  🔴 **Never edit files under `node_modules` for debugging** — pnpm hard-links them from one store, so the edit
  leaks into every worktree and the main checkout (it did, during #160).
- **Merged 2026-09-15 (tx.* migration, #142 closed):** #149 → PR #167, #150 → PR #168, #151 → PR #170,
  #152 → PR #171, #153 → PR #172, #154 → PR #174. Handler-scoped transactions are in force (ADR-0003 addendum
  **Accepted**); the longest void transaction went ~112 ms → 13–24 ms, flat latency. Read
  `docs/handoff_log/tx-migration-2026-09-15.md` before touching `common/request-context.ts`, `TenantService`,
  `idempotency/` or the void path. 🔴 Three architecture specs now gate the seam — `tenant-door.spec.ts` (who may
  hold a pool / name a tenant), `tenant-wrapper.spec.ts` (every public context reader goes through `runTx`) and
  `idempotency-routes.spec.ts` (the 38 pinned claiming routes, claim first, `successCode` = `@HttpCode`); change
  them deliberately, never to get green. 🔴 A new write route with **no** claim at all is still invisible to them.
  Follow-ups filed: #169 (`idem.cleanup` without a tenant deletes 0 rows under RLS), #173 (cached reads open a
  transaction before checking Redis), #175 (role/no-PIN void-denial audit rows can drop in a burst).
- **Settled 2026-09-15 (owner):** #145 + #163 — Thai wording for `SALE_NOT_IN_OPEN_SHIFT` and the four device
  errors (02 §8.1, `ServerErrorResolver`); enrol/retire stays **owner only**; enrol code 15 min single use; the
  plaintext code in `idempotency_keys` is accepted; one `เข้าสู่ระบบไม่สำเร็จ` for every login 401; code re-issue,
  label edit and a client device screen are **phase 2** (ADR-0004 *ยังไม่เคาะ*). PR #176; read
  `docs/handoff_log/owner-decisions-145-163.md`.
- **Merged 2026-09-15 (tx follow-ups):** #169 → PR #177 (global `idem.cleanup` fans out per tenant;
  scheduled hourly since #182), #175 → PR #178 (audit pool timeout 10 s; loss not reproducible for role denials, burst pinned),
  #173 → PR #179 (🔴 cached reads: Redis first via `authorisedTenantId()`, `runTx` loader only on a miss — never
  open `runTx` before `singleFlight`). Read `docs/handoff_log/followups-169-173-175.md`.
- **Merged 2026-09-15:** #183 → PR #197 — `ApiClient` timeouts: reads and `/auth/refresh` 15 s, writes 40 s
  (nginx's own worst case is ~34 s). 🔴 A timeout throws `ApiTimeoutException` (a `ClientException`, never an
  `ApiException`): it is **not a verdict**, so `PendingWrites` keeps the id + key. 🔴 Every #55 transport fallback
  in `data/repositories/api_*.dart` has `on ApiTimeoutException { rethrow; }` before its `catch (_)` — a timed-out
  write may have committed, and falling back ran it twice locally; `api_repository_contract_test.dart` enforces it.
  A reset socket still falls back (pre-existing). Follow-ups: #199 and #200 (merged 2026-09-15).
- **Merged 2026-09-15:** #182 → PR #198 — `JobSchedulerService` upserts the global `idem.cleanup` as a BullMQ job
  scheduler (id `idem-cleanup-global`, every hour; BullMQ 6.3.4 runs the first occurrence **immediately** on first
  registration, not at the next hour). 🔴 It lives in `QueueSchedulerModule`, imported **only** by
  `WorkerModule.forRoot` — never add it to `QueueProcessorsModule`, which e2e files import: the first cut did, and
  every such test app registered the scheduler, fanned DELETEs over every dev tenant and left it in shared Redis.
  🔴 Renaming the scheduler id orphans the old scheduler in Redis — remove it (`removeJobScheduler`) in the same change.
  A scheduler e2e must clear the queue first and drain active jobs before `app.close()` (`idem-cleanup-scheduler.e2e-spec.ts`).
- **Merged 2026-09-15:** #201 → PR #205 — `DEFAULT_JOB_OPTIONS.backoff` is BullMQ's **builtin**
  `{ type: 'exponential', delay: 1000, jitter: 1 }` (full jitter). The old custom `'exponential-jitter'` type was never
  registered: a failing job threw `Unknown backoff strategy` and stuck `active` with `attemptsMade` 0 (no retry, no
  DLQ). 🔴 Keep backoff a builtin type — a custom type needs `settings.backoffStrategy` on **every** Worker (it is a
  per-Worker option, `@Processor(name, opts)`), and a strategy that throws recreates the same stuck-`active` failure.
  `jitter-backoff.ts` is deleted; `test/backoff-strategy.e2e-spec.ts` pins retry + `failed` on a Worker with no settings.
- **Merged 2026-09-15:** #188 → PR #204 — `GET /api/v1/doc-counters` (`pos` only, device from the token's `did`,
  retired device → 403) returns the calling device's high-water marks for every period plus the tenant's current
  `period`, computed by the issuer's shared `TENANT_PERIOD_SQL` (never copy it). Client: Drift **schema v6** —
  `doc_counters` / `doc_counter_seeds` keyed by server **`deviceId`**, not `deviceNo` (`device_no` repeats across
  tenants; a browser re-enrolled from the demo tenant kept its old counters). `DocCounterSeeder` applies
  `local = max(local, server)` and the seeded marker in one local transaction on every `Authenticated` of a `pos`
  device (`USE_API_WRITES` only); a failure never blocks sign-in. 🔴 A seeded marker proves only that a seed happened
  at `seededAt`, **not** that the counter is current — in phase 1 the server keeps issuing after the seed and the
  client does not advance from write responses; #189 must re-seed or compare before trusting it (hazards on #189).
- **Merged 2026-09-15:** #199 → PR #209 (Thai connection sentence at the counter via `resolveCounterError`) and
  #200 → PR #208 (`AbortableRequest` cancels a timed-out request). The post-merge review found no regression (#183
  invariants hold, abort proven on a live socket, verdicts keep their Thai text). Follow-ups #219 (`http ^1.5.0`,
  200 ms timers, test fixtures), #221 (the credit-payment re-ask only handles the server's
  `CREDIT_PAYMENT_EXCEEDS_BALANCE`, not the local `OVERPAYMENT_NOT_ALLOWED`). 🔴 After a timeout Checkout still says
  "ขายไม่สำเร็จ" although the bill may have committed — editing the cart then mints a new id + key and can ring a
  second bill; the wording is the owner's call (#220).
  #200 rules: all client requests route through `http.AbortableRequest` with an `abortTrigger` completed on timeout
  in `ApiClient._withTimeout` — an abandoned XHR in the browser is cancelled immediately so it does not tie up
  one of ~6 HTTP/1.1 connection slots per host. 🔴 It still throws `ApiTimeoutException` (subclass of
  `http.ClientException`), so it remains a transport failure (never an `ApiException`/verdict), `PendingWrites`
  keeps the attempt parked, and credit payments remain queued in Drift. A 401 retry creates a fresh `AbortableRequest`
  with its own `abortTrigger`.
  #199 rules: `ServerErrorResolver.resolveCounterError` centralizes counter error formatting across Checkout, Returns,
  Cash Drawer, and Mechanics credit payments — on `ClientException` (incl. `ApiTimeoutException`) and `TimeoutException`
  it renders the canonical Thai connection sentence (`เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์`), exactly mirroring
  `AuthCubit.loginRefusalMessage`; raw exception text and backend URLs never reach the counter UI; server verdicts
  (`PosException`) still render their own message verbatim; exceptions quoting URLs are defensively masked to the
  connection sentence.
- **Decided 2026-09-15 (owner):** #187 + #191 → PR #214 (supersedes PR #206, corrects PR #210). Offline PIN for
  `cashier` only, device-bound, valid 3 days since the last online login on that device, Degraded mode only, re-checked
  on `/sync/push`. Reconnect = push outbox then pull; products with pending ops are not overwritten until pushed;
  `offlineOk` computed on the client; keyset cursor with a **30 s** rewind + tombstones; no `change_log`. Still open in
  ADR-0009: offline PIN vs online credential reuse, re-login vs background JWT exchange, void offline. Implementation
  #211 / #212. Read `docs/handoff_log/owner-decisions-187-191.md`.
- **Merged 2026-09-15:** #213 → PR #215 — the transaction ceiling ADR-0010's 30 s rewind depends on. 🔴 A **25 s
  commit guard** (monotonic mark before `BEGIN`, rollback + `CommitCeilingExceededError` before `COMMIT`) in
  `TenantService.runTx` and `TenantJobRunner` bounds commit − `now()` for any number of statements; role `pos_app` gets
  `statement_timeout=25s` and `idle_in_transaction_session_timeout=5s` (migration `1788652802131`; Postgres 16 has no
  `transaction_timeout`). 🔴 Never make `statement_timeout` ≤ `CLAIM_LOCK_TIMEOUT` — the first cut (5 s) made
  `503 IDEMPOTENCY_KEY_IN_FLIGHT` unreachable and killed all-time reports (57014 at 5 s on 550k bills). 🔴 A pool
  holder that writes a table clients pull by `updated_at` must commit through the guard (`tenant-door.spec.ts`); the
  tenant export is the only opt-out (`exemptFromCommitCeiling`). Role-in-database settings are lost by a plain
  `pg_dump`, and running processes keep old values until they reconnect — `DbModule` warns at boot on a mismatch.
  A dev DB that ran the short-lived id `1788652802130` must delete that `migrations` row and re-migrate.
  `TenantJobRunner` also stopped losing the DLQ after a failed rollback or a failed `BEGIN`.
  Follow-up #217: tenant import stamps historic `updated_at`, so already-synced devices never pull imported rows.
- **Still open:** #67 (needs the owner's go-ahead); branch protection on `main`
  (owner runs 07 §4, #186); #217; #219–#221. Lane A's phase-1 close-out and the phase-2 ADR risks are ticketed under #196;
  the owner decided 2026-09-15 to clear all of it before starting phase 2 — read
  `docs/handoff_log/lane-a-closeout-round-2026-09-15.md` for the ordered next steps. The repo's only long-lived
  branches are `main` and `POC_sample_offline_first`.

**Pending follow-ups (not yet built).** Deployment/hosting is owned by `docs/Backend_design/07_CICD_DEPLOY.md` since 2026-09-10 (ADR-0013); before that it had no owning document — the old
`docs/PLAN.md` and `docs/BACKEND_DEPLOYMENT.md` were deleted in `ec24f79` and are **not coming
back** (decided 2026-09-04). Recover from git history if you ever need the Supabase-era text:
- **Cloud snapshot backup (Supabase) — Phase 7a**, stubbed/not wired (needs project creds).
  Do first: dev/prod env split, then scheduled+manual backup + restore drill.
- **Record-level sync — Phase 7b**, optional until a second device exists. ~~Prerequisite:
  add `updatedAt` to `customers`/`mechanics`/`settings`~~ — **done 2026-09-04** (schema v2:
  `updatedAt`/`deletedAt` on those three + `saleItems.costAtSale` per ADR-0008, with an
  `onUpgrade` migration; write paths wired). ~~Note `products.updatedAt` is still never
  written by the app~~ — **done 2026-09-10** (schema v3, #53): all six paths that change a
  product row stamp it (add / update / adjustStock / saveSale / createReturn / receivePO).
- **Software hardening — Phase 8a** (anywhere, can parallel Phase 7): manager-PIN gate,
  audit log, PDPA, **bundle Sarabun/Barlow fonts as assets** (currently `google_fonts`
  runtime fetch — set `GoogleFonts.config.allowRuntimeFetching = false` in tests to avoid
  a pending-timer leak).
- **Native hardware — Phase 8b** (needs shop access): thermal printer / cash-drawer kick /
  barcode **scanning** (camera); scan actions currently use manual entry.
- **Security (2026-09-09 review)** — compose hardening landed the same day: both Redis run with
  `--requirepass` (`REDIS_PASSWORD`, carried in `REDIS_*_URL`) and **no datastore port is published
  to the host** — `docker-compose.yml` keeps Postgres/Redis on the compose network only, while
  `server/docker-compose.dev.yml` publishes 5432/6379/6380 on loopback **for dev machines and CI
  runners only, never the VM** (`server/README.md`, `04_QA_SCRUTINY.md` รอบ 4 เพิ่มเติม). Also:
  ADR-0009 addendum *"การเซ็นและที่เก็บ token"* (RS256 + `kid`,
  `typ` claim, access in memory / refresh in IndexedDB) binds #4; **#43** owns the `audit_log`
  writer (auth events with #4, money/stock writes call it); **#44** `sec.1` owns Helmet/CORS,
  per-user auth rate limits, the negative-path e2e suite, CodeQL after #4+#20, and a one-off ZAP
  baseline before submission. OWASP Top 10 mapping lives in `04_QA_SCRUTINY.md` รอบ 4.
- **Multi-tenant client work** — the Flutter side of phase 1/2: an `ApiRepository` layer behind the
  existing repository interfaces (`03_ARCHITECTURE.md §8` task `q1`) that **writes through to
  Drift** and maps at the repository boundary ([ADR-0010](docs/Backend_design/adr/0010-client-write-through-cache.md)),
  then the outbox + `offlineOk` shell. Thai strings for the 7 new server errors now have
  **agent-drafted placeholders** accepted by the project owner (`02_API_SCREENS.md §8.1`) — three
  of them are counter-facing and still need the shop's own wording. Never invent new ones.
- **Re-capture tutorial screenshots** from the Flutter app (current images are from the JS app).
- Carried from JS (beyond 8a): full tax invoice (ใบกำกับภาษีเต็มรูป) — out of scope for v1.

---

## Conventions

- **Thai UI strings = behaviour parity** — copy exactly from `db.js` / the `.jsx`; never translate.
- Money via `baht()` / `round2()` — or `baht2()` where the display is fixed 2-decimal
  (cost/margin views); never inline `'฿${…toStringAsFixed(…)}'`.
- Date-string keys (yyyy-MM-dd / yyyy-MM, the db.js `slice(0,10)` idiom) via
  `core/utils/dates.dart` (`dateKey`/`todayKey`/`monthKey`); never re-slice inline.
- Thai date/time display via `presentation/widgets/thai_format.dart`
  (`thaiDate`/`thaiDateTime` for "23 มิ.ย. 2569", `thaiDateSlash`/`thaiDateTimeSlash`
  for the numeric "23/06/2569" CSV/receipt shape); no private per-file formatters.
- Status pills via the shared `StatusChip` widget (`StatusChip.of` for the common keys, or an
  explicit label+tone where the JS labels differ, e.g. PO 'open' → รอรับสินค้า).
- Quote expiry/converted checks via the `QuoteRowStatus` extension in
  `domain/models/aggregates.dart` (`q.isExpired` / `q.isConverted`).
- Screens consume **repository providers + Drift row classes** — never touch `AppDatabase`
  directly from a screen.
- Each screen file owns its sub-views (Receipt, ClosingReport, QuotesManager, etc.) per
  `CONTRACT.md §5`.

## Legacy app & full plan

The legacy JS app (source-of-truth-until-cutover) and the full migration plan live in the
**"Srisurart Autopart Design System"** repo. Tag **`v1.0-js-localstorage`** there marks the last
pure-JS/localStorage state.
