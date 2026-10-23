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

## 🌿 Branch strategy (set 2026-09-04; `develop` added 2026-10-06)

Three long-lived branches. Know which one you are on before you change anything.

| Branch | What it is | Status |
|---|---|---|
| **`main`** | **The multi-tenant line** — Flutter **client** + NestJS **backend** + **CI/CD**, per `docs/Backend_design/` (Architecture C phase 1 = A, tenancy model T1) | **Release line.** Receives `develop` only; every code push builds images and triggers a deploy. |
| **`develop`** | Integration branch for the `main` line (owner decision 2026-10-06) | **Active.** Every work PR targets `develop` (`gh pr create --base develop`). |
| **`POC_sample_offline_first`** | Frozen **proof-of-concept snapshot** of the offline-first, Drift-only build (branched from `main` at `4dae2f0`) | Reference only. Do not build on it. |

**What this means in practice:**
- `main` grows a **server** (NestJS + PostgreSQL + Redis + BullMQ + Nginx) and **pipelines**
  (`.github/workflows/`) alongside the existing Flutter app — it is no longer a Flutter-only repo.
- **PostgreSQL becomes the source of truth**; Drift drops to a read cache / offline shell, and the
  transactional invariants (`saveSale`, `createReturn`, `receivePO`, shifts) move **server-side**.
  The Dart repositories stay the behavioural reference for those rules — port them, don't reinvent.
- `POC_sample_offline_first` preserves the offline-first build exactly as the shop runs it today,
  so the phase-1 rule **"the shop keeps running the Drift build, no cutover"** stays testable.
- The offline-first design is **not abandoned** — it returns as **phase 2** (outbox + ~~`offlineOk`~~ — dropped 2026-09-15, see 08
  + a single `role='pos'` writer per tenant, ADR-0004). The POC branch is its starting point.

🔴 **`develop` → `main` = merge commit only — now enforced (2026-10-06).** Squash/rebase rewrites the
SHAs, so `bedd328` (the `ROLLBACK_FLOOR` in `deploy/scripts/pos-deploy.sh`) would stop being an
ancestor of `main` and `pos-deploy` would refuse every SHA. Repository ruleset 24564072
"main: merge commit only" (active, no bypass actors) refuses squash and rebase on PRs into `main`;
PRs into `develop` may still squash. `develop` has the same branch protection as `main`.

