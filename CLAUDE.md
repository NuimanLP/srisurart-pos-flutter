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
      db/tables.dart           ← 20 Drift tables (ported sa_* stores from pos/db.js)
      db/database.dart         ← AppDatabase (@DriftDatabase) + seed data + AppDatabase.open()
      db/database.g.dart       ← GENERATED (committed). Regenerate ONLY on an ASCII path.
      repositories/            ← one repo per domain; transactional services mirror db.js
    domain/models/aggregates.dart  ← SaleWithItems/… read aggregates + input DTOs (SaleInput…)
    presentation/
      repositories/repository_providers.dart ← flutter_bloc RepositoryProvider tree (13 repos)
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
client write-through cache, monorepo). **Where a doc contradicts an ADR,
the ADR wins.** The 2026-09-04 scrutinize round (3 agents) added binding addenda you must read
before server work: ADR-0004 *"การผูกเครื่อง"* (a device is a server-issued device token via
`POST /devices` + `POST /auth/device`; `did`/`drole` never come from the request body),
ADR-0007 *phase 1 = server issues every document number, phase 2 = the `pos` device issues
RC/CN only*, ADR-0009 *refresh also checks `devices.retired_at`*, ADR-0010 *`ApiRepository`
patches rows only and never calls the Drift transactional services; Drift schema v3
(`Sales.shiftId`, `Shifts.id` TEXT, `Products.offlineOk`) is due before `q1` ends*. The eight
questions only the shop/project owner can answer are collected at the end of `adr/README.md`.
**Server status (2026-09-07): `server/` exists — #14 `p1` and #15 `p2` are merged to `main`.**
Compose stack with Nginx + NestJS ×3 + Postgres + two Redis + worker + Bull-Board, health
probes, JSON logs; the 27-table schema as TypeORM migrations applied by a one-shot compose
`migrate` job, RLS enabled + forced on every tenant-scoped table, grants to the non-owner
`pos_app` role, the five-category seed; see `server/README.md` *Schema and migrations*. No auth
or business endpoints yet — **#4 `p3`** is next on the critical path. `synchronize` is never
true anywhere, tests included. Phase-1 backend/CI tickets are assigned by lane: `NuimanLP`
(Lane A), `LomerAlloys` (Lane B), `PattaraponKitcharoen` (Lane C) — see
`handoff_log/merge-p1-p2-lane-assignments.md`. **No cutover is planned for phase 1** — the shop
keeps running this Drift build while the server is developed against a demo tenant. **As of
2026-09-04 this work happens on `main`** (see *Branch strategy* above): the server, the
client's API layer and the CI/CD pipelines all land in this repo.

**CI/CD — levels 1–2 are done, level 3 is ticketed.** `.github/workflows/flutter.yml` is the
client gate (`dart analyze`, `flutter test`, `build_runner` no-diff, `flutter build web` + the
web-asset assertion), committed 2026-09-04. Level 3 remains the agreed target:
1. ✅ **Flutter CI** — done. Runners are ASCII paths, so `build_runner` verification runs in CI —
   the only place the committed `*.g.dart` is ever checked against the schema.
2. ✅ **Backend CI** — `.github/workflows/server.yml` (2026-09-06, #38): four jobs — lint,
   unit, integration, and `audit` (2026-09-09, #44: `pnpm audit --audit-level=high` + Trivy fs
   scan; `flutter.yml` gained `deps-audit` = OSV-Scanner on `pubspec.lock`; `.github/dependabot.yml`
   covers npm/pub/docker/actions weekly). A transitive CVE is fixed via `pnpm.overrides` in
   `server/package.json`, never by hand-patching. Integration starts the compose Postgres + both Redis (GitHub service
   containers cannot set the Redis eviction policies), applies the real migrations, then runs
   `test:e2e`; `synchronize` is false even in tests. Path-filtered to `server/**`.
3. **Build/deploy** — Flutter Web artifact + server container image on every green build —
   issue **#40**. The **deploy step stays unwired until a production host is chosen** (due
   before `q4`; the faculty VM is demo-only — `03_ARCHITECTURE.md §8`).

