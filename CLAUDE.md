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
- The offline-first design is **not abandoned** — it returns as **phase 2** (outbox + ~~`offlineOk`~~ — dropped 2026-09-15, see 08
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

## Migration status (Phase 0–6 complete; phase-1 backend/CI/CD built; phase-2 in progress)

**Full build log archived.** Every merged PR, bug found, and owner decision from
2026-06-24 through 2026-09-17 — the backend stand-up, all three CI/CD levels, the
phase-1 lane-A/B/C work, and the phase-2 kickoff — is preserved verbatim in
`docs/handoff_log/claude-md-full-history-archive-2026-09-17.md`. Read it for the *why*
behind any rule below, or the story of a specific PR/ticket this section only names.
What follows is current state plus the rules from that log that still bind new code.

**Done:** scaffold; data layer + unit tests; all 11 screens; shared UI kit + nav; shifts
layer; adversarial scrutiny + fix pass; web-DB runtime wired. App `dart analyze`-clean,
tests green, `flutter build web` ok. Riverpod → flutter_bloc migration done (2026-07-14,
`handoff_log/riverpod-to-bloc.md`).

**Web DB:** needs `web/sqlite3.wasm` + `web/drift_worker.js` matching the pub-locked
`sqlite3`/`drift` versions (`frontend/web/WEB_DB_ASSET_VERSIONS.txt`); CI fails the build
on any skew. 🔴 **Bumping `drift` or `sqlite3` → re-download both assets from the
matching GitHub release tags and update the version file** — a skew changes SQLite-core
or worker-cancellation behaviour, it isn't cosmetic. 🔴 **#266** (browsers without
`dedicatedWorkersInSharedWorkers` hit a `LinkError` on `xFileControl` in drift's
non-OPFS fallback): a fix (stub `xFileControl` → `SQLITE_NOTFOUND`) merged 2026-09-17
by `LomerAlloys` (`docs/handoff_log/ticket-266-web-db-linkerror.md`), but the GitHub
issue itself is still open — verify it's actually closed before assuming #241 (PWA
precache manifest) is unblocked.

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
collected at the end of `adr/README.md`. Phase-2 spec/lanes: see below.