🔴 **`develop` → `main` showing "conflict" while `git merge` is clean = criss-cross merge bases**
(`git merge-base --all` prints 2+): merge `main` into `develop` with a merge-commit PR (#673), never squash.
🔴 **Never enable auto-merge on a PR an agent is still pushing to** — a push after the merge button
misses the base; check `gh pr view N --json headRefOid` at merge time (details: `docs/rules/client-write-path.md`).

**Last release, deploy evidence and the full release log:** `docs/status.md`.

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
- 🔴 **BeeStation cloud placeholders break `docker build` on this checkout** (found
  2026-09-21, `docs/handoff_log/demo-rehearsal-dev-2026-09-21.md`). After a `git pull`,
  most files under `server/src/` can be dehydrated placeholders (`Attributes` =
  `Archive, ReparsePoint`), and BuildKit refuses the context with
  *`load build context: invalid file request …`*. `builder prune` does not help. Build
  from a clean git-object context instead:
  `git archive HEAD server | tar -x -C <ascii-tmp>/ctx && docker build …`, then
  `docker compose up -d` **without** `--build`. This is a *different* cause from the
  non-ASCII-path rule above, and it cannot happen on `mob04` (no build there).

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
      router/app_router.dart   ← GoRouter + AppRoutes (13 shell routes + /login). ShellRoute → AppShell.
      theme/                   ← navy/orange brand, Sarabun (Thai) + Barlow type
      utils/                   ← newUuid/newIdempotencyKey/docNo (ids.dart), baht/round2/pointsFor (money.dart),
                                 csvSafe (csv_safe.dart)
    data/
      db/tables.dart           ← 27 Drift tables, schemaVersion 15 (20 ported sa_* stores + #24's
                                 credit-payment outbox + phase-2 tables incl. OutboxOps, OpEffects
                                 + #676 PaymentAccounts; v15 = Products.imageKey) — recounted 2026-10-10
      db/database.dart         ← AppDatabase (@DriftDatabase) + seed data + AppDatabase.open()
      db/database.g.dart       ← GENERATED (committed). Regenerate ONLY on an ASCII path.
      repositories/            ← one repo per domain; transactional services mirror db.js
      repositories/api/        ← #56: ApiSales/ApiReturns/ApiShifts — same interfaces,
                                 server is the truth, Drift rows patched from the response
                                 (ADR-0010). Opt-in: --dart-define=USE_API_WRITES=true
    domain/models/aggregates.dart  ← SaleWithItems/… read aggregates + input DTOs (SaleInput…)
    presentation/
      repositories/repository_providers.dart ← flutter_bloc RepositoryProvider tree (25 entries:
                                 20 repos incl. AuthRepository and PaymentAccountsRepository, +
                                 ApiClient/BootstrapService/DocCounterSeeder/SyncFacade) — recounted
                                 2026-10-10; `useApi` swaps in the #56 API repos
      blocs/                    ← Cubits (ThemeMode, FontScale, UiZoom, PendingQuote, Cart)
      screens/                  ← 14 screen files: 12 in the AppShell nav + /devices + /login
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
- **openShift** — deliberately departs from db.js here (its "same day → return the open
  shift" is gone): several shifts a day (08 §11, #453). An `id` that already exists
  returns that shift unchanged; otherwise it archives the prior active shift first (even
  one opened today — never lose a day) and inserts a new one. `addDrawerEntry` blocked after close.
- **quotes / parked** never touch stock. **adjustStock** DOES clamp at 0 (manual adjustment).
- **snapshot** — `exportSnapshot()` emits the JS `sa_*` + `__meta` backup shape;
  `importLegacyBackup()` atomically imports a JS `DB.exportSnapshot()` JSON (zone→category
  migration, null-as-absent). This is the Phase-2 data-migration path.
- Entity ids via `newUuid()` (lowercase UUIDv7, #616); idempotency keys via `newIdempotencyKey(prefix)`;
  doc numbers via `docNo`; CSV via `csvSafe`.
- API build (`USE_API_WRITES`) never seeds demo business data; an already-seeded DB gets a one-time `purgeDemoSeed()` (skipped while outbox ops or queued credit payments exist; deletes only untouched `updatedAt IS NULL` seed rows no local record references; AppMeta marker `demo_seed_purged`, also set by `importLegacyBackup`). The seeded settings identity persists until the first successful `GET /settings`.

---

**CouchDB was considered and rejected (2026-09-08)** — PostgreSQL stays source of truth.
Reasoning: `docs/Backend_design/adr/0012-couchdb-replaces-postgres.md` (**Rejected**).

**Backend/multi-tenant stack (set 2026-08-25):** NestJS + PostgreSQL + Redis + BullMQ +
Nginx, multi-tenant (one database, many tenants). PostgreSQL is the source of truth;
Drift is a read cache; transactional invariants live server-side, ported from the Dart
repositories (don't reinvent them). Design package: `docs/Backend_design/` —
`00_BASICS.md`/`00_INDEX.md`, `01_DATABASE.md` (schema+DDL+invariants),
`02_API_SCREENS.md` (endpoints), `03_ARCHITECTURE.md` (rollout+DoD),
`04_QA_SCRUTINY.md`, and **`adr/`** — the binding decision record. **Where a doc
contradicts an ADR, the ADR wins.** Open questions only the owner can answer are
collected at the end of `adr/README.md`. Phase-2 spec/lanes: `docs/rules/phase2.md`.

---

### Binding rules from the phase-1 build (still enforced — read before touching the named area)

Each area's rules live in their own file, moved verbatim from this file on 2026-10-23. **Read the
file before touching its area** — the 🔴 rules there bind as much as anything above.

| Before touching… | read |
|---|---|
| server transactions, `TenantService`, RLS, lock order of money/stock writes | `docs/rules/server-transactions-tenancy.md` |
| idempotency, `api*` repositories, outbox/`PendingWrites`, 5xx handling, drawer cash, returns, settings writes, RC/CN counters | `docs/rules/client-write-path.md` |
| `.github/workflows/`, `deploy/`, `mob04`, branch protection, merging or deleting branches, APK, TLS CA, multi-arch, Tailscale | `docs/rules/ci-cd-deploy.md` |
| metrics names, Prometheus/Grafana/Gatus, alerting | `docs/rules/metrics-monitoring.md` |
| `nginx.conf`, login/auth, device tokens, rate limits, web token storage | `docs/rules/nginx-auth.md` |
| `server/src/products/`, the `GET /products` cursor, part numbers, PO receive | `docs/rules/catalogue-sync.md` |
| `presentation/` code, UI zoom, web build checks, tenant cache, customer/mechanic pull, web DB assets | `docs/rules/flutter-client.md` |
| product images, sale photos, barcode scan, supplier tab, PO print, VAT report, owner backup import | `docs/rules/features.md` |
| anything under `docs/Backend_design/` | `docs/rules/docs-writing.md` |
| phase-2 tickets, lanes, split tickets | `docs/rules/phase2.md` |
| claiming something is released/deployed/done, backups/offsite (#363), open tickets, history | `docs/status.md` |

**General lesson, learned the expensive way more than once (#22, #24, #260's import
pre-flight):** **validate input first, then clamp** — a `GREATEST`/`Math.max` clamp on
an unvalidated value turns a loud corruption into a quiet one.

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