`server/` and the Flutter client share this repo ([ADR-0011](docs/Backend_design/adr/0011-monorepo.md)),
so every CI job needs a `paths:` filter — the Flutter jobs must not run on `server/`-only changes.
🔴 **Known trap:** `flutter.yml`'s `paths-ignore` means a `server/`-only PR runs **no** Flutter
jobs at all; if those job names are required status checks on `main`, such a PR can never satisfy
them and blocks forever. Issue **#39** owns that fix.

**Where the work lives — GitHub issues (since 2026-09-05).** `docs/Backend_design/` says *what* to
build; the issue tracker says *who builds what, in what order.*
- **#2** — phase-1 program brief: the full child tree plus the ownership table. Read it first.
- **#3 / #7 / #8 / #9 / #10** — parents. They hold shared context and carry **no**
  `ready-for-agent` label; do not implement them directly.
- **#14–#40** — the 27 implementable slices. Each is one PR's worth of work with its own
  acceptance criteria and real "Blocked by" numbers.
- **#11–#13** — decisions only a human can make (labelled `question`). **Never settle one in a
  PR**, especially #11 (`mechanics.total_credit`), where the design doc and the Dart reference
  disagree and reading either alone gives a confidently wrong answer.

🔴 **Course rule (2026-09-05): every team member must touch frontend, backend *and* CI/CD.** The
old "one backend lane each" split is therefore dead — all three lanes were backend. Work is now
three cross-cutting bundles of **9 backend slices + 1 CI slice + 1 frontend slice**, carried by
the labels `team/1` / `team/2` / `team/3`; the table is in #2. **As of 2026-09-07 the 31 issues
are also assigned to real GitHub handles**, not just labels: `NuimanLP` (`team/1`, transaction
path + #14 compose stack), `LomerAlloys` (`team/2`, schema/catalogue/reports), `PattaraponKitcharoen` (`team/3`,
platform/infra/ops). **The frontend slices are reserved but not yet ticketed** — they are task
`q1` + Drift schema v3, and they must be cut before anyone finishes their backend bundle.

**Pending follow-ups (not yet built).** Deployment/hosting has **no owning document** — the old
`docs/PLAN.md` and `docs/BACKEND_DEPLOYMENT.md` were deleted in `ec24f79` and are **not coming
back** (decided 2026-09-04). Recover from git history if you ever need the Supabase-era text:
- **Cloud snapshot backup (Supabase) — Phase 7a**, stubbed/not wired (needs project creds).
  Do first: dev/prod env split, then scheduled+manual backup + restore drill.
- **Record-level sync — Phase 7b**, optional until a second device exists. ~~Prerequisite:
  add `updatedAt` to `customers`/`mechanics`/`settings`~~ — **done 2026-09-04** (schema v2:
  `updatedAt`/`deletedAt` on those three + `saleItems.costAtSale` per ADR-0008, with an
  `onUpgrade` migration; write paths wired). Note `products.updatedAt` is still never
  written by the app — it only round-trips through snapshots.
- **Software hardening — Phase 8a** (anywhere, can parallel Phase 7): manager-PIN gate,
  audit log, PDPA, **bundle Sarabun/Barlow fonts as assets** (currently `google_fonts`
  runtime fetch — set `GoogleFonts.config.allowRuntimeFetching = false` in tests to avoid
  a pending-timer leak).
- **Native hardware — Phase 8b** (needs shop access): thermal printer / cash-drawer kick /
  barcode **scanning** (camera); scan actions currently use manual entry.
- **Security (2026-09-09 review)** — ADR-0009 addendum *"การเซ็นและที่เก็บ token"* (RS256 + `kid`,
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