**Where work lives:** GitHub issues, not this file. `#2` is the phase-1 program brief;
`#3/#7/#8/#9/#10` are parents (no `ready-for-agent` — don't implement directly);
`#11–#13` are owner-only decisions, never settled in a PR. Phase-1 lanes: `NuimanLP`
(team/1), `LomerAlloys` (team/2), `PattaraponKitcharoen` (team/3) — every member
touches frontend, backend *and* CI/CD (course rule, 2026-09-05).

**Status:** the phase-1 backend (server, RLS, transaction/idempotency seam, all three
lanes' slices) and the frontend API-write layer (`fe.0`–`fe.3`) are merged. CI/CD levels
1–3 are done (Flutter CI, backend CI, GHCR release images with Trivy gating); level 4
(Ansible deploy to the demo VM, monitoring, etcd/`RuntimeConfigService`) is **partial**
— see "Still open". The 2026-09-16 DoD audit (PR #265) ticked 5 of 13
`03_ARCHITECTURE.md §8` boxes with file:line evidence; the other 8 are documented open
gaps, not fabricated ticks — check that section for the current real count before
claiming phase 1 is "done". No cutover: the shop still runs the Drift build; the server
develops against a demo tenant.

**Still open (phase 1):**
- #67 — self-hosted deploy runner: workflow merged (PR #237), but not installed on the
  demo VM; real-run ACs unproven (`PattaraponKitcharoen`).
- #184 / #251 — the three-laptop k6 load-test run (`PattaraponKitcharoen`).
- #272 — drop `Products.offlineOk` (Drift schema v7) — in progress on `LomerAlloys`'
  `lane2` branch as of 2026-09-17.
- Phase-2 kickoff order for the remaining hub tickets: #228 → #229 → #212/#211/#189 →
  #230 → #190 → #231.

The repo's only long-lived branches are `main` and `POC_sample_offline_first`.

---

### Binding rules from the phase-1 build (still enforced — read before touching the named area)

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

**Idempotency & the client write path (`server/src/idempotency/`, `frontend/lib/data/repositories/api*`):**
- The idempotency fingerprint is the **concrete request path**, never `req.route.path`
  (the pattern) — a reused key on two different bills must not collide.
- Only a **4xx is a verdict** (`isVerdict`); a 5xx, a 429, or a lost/timed-out reply
  means the write's fate is unknown — never fall back to a local write on anything but a
  genuine transport failure (`ApiTimeoutException` included). `api_repository_contract_test.dart`
  enforces this over both `data/repositories/api/` and `data/repositories/api_*.dart`.
- An `ApiRepository` never calls a Drift transactional service (double stock decrement).
- An `ApiException` must never reach a screen — convert via `rethrowThai` /
  `rethrowServerRefusal` to a plain Thai-string `Exception`/`PosException`.
- The bill id and `Idempotency-Key` are minted **once per cart**, not once per call
  (`PendingWrites` parks the attempt); a fresh id+key on retry defeats both server
  defences and double-rings the sale.
- Consent (e.g. `overrideCreditLimit`) is carried explicitly from a dialog the counter
  was actually shown — never inferred by re-running a stale local check.
- Money crosses the wire as the string `"1234.50"`; a field the response omits leaves
  its row alone.

**CI/CD (`.github/workflows/`, `deploy/`):**
- Both `flutter.yml` and `server.yml` trigger unfiltered on every push/PR; a `changes`
  job gates each workflow's own jobs internally so a `server/`-only PR still runs (and
  can satisfy) the Flutter required check, and vice versa. Each workflow ends in one
  always-reported status job (`flutter-ci-status`/`server-ci-status`) — the only
  required checks on `main`. `concurrency.group` is keyed by commit SHA.
- Branch protection on `main` has been set since 2026-09-15: PR required (0 approvals),
  the two status jobs required, no force-push/delete, admins not enforced.
- Base image digests are pinned and bumped by hand, never suppressed with `.trivyignore`.
- `.github/dependabot.yml` is security-updates-only — routine bumps are human-timed.
- Never `docker compose down -v` on a shared Docker daemon (wiped another session's dev
  volumes once); throwaway stacks use a unique `-p`.

**Nginx / auth / rate limiting:**
- Nginx must be the only reverse proxy in front of the API — `trust proxy` is exactly
  `1` and `clientIp()` reads the rightmost `X-Forwarded-For` entry; a second proxy or
  CDN in front collapses every client onto one rate-limit bucket.
- Login throttles **before** it spends a DB connection and counts **before** it knows
  the outcome (one atomic Lua `INCR`); every refusal counts, a success only refunds its
  own IP attempt.

**Catalogue/sync (`server/src/products/`):**
- `GET /products?updatedSince=&afterId=` is a **microsecond**-precision keyset cursor —
  a millisecond timestamp skips or re-serves rows sharing one bill's `now()`.
- Part-number uniqueness is a Postgres constraint (`uq_products_partno_ci`), not an app
  check; check `EXPLAIN` as `pos_app`, never as superuser (RLS changes the plan).
- PO receive lock order: PO row → products in id order; weighted-average cost rounds
  satang half-up (deliberately differs from the Dart client's float `round2`).

**Client-side Flutter:**
- `setState(() { x = …; })`, never the arrow form, **when the assigned value is a
  `Future`** — the arrow form trips a Flutter assertion (compiled out in release builds,
  which is why it hid for a while).

**General lesson, learned the expensive way more than once (#22, #24, #260's import
pre-flight):** **validate input first, then clamp** — a `GREATEST`/`Math.max` clamp on
an unvalidated value turns a loud corruption into a quiet one.

---

## Phase 2

**Spec:** `docs/Backend_design/08_PHASE2_SPEC.md` (2026-09-15; owner decisions D1–D15,
E1–E11, F1–F10 in #240, map #243; merged as PR #254). Key shape: one `owner` role + one
active shop account per tenant, retire/enrol/export need an enrolled device token, no
`offlineOk` (column dropped), the `pos` device issues RC/CN online *and* offline,
`POST /sync/push` authenticates with the device token and replays by key then client id
before any check, multiple shifts per day, online void = reason only (no PIN), the
offline-PIN window is enforced till-side only, production = department VM `mob04` via
the hardened self-hosted runner. ADR-0004/0007/0009/0010/0013 carry dated phase-2
addenda.

**Lanes:** `docs/Backend_design/09_PHASE2_LANES.md` (2026-09-16, owner-approved; 35
issues under #243). Lane B (`team/2`, `LomerAlloys`) owns the whole on-device engine —
PWA/SW, `outbox_ops`, `SyncService`, RC/CN numbering, offline PIN, pull, and **every
Drift schema bump**. Lane C (`team/3`, `PattaraponKitcharoen`) owns the server + new
screens + ops. Lane A (`team/1`, `NuimanLP`) is 3 unblocking tickets — **all merged
2026-09-17**:
- **#268** (Thai copy, Option A) → PR #305 — 5 new error codes + 13 phase-2 UI strings
  in `02_API_SCREENS.md §8`/`§8.1`/`§8.1.1`, wired into `server_error_resolver.dart`.
- **#269** (`SyncFacade` seam) → PR #307 — `SyncFacade`/`NullSyncFacade`/`FakeSyncFacade`
  (`frontend/lib/data/sync/sync_facade.dart`) + all 18 `/sync/push` fixture JSONs
  (`docs/Backend_design/fixtures/sync-push/`) — the contract lane B/C build against.
- **#270** (platform allowlist) → PR #308 — `/api/v1/platform/` restricted to
  loopback/`PLATFORM_ADMIN_IPS`, `/sw.js` no-cache, `nginx-check` CI job.

🔴 Four issues are **halves** — read both before touching either: #228 ↔ #283,
#212 ↔ #277, #194 ↔ #285, #193 ↔ #287. 🔴 **Blocked-by never crosses a lane** — a
cross-lane need is a contract (fixtures, `SyncFacade`), never a queue. 🔴 An AC may
never claim "works against the real thing" while the other half of a split ticket is
unmerged. Every ticket ends with `09 §10`'s working agreement: `/scrutinize` the
approach → code per `karpathy-guidelines` → test only against your own side's fake →
close with `/code-review`. Read `docs/handoff_log/phase2-lane-split-and-tickets-2026-09-16.md`
for how the split was chosen.

---

## Pending follow-ups (not yet built)

Deployment/hosting is owned by `docs/Backend_design/07_CICD_DEPLOY.md` (ADR-0013).
- **Cloud snapshot backup (Supabase) — Phase 7a**, stubbed/not wired (needs project
  creds).
- **Record-level sync — Phase 7b** — done as of #53 (schema v3): all six
  product-mutating paths stamp `updatedAt`; optional until a second device exists.
- **Software hardening — Phase 8a**: manager-PIN gate, audit log, PDPA. Font bundling
  done (#271) — 🔴 not fully closed: the web build's fallback-glyph fetch to
  `fonts.gstatic.com` (the Flutter engine's, not `google_fonts`') still fires for the
  ~29 files using emoji, and the web service worker precaches nothing (blocked on
  #266) — see `docs/handoff_log/ticket-271-bundle-fonts.md`.
- **Native hardware — Phase 8b** (needs shop access): thermal printer / cash-drawer
  kick / barcode scanning — scan actions currently use manual entry.
- **Security** — compose hardening done (Redis `--requirepass`, no datastore ports
  published beyond dev/CI loopback); ADR-0009 addendum covers token signing/storage.
- Re-capture tutorial screenshots from the Flutter app (current images are from the JS
  app). Full tax invoice (ใบกำกับภาษีเต็มรูป) stays out of scope for v1.

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
