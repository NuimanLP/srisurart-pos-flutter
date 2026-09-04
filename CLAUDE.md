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

## Build / test commands

```
dart analyze                              # NOT flutter analyze
flutter test                              # unit + repository + smoke tests
flutter build web --no-tree-shake-icons   # web build (replaces POS.html on the shop PC)
dart run build_runner build               # ONLY after Drift schema changes — ASCII path only
```

---

## Architecture (layered: data → domain → presentation)

```
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
CONTRACT.md                  ← THE binding spec: tables, repo signatures, providers, routes,
                               screen→sub-view ownership, Thai-string rules. Read it first.
test/                        ← repo unit tests (per transactional rule) + route smoke tests
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

## Migration status (Phase 0–6 complete) — see legacy `PLAN.md`

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
`_refresh()`). `flutter_riverpod` fully removed from `pubspec.yaml`. Plan + rationale:
`docs/plans/riverpod-to-bloc.md`.

**Backend direction changed (2026-08-25) — read `docs/Backend_design/` first.** The team now has
backend help and the stack is fixed by the course/assignment to **NestJS + PostgreSQL + Redis +
BullMQ + Nginx**, with **multi-tenant** (many shops, one database) added to the scope. That
supersedes the Supabase-as-backend decision below on three points: a custom server now exists,
**PostgreSQL becomes the source of truth** (Drift drops to a read cache), and the transactional
invariants move server-side. The package is `docs/Backend_design/` — `00_BASICS.md` (backend
primer), `00_INDEX.md` (map + open decisions), `01_DATABASE.md` (28 tables + DDL + invariants),
`02_API_SCREENS.md` (all 11 screens → endpoints), `03_ARCHITECTURE.md` (3 options + rollout),
`04_QA_SCRUTINY.md` (design review record), and **`adr/` — the binding decision record**
(ADR-0001…0007: tenant provisioning, platform-admin plane, tenant lifecycle, device roles,
data portability, per-tenant rate limit, receipt numbering). **Where a doc contradicts an ADR,
the ADR wins.** Nothing is built yet, and **no cutover is planned
for phase 1** — the shop keeps running this Drift build while the server is developed against a
demo tenant. **As of 2026-09-04 this work happens on `main`** (see *Branch strategy* above): the
server, the client's API layer and the CI/CD pipelines all land in this repo.

**CI/CD (not built yet) — the next thing to stand up.** `.github/workflows/` is still empty; the
repo has no pipeline of any kind. Target shape, smallest first:
1. **Flutter CI** — `dart analyze` + `flutter test` on every push/PR (mirrors the local gate).
   Runners are ASCII paths, so `build_runner` verification can also run in CI.
2. **Backend CI** (once `server/` exists) — lint + unit + integration tests on a Postgres/Redis
   service container; the phase-1 done-criteria tests in `03_ARCHITECTURE.md §8` are the target.
3. **Build/deploy** — Flutter Web artifact for the shop PC (`docs/BACKEND_DEPLOYMENT.md §3` owns
   this), then container images for the server + `docker compose up` smoke check.

**Pending follow-ups (not yet built)** — phase numbers per the revised `docs/PLAN.md` (2026-07-03).
`docs/BACKEND_DEPLOYMENT.md` (2026-07-13) still owns **deployment/hosting** (§3: Flutter Web build
→ shop PC, Android/iOS, CI) — its §1–2 (Supabase hierarchy) are superseded by the package above:
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
- **Multi-tenant client work** — the Flutter side of phase 1/2: an `ApiRepository` layer behind the
  existing repository interfaces (`03_ARCHITECTURE.md §8` task `q1`), then the outbox + `offlineOk`
  shell. Thai error strings for the new server errors are **still unresolved** (`00_INDEX.md` open
  item 3) — never invent them.
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

The legacy JS app (source-of-truth-until-cutover) and the full migration `PLAN.md` live in the
**"Srisurart Autopart Design System"** repo. Tag **`v1.0-js-localstorage`** there marks the last
pure-JS/localStorage state.
