# Srisurart Autopart POS — Flutter (Project Knowledge Base)

Flutter migration of a Thai auto-parts shop POS, ported from the React-in-browser +
localStorage app (the "Srisurart Autopart Design System" repo; origin
github.com/NuimanLP/Sri-SuRat_Store). The shipped client is **offline-first**: Drift/SQLite +
flutter_bloc + go_router. Thai-first UI with EN labels. Targets **Android/iOS + Web**.
Since 2026-09-04 `main` is the **multi-tenant client + backend + CI/CD** line (see below); the
offline-first-only build is preserved on `POC_sample_offline_first`.

> **🔒 Read first — private operating instructions (machine-local, NOT in this repo).**
> Also read these from the local toolkit folder `D:\Beestation\A_Tooling\Codex-portable\`:
> - `AGENTS.md` — global working guidelines for this machine.
> - `skills-for-AGENTS.md` — skill-routing table (trigger → skill); invoke via the Skill tool.
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
      db/tables.dart           ← 20 Drift tables (ported sa_* stores from pos/db.js)
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
🔴 **`closeForRetirement` still has no production caller** — `src/devices/` does not exist, so the
ADR-0004 rule *"retiring a `pos` device closes its open shift in the same transaction"* is proved
only against a test-mounted probe controller (`test/shifts.e2e-spec.ts`). Whoever builds the device
endpoint must call it, and that wiring is the part no test covers today.
🔴 **A local DB one migration behind reads as a code bug:** this round began with 14 red returns
cases, all 500s, because the dev Postgres had never been given `1788652800004` (#22's
`return_items.cost_at_sale`) — `pnpm db:migrate:status` said *"up to date"* because `dist/` was
stale too. Rebuild before believing it. The `200 concurrent bills` case is still the known
machine limit, now with its cause measured: every 500 is `pg-pool`'s *"timeout exceeded when
trying to connect"* raised in `request-context.middleware.ts` **before routing** — the
request-wide transaction ADR-0003's `tx.*` slices remove, not a fault on the sale path.
Read `docs/handoff_log/p6.3-shifts-drawer.md` before #30 or a device slice.

🔴 **ADR-0003 was amended 2026-09-10 — the transaction is handler-scoped, not request-wide.** The
addendum's status is **Proposed** and takes effect only when slice `tx.4` lands; until then the
middleware → guard → interceptor split that #75 shipped is the in-force mechanism (the 2026-09-11
review found the first draft banned the very code the PR added).
The old split (middleware opens the transaction, the guard names the tenant on it, an interceptor
commits) was never chosen: it was forced by reading ADR-0003's "status check and `SET LOCAL` in one
component" as also binding *where the transaction lives*. Separating **who decides the tenant**
(the guard, unchanged) from **who executes `set_config`** (`TenantService.runTx`) keeps every ADR-0003
guarantee and deletes the middleware, `TENANT_ROUTES`, the `res.on('close')` backstop and the global
interceptor — and cuts the open-transaction hold from **112 ms to 18–28 ms** (measured, 4 concurrent
voids at `DB_POOL_SIZE=2`). The migration is **not done**: it is planned as six slices `tx.0`–`tx.5`
in `docs/Backend_design/adr/0003-handler-scoped-migration-plan.md`, and `tx.3` (idempotency) is the
one that fails silently and as money. 🔴 **`runTx` must never take a `tid` argument** — the amendment
is only safe because `runTx(fn)` cannot name a tenant the guard did not authorise; the
`TenantService` in the tree today still has the `runTx(tid, fn)` signature, and following it would
silently restore exactly what ADR-0003 banned, failing as a cross-tenant read that raises nothing.
The proving prototype is commit `0feaf94` on `worktree-agent-a1756ff02f223b4eb` (never merge it).
Until `tx.*` lands, `server/README.md` *The request-context seam* still describes the shipped code.

🔴 **The e2e suite cannot tolerate a second concurrent runner on the same database** —
`test/schema.e2e-spec.ts` tears the schema down and re-applies it. CI is safe (one Postgres per job),
two developers sharing a dev database are not; the symptom is a migration dying with
`terminating connection due to administrator command` and document numbers starting mid-series.
No ticket yet. `synchronize` is never
true anywhere, tests included. Phase-1 backend/CI tickets are assigned by lane: `NuimanLP`
(Lane A), `LomerAlloys` (Lane B), `PattaraponKitcharoen` (Lane C) — see
`handoff_log/merge-p1-p2-lane-assignments.md`. **No cutover is planned for phase 1** — the shop
keeps running this Drift build while the server is developed against a demo tenant. **As of
2026-09-04 this work happens on `main`** (see *Branch strategy* above): the server, the
client's API layer and the CI/CD pipelines all land in this repo.

**CI/CD — levels 1–3 are done (level 3 = both release images on GHCR since 2026-09-10, #69/#70). CD to the faculty VM (Ansible), etcd and Prometheus/Grafana are designed in `docs/Backend_design/07_CICD_DEPLOY.md` + ADR-0013 (spec #60) and ticketed #63–#67 under #10 for the teammates — read those before touching `.github/`, `deploy/`, `server/Dockerfile`, `server/docker-compose.yml` or `server/docker/nginx/`.** `.github/workflows/flutter.yml` is the
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
   🔴 **#40's AC4 is still open:** `push.paths` means a `server/`-only commit produces no web
   image and a `frontend/`-only commit no server image, so a full release exists only for a commit
   touching both. The fix — no `paths:` on push, PR-only filtering inside the workflow — is
   specified in 07 §2 and belongs to **#39**.

`server/` and the Flutter client share this repo ([ADR-0011](docs/Backend_design/adr/0011-monorepo.md)),
so PR runs are path-filtered — the Flutter jobs must not run on `server/`-only PRs.
🔴 **Known trap:** today's workflow-level `paths:` means a `server/`-only PR runs **no** Flutter
jobs at all; if those job names are required status checks on `main`, such a PR can never satisfy
them and blocks forever. Issue **#39** owns the fix, and its shape is decided (07 §2/§4): filter
inside the workflow on PRs only, two uniquely-named always-reported status jobs
(`flutter-ci-status`, `server-ci-status`) as the only required checks, `!cancelled()` semantics.

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

**#54 is merged (PR #81, 2026-09-12) and #56 is on `feat/fe3-api-writes` (PR open).** `fe.3` is the
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
- 🔴 **The bill id and `Idempotency-Key` are minted once per cart, not once per call.** `ApiClient`
  sets no timeout, so the ordinary failure is a dropped reply for a bill the server committed; a
  fresh id and key on the counter's second press defeat **both** server defences at once
  (`existingSale` keys on the client's bill id, `idempotency_keys` on the header) and ring the sale
  up twice. A `SocketException` parks the attempt, an `ApiException` is a verdict and closes it.
- 🔴 **Consent is carried, never inferred.** `SaleInput.overrideCreditLimit` exists because the
  first implementation replayed `checkout_screen.dart:561`'s own credit-limit test against the
  cached mechanic row on a 409 and treated a trip as proof the counter had confirmed. It is not the
  same read — the screen tests the row it captured when its list loaded — so it could override a
  limit nobody was shown a dialog for, and the server then writes an `audit_log` row recording a
  confirmation that never happened.
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
hit it in any debug build. Write `setState(() { x = …; })`, never the arrow form, when assigning.

**#83 is open** (`team/3`): `ServerErrorResolver` prefers *any* server message containing a Thai
codepoint over its own canonical string, so `returns.service.ts`'s English
`Refund method 'หักจากเครดิต' needs a bill with a mechanic.` wins and the mapped Thai never fires.
Three idempotency codes are unmapped too.

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
