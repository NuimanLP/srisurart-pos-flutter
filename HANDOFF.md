# HANDOFF — Srisurart POS Flutter migration (updated 2026-09-04)

## TL;DR
The Flutter port (Phase 0–6, offline parity) is built and the gate is **GREEN as of
commit `92bd3bf`** (2026-09-04): `dart analyze` clean, **123/123 tests pass**. State
management is **flutter_bloc**, not Riverpod (migration landed 2026-07-14; see that
entry). **Local `main` is 3 commits ahead of `origin/main` and has NOT been pushed.**

Backend direction: the design package `docs/Backend_design/` is now backed by a
**decision record in `docs/Backend_design/adr/` (ADR-0001…0009)** — read its
`README.md` before touching any backend doc. `CLAUDE.md` now states that **where a doc
contradicts an ADR, the ADR wins.** Nothing server-side is built yet; the design is the
deliverable so far, and no cutover is planned for phase 1.

Two of those ADRs were implementable immediately and shipped: Drift **schema v2**
(`sale_items.costAtSale` + `updatedAt`/`deletedAt` on customers/mechanics/settings —
this clears the Phase-7b prerequisite) and a **fix to the profit reports**, which were
overstating profit against today's product cost. See the 2026-09-04 entry.

Remaining bigger work: Phases 7a/7b/8a/8b per `docs/PLAN.md`, and **CI/CD**, which is
the next thing the user asked for.

## 2026-09-04 (backend design grill → ADR record + schema v2 — commits `3bcc146`, `21e7434`, `92bd3bf`)
- **Full detail: [`handoff/backend-design-adr.md`](handoff/backend-design-adr.md).** Read
  that plus `docs/Backend_design/adr/README.md`; this entry is only the summary.
- A 4-round `/grill-with-docs` interview on the multi-tenant design produced **9 ADRs**:
  tenant provisioning, platform-admin plane, tenant lifecycle, device roles, data
  portability, per-tenant rate limit, receipt numbering, cost-at-sale, JWT lifetime.
  Docs `01`–`03` + `00_INDEX` were then propagated to match (3 parallel sub-agents,
  one file each), so the package no longer contradicts itself.
- **Three real contradictions were found in the existing design docs and fixed**, the
  largest being the claim that "conflict is structurally impossible because the shop
  has one machine" — nothing enforced that (it's a web app; a second tab breaks it),
  and it was unnecessary anyway since the phase-1 acceptance test already proves
  concurrent machines are safe. Replaced with the constraint that actually holds:
  one cash drawer, one receipt-number series, enforced by a partial unique index.
- **Drift schema v1 → v2** with an `onUpgrade` adding 7 nullable columns.
  `build_runner` ran here without trouble — the `CLAUDE.md` warning is about the Thai
  folder path on Windows, and this checkout is on an ASCII path.
- **Profit reports were wrong on the shop's screen**, not just imprecise: cost came
  from `products.cost` (which moves on every PO receive), and a missing product fell
  back to cost `0` = 100% profit. Both the monthly KPI and the CSV export now read the
  recorded cost first, and the CSV gained a `ที่มาของต้นทุน` column so each row can be
  audited. Also found: `snapshot_repository` had been dropping `cost` from JS backups
  all along, so importing the shop's real backup recovers historical cost.
- 🔴 **Three Thai UI strings in the reports fix were written from scratch** (no `db.js`
  original exists), which is against the parity rule in `CLAUDE.md`. They are flagged
  at the end of ADR-0008 for the shop owner to reword. Seven more Thai error strings
  for the backend remain deliberately blank for the same reason.
- **Verified:** `dart analyze` clean; `flutter test` 123/123 (2 new tests — a
  `costAtSale` regression test and a snapshot round-trip assertion).

## 2026-07-23 (frontend-prototype presentation deck — docs/collateral only, no app code)
- Iterated `PDF_Report/frontend-prototype-slides.html` (first added 2026-07-20, commit
  `f173fbe`) from an 11-slide code/jargon-heavy draft into a 21-slide screenshot-driven
  walkthrough, in response to grading-committee-readability feedback: one real-screenshot
  slide + one paired "flow-chain" code-trace slide per feature (select product → adjust cart
  qty → pay → cross-screen linking to customers/mechanics/stock), a full 11-screen gallery,
  and one deep-dive slide per grading-rubric criterion (UI Completeness, Layout Structure,
  Code Cleanliness, UX & State-Driven) pairing real code with real verification evidence
  (test counts, a caught-and-fixed CSS bug, concrete stats).
- Real screenshots captured via a disposable headless-Chrome + DevTools-Protocol pipeline
  (Claude-in-Chrome wasn't connected this session) and embedded as base64 data URIs so the
  deck stays a single portable file.
- Gate status unchanged from 2026-07-20 (`d44dfce`) — no `lib/`/`test/` files touched.
- Added reference PDFs alongside the deck (course/rubric materials, not authored this
  session): `02_Widget improvement.pdf`, `03_Clean_Code - Google เอกสาร.pdf`,
  `Update Frontend Prototype.pdf`.

## 2026-07-14 (Riverpod → flutter_bloc migration — commits `d834450`, `857f434`, `d44dfce`)
- **Full state-management replacement**, executed per the 12-step plan in
  `docs/plans/riverpod-to-bloc.md` (now `Status: Complete`): DI moved to 13
  repositories via flutter_bloc `RepositoryProvider` (new
  `lib/presentation/repositories/repository_providers.dart`); the 4 stateful
  controllers became Cubits in `lib/presentation/blocs/`
  (`ThemeModeCubit`/`FontScaleCubit`/`PendingQuoteCubit`/`CartCubit`); the 20
  one-shot data loads across screens became `FutureBuilder`s fed by futures created
  in `initState`/explicit `_refresh()`. `flutter_riverpod` fully removed from
  `pubspec.yaml`; old provider files deleted (`providers.dart`, `shift_providers.dart`,
  `pending_quote_provider.dart`).
- **Docs updated to match:** `CONTRACT.md` (§0.5, §1, §3, §4, §5, §11), `CLAUDE.md`
  (architecture summary + dated migration-status note).
- **Verified:** `dart analyze` clean; `flutter test` 122/122; manually smoke-tested
  in a live browser session (theme/font-scale toggle repaints from 3 read/write
  sites, quote→checkout cart hand-off, post-sale stock refresh).
- **Follow-up commit `d44dfce`** ran `dart format` across the whole `lib/`/`test/`
  tree (formatting only, no behavior change) to clean up drift accumulated during
  the migration's many touched files.
- Full session narrative (environment quirks, git-state-at-handoff notes) lives in
  `handoff/riverpod-to-bloc.md` — not duplicated here.

## 2026-07-13 (backend / Supabase-hierarchy / deployment plan — docs only)
- **Gap closed:** `docs/PLAN.md` covered frontend + local data layer in depth but left
  backend architecture, the Supabase hierarchy, and hosting/Docker undefined. Authored
  **`docs/BACKEND_DEPLOYMENT.md`** as the companion doc; PLAN.md cross-links it (Related
  block + §11 log entry) and `CLAUDE.md` pending-follow-ups points to it.
- **Decisions recorded there (planned, nothing built):** no custom server — Supabase IS
  the backend, all transactional invariants stay in the Dart repos; **two separate
  Supabase projects** `srisurart-dev`/`srisurart-prod` selected via
  `--dart-define-from-file` (keys git-ignored); Auth = one owner email account, sign-ups
  off (manager PIN stays app-level, Phase 8a); Phase 7a needs **no Postgres tables** —
  just a private `backups` bucket, `{deviceId}/{timestamp}_{schemaVersion}.json.gz` in
  the exact `exportSnapshot()` shape (one format for cloud backup / local backup /
  legacy import), 30-daily+12-monthly retention; 7b Postgres = snake_case mirror of the
  20 Drift tables split append-only-events vs LWW-mutable + `devices`/`sync_conflicts`,
  RLS on everything (the `updatedAt` prerequisite still blocks 7b); **hosting = static
  file serving of `build/web` on the shop PC** (Docker/nginx only if the PC already runs
  Docker — the BeeStation cannot run containers); **Supabase cloud, NOT self-hosted**
  (backups on shop hardware defeat the purpose); CI (analyze/test/build + stale-`*.g.dart`
  check on ASCII-path runners) slotted into Phase 8a — none exists yet.
- **No app code touched** — gate status unchanged from 2026-07-10. The red
  uncommitted smoke-harness pair (`test/route_smoke_test.dart` +
  `lib/core/theme/app_theme.dart`) is still in the working tree, still NOT committed.

## 2026-07-10 (clean-code pass + rendering fixes — commit `279b90a`)
- **Clean-code audit fixes** (details in the commit message): `baht2()` for fixed
  2-decimal money; new `core/utils/dates.dart` (`dateKey`/`todayKey`/`monthKey`) replacing
  all inline `toIso8601String().substring` slicing; `thaiDateSlash`/`thaiDateTimeSlash` in
  `thai_format.dart` replacing 3 private per-file formatters; PO screen status pill now
  uses shared `StatusChip` (JS labels kept verbatim — 'open' → รอรับสินค้า, do NOT swap to
  `StatusChip.of`); `QuoteRowStatus` extension (`isExpired`/`isConverted`); settings
  saved-file dialog dedup; dead `_hhmm` removed. Conventions recorded in `CLAUDE.md`
  Conventions + `CONTRACT.md` §7/§11.
- **3 pre-existing rendering bugs fixed** (all caught by the committed smoke tests, all
  pre-dated this session): products' `Flexible`-as-`FilledButton.icon`-label
  (ParentDataWidget error at every size); reports header range-pill Row overflow at phone
  (now horizontal-scrolls, `reverse: true`); reports `_StatCard` `sub` line moved inside
  the `FittedBox` (15px bottom overflow in short grid cells).
- **New tests**: `movements` / `suppliers` / `settings` repository tests (were the only
  repos without any).
- **⚠ UNCOMMITTED + RED — responsive smoke-test harness** (left in working tree on
  purpose): `test/route_smoke_test.dart` (+262-line `_pumpAndProbe` rewrite) +
  `lib/core/theme/app_theme.dart` (adds `AppTheme.useGoogleFonts`, which that harness
  needs). Under the new harness: products@desktop_web dies with
  `'_pendingExceptionDetails != null'` (an uncaught zone error escapes its
  `FlutterError.onError` override — verified NOT caused by the refactor; HEAD screens fail
  identically), and purchase_orders@desktop_web/tablet deadlock for hours inside
  `tester.runAsync` (same screens pass in seconds under the committed harness). Fix the
  harness first: capture zone errors (`runZonedGuarded`/`PlatformDispatcher.onError`) so
  the real exception surfaces, then chase the `runAsync` + `db.close()` sequencing.
- **⚠ Ops lessons (repeat offenders)**: (1) `flutter test` CANNOT run on the BeeStation
  cloud mount — errno-60 timeouts/hangs; rsync the repo (minus `build`/`.dart_tool`/`.git`)
  to a local path and test there. (2) BeeStation sync silently REVERTED `CLAUDE.md` to a
  pre-`38d94a3` version this session (restored from git) — before committing, diff doc
  files against HEAD and distrust hunks that delete recently-committed content.
  (3) `android/build/` artifacts were accidentally staged — now gitignored.

## 2026-06-30 (onboarding course → three audience tracks — still OUT of repo)
- Expanded the `/teach` onboarding course (the out-of-repo artifact under
  **`Sri_POS/Summary/teaching/`**, see the "2026-06-24 (developer-onboarding course)" entry) from
  a **dev-only** course into **three audience tracks** of the same project: **Dev** (existing 5
  lessons + glossary/cheat-sheet), **CEO** (business case, status/roadmap/risk — no code), and
  **Owner / "for me"** (operate + protect the data; the open decisions only the owner can make).
- New files (all under `teaching/lessons/`, reusing the shared `assets/course.css` verbatim — no
  CSS changes): `ceo-01-the-business-case.html`, `ceo-02-status-and-roadmap.html`,
  `owner-01-run-and-protect.html`, `owner-02-decisions-you-own.html`. `index.html` reworked into a
  three-track hub (per-track brand span: `.dev` / `.biz` / `.shop`). `MISSION.md` audience-scope
  updated; `learning-records/0004-three-audience-tracks-ceo-owner.md` added.
- **Grounding:** CEO/Owner content is a business/ops framing of facts already in `CLAUDE.md`
  (migration status, pending follow-ups, invariants) + the existing dev lessons — no new code
  claims, no app code touched. The #1 risk surfaced for the CEO/Owner = **no automatic cloud
  backup yet** (Phase 7 Supabase stubbed); interim mitigation = daily manual snapshot export.
- **Still NOT in this repo.** Same rule as before — git tracks app code only; the course is a
  BeeStation-synced artifact. The only in-repo change this session is **this HANDOFF entry**.
- **No app code touched** — docs only; gate status unchanged from the entries below.

## 2026-06-25 (UI polish — topbar alignment + live clock, vehicle search, dark-mode contrast)
- **Topbar cluster floated to the centre instead of the right edge** (`app_shell.dart`
  `_TopBar`): the cashier/date block was a `Flexible` (flex:1) competing with the `Expanded`
  shop name, so the Row split its free space 50/50 and the loose-fit block sat left-aligned in
  its half — leaving a large empty navy gap on the right. Fix: made it a plain fixed-size
  `ConstrainedBox` (maxWidth 220, NOT `Flexible`) so the shop name absorbs all slack and the
  cluster pins right. `maxWidth` + per-line ellipsis still prevent a long cashier name from
  overflowing.
- **Added a live ticking clock to the topbar.** `_TopBar` is now `ConsumerStatefulWidget` with
  a `Timer.periodic(1s)` that only `setState`s when the displayed minute (or day) changes — so
  the topbar's StreamBuilders aren't rebuilt 60×/min. Second line now shows `EEE date · HH:mm`
  (e.g. `พฤ. 25 มิ.ย. 2569 · 20:17`) via the existing `thaiTime()` helper. Timer cancelled in
  `dispose()`. (No test mounts `AppShell`/`_TopBar`, so the periodic timer can't stall
  `pumpAndSettle` in the suite.)
- **Vehicle search showed motorcycle models in a car shop** (`vehicle_search_screen.dart`):
  `_popularVehicles` was the legacy `.jsx` motorcycle list (Wave/PCX/Click/NMAX…), but the
  seed products' `compat` fields and the search hint are all cars/pickups — so every quick-chip
  returned zero results. Replaced with the 12 car/pickup models actually present in seed
  `compat` (Toyota Hilux/Vios/Fortuner, Honda City/Civic/Jazz, Isuzu D-Max/MU-X, Ford Ranger,
  Mitsubishi Triton, Nissan Navara, Mazda 2) so each chip matches real data.
- **…which then overflowed the phone layout** — the longer car names made the chip `Wrap`
  tall enough that header+search+chips exceeded the 800px body and the body `Column` overflowed
  by 56px at 400×800 (caught by the route-smoke test). Fix: chips now `Wrap` on wide screens
  (≥`AppBreakpoints.rail`) but become a single **horizontally-scrolling** row on phones (fixed
  height, robust to any number/length of model names, leaves room for results).
- **Dark mode: secondary buttons were invisible** (`app_button.dart`): `AppButton.secondary`
  hardcoded `foregroundColor: AppColors.navy` (#0B2444) — fine on the light cream surface, but
  navy-on-navy in dark mode (scaffold `bgDark` #0B2444, header surface `navyMid` #153660). Made
  the label brightness-aware (white in dark, navy in light); the steel-blue outline reads in
  both. Shared widget → fixes every secondary button app-wide (e.g. "📊 สรุปยอดปิดร้าน").
- **Gate:** `dart analyze` clean; `flutter test` **112/112** (incl. vehicle_search phone after
  the overflow fix); no schema/codegen change. UI-only.

## 2026-06-24 (developer-onboarding course — moved OUT of repo)
- Built a `/teach`-style **developer onboarding course** that explains what the project is, what
  each code sector does, and how to configure/run it. From a 4-agent codebase sweep (lib map /
  data layer + CONTRACT / build+config / presentation), styled after the `cookies-101.html` design
  reference (warm paper/caramel; Fraunces + IBM Plex Sans Thai + JetBrains Mono). Thai-primary
  prose; identifiers in EN. Course = `index.html` + 3 lessons + glossary/cheat-sheet + shared
  `assets/course.css`/`course.js`, plus the `MISSION/NOTES/RESOURCES/learning-records` workspace.
- **The course does NOT live in this repo.** It was relocated to
  **`Sri_POS/Summary/teaching/`** (a BeeStation-synced folder, sibling to `Flutter/`) so the
  rendered HTML and its markdown source stay together and out of the app repo. The markdown that
  was briefly committed here (commit `1399e3f`) is removed again in the follow-up commit — git
  tracks app code only; the course is a synced artifact, not a repo file.
- **No app code touched** — docs only; gate status unchanged from the entries below.

## 2026-06-24 (two HIGH fixes — web export + ClosingReport responsive)
- **HIGH — backup + CSV export were `dart:io`-only → silently broken on web** (the only
  data-safety path for an offline-first app; a web shop could never back up). Added a
  conditional-import platform helper **`lib/core/utils/file_export.dart`** (+ `_io.dart` /
  `_web.dart`): native writes to the app docs dir and returns the path; **web triggers a
  browser download** via Blob + a hidden `<a download>` (the same mechanism the original JS
  app used) and returns null. Rewired all four exporters to `exportTextFile(...)` —
  `settings_screen.dart` (JSON backup + 3 CSVs) and `quotes_screen.dart` (CSV, same defect);
  removed their `dart:io`/`path_provider`/`path` imports. Save dialogs now show the path on
  native and a "ดาวน์โหลด …แล้ว" note on web. Added `web: ^1.1.1` to pubspec (promoted from
  transitive). **`flutter build web` compiles the web impl clean** (proof the previously
  throwing path now builds for web). *Caveat: the live in-browser download click is not yet
  manually verified (headless has no download harness); logic is the standard pattern.*
- **HIGH — ClosingReport dialog overflowed on phones** (fixed 320px right pane + Expanded
  left). Wrapped `_body` in a **`LayoutBuilder`**: ≥720px keeps the side-by-side Row; below
  that it **stacks** the summary + cash panes in one scroll view (panes extracted to
  `summary`/`cashForm` locals). Also fixed a **pre-existing 6.3px overflow inside the 320px
  cash pane** (long Thai label + amount in `spaceBetween` rows) by making those labels
  `Expanded` so they ellipsize — caught only because ClosingReport had never been rendered in
  a test before (it's a dialog behind a button).
- **Regression test added** (`test/closing_report_layout_test.dart`, 2 cases): renders
  ClosingReport at phone (400) and tablet (1280) with no overflow (would fail pre-fix at both).
- **Gate:** `dart analyze` clean; `flutter test` **112/112**; `flutter build web` ok.
- **Next (audit backlog, see `SCRUTINY_REPORT.md`):** the quick-wins batch — GoRouter
  `errorBuilder`, write-handler error toasts (park/save-quote/cash open/close), `closeShift`
  confirm dialog, change-due contrast (#2ECC71 → forestGreen), Mechanics `ลดให้ช่าง` stat
  (`totalCredit`→`totalDiscount`), unit tests for `round2`/`pointsFor`/`baht`/`csvSafe`; then
  the medium a11y / design-system / i18n items.

## 2026-06-24 (scrutiny + Quote→Checkout fix)
- **15-agent scrutiny audit** (code/DB/UI/UX/design/a11y/perf/i18n/security/tests, each
  finding adversarially verified against the real code path + the legacy `db.js`/`.jsx`):
  **129 agents → 113 findings → 107 verified, 6 rejected** as false positives. Full prioritized
  report committed as **`SCRUTINY_REPORT.md`** (exec summary, top fixes, per-dimension catalog,
  quick wins, what's solid, and the rejected FPs with verifier reasoning).
  Severity totals: **1 critical · 2 high · 28 medium · 36 low · 11 info**. Headline: the
  data/money core is solid; the work is the presentation layer + the web target.
- **CRITICAL fixed — dead Quote→Checkout hand-off** (`checkout_screen.dart`): `QuotesScreen`
  staged a quote in `pendingQuoteForCartProvider` and navigated to `/`, but `CheckoutScreen`
  **never read it** → "→ ขาย" (convert) and "✎" (edit) landed on an EMPTY cart, and the edit
  path `deleteQuote()`s first → unrecoverable. Fix: CheckoutScreen now consumes the staged quote
  on mount (`initState` post-frame, with a `build`-time `ref.listen` fallback), mirroring the JS
  `loadQuote` effect — re-validates items vs current stock (existing `_validateItems`: drop
  missing/out-of-stock, clamp over-stock + Thai warning), loads cart + discount at the quoted
  prices, best-effort re-selects the customer **by phone**, then clears the provider (guarded so
  it can't double-load). The edit data-loss is resolved as a side effect (the in-memory
  `QuoteWithItems` flows to the cart regardless of the DB delete; `_handleEdit` delete-first
  ordering left intact to match its documented UX).
- **Known limitation (flagged, not silently diverged):** the `Quotes`/`QuoteItems` tables persist
  only `customerName`/`customerPhone` (no `customerId`, no mechanic) — unlike the JS app which
  restores customer/mechanic **by id**. So mechanic context **cannot** be restored on convert/edit;
  customer is best-effort by phone. Storing `customerId`/`mechanicId` on quotes would need a Drift
  schema change → `build_runner` on an ASCII path.
- **Regression test added** (`test/quote_to_checkout_test.dart`, 2 cases): a staged quote loads
  into the cart + clears the provider; an over-stock quote qty is clamped to available stock.
- **Gate:** `dart analyze` clean; `flutter test` **110/110** (108 prior + 2 new).
- **Next:** the two HIGH findings — **now both DONE**, see "two HIGH fixes" entry above.

## 2026-06-24 (web DB) — `flutter run -d chrome` now boots
- **Symptom:** the web app loaded to a blank white page. Console threw
  `Invalid argument(s): When compiling to the web, the 'web' parameter needs to be set`
  from `driftDatabase()` — the app crashed at DB-open before rendering.
- **Fix:** committed the two required web assets into `web/` — `sqlite3.wasm` (matches
  `sqlite3` 3.3.3) and `drift_worker.js` (matches `drift` 2.34.0), both pulled from the
  simolus3 GitHub releases (WASM magic-bytes verified). `AppDatabase.open()` now passes
  `web: DriftWebOptions(sqlite3Wasm: Uri.parse('sqlite3.wasm'), driftWorker: Uri.parse('drift_worker.js'))`
  (the option is ignored on native, so Android/iOS/macOS/tests are unaffected).
- **Verified (pixel-confirmed):** `dart analyze` clean; the POS home screen renders fully on the
  web — product grid (all 12 seeded items, prices, live stock counts), nav rail, and the
  customer/mechanic/payment panel all paint, proving the Drift web DB opens and loads seed data.
  Console logged `Using WasmStorageImplementation.sharedIndexedDb` (drift picking a web storage
  backend), no exceptions.
- **How it was screenshotted (for next dev):** the **debug** build (`flutter run`) will NOT paint
  under headless Chrome — its DDC module loader (~1370 ES modules) stalls without the dev harness.
  Screenshot the **release** build instead: `flutter build web --no-tree-shake-icons`, serve
  `build/web` (`python3 -m http.server`), and capture with headless Chrome started with
  `--enable-unsafe-swiftshader` (CanvasKit needs WebGL; software GL works, plain `--disable-gpu`
  gives a blank canvas). Release is also exactly what deploys to the shop PC.
- **Gotcha for next dev:** if you bump `drift` or `sqlite3`, re-download the version-matched
  assets or the web DB breaks at boot (version skew). Source: `github.com/simolus3/{drift,sqlite3.dart}/releases`.

## 2026-06-24 session — parity gate closed
- **Env note:** this session ran on **macOS** at an **ASCII path**
  (`/Users/.../Sri_POS/Flutter`), so the Thai-path `build_runner`/`flutter analyze`
  constraint does NOT apply here — all tools run. Flutter **3.44.3** (Dart 3.12.2) was
  installed via `brew install --cask flutter`. The Windows `C:\srisurart_pos` workflow in
  the older notes below is therefore optional; this Mac path is fully build-capable.
- **Fixed the 3 phone-overflow route-smoke fails** (all now green at 400×800, tablet
  unchanged):
  - `customers_screen.dart` `_TopBar`: `Row` → `LayoutBuilder` (≥600px renders the original
    single-row layout byte-for-byte; <600px stacks stats over a full-width search+button row).
  - `purchase_orders_screen.dart` `_PoListView` stat bar: grouped the two `_Stat`s into a
    `Flexible` inner `Row` (each `_Stat` `Flexible`); added `maxLines:1`+ellipsis on the `_Stat`
    label. Tablet sizes to intrinsic width (Spacer still pins the button right) — no regression.
  - `returns_screen.dart` `_LeftPane` tab bar: wrapped the two-`_TabButton` `Row` in a
    horizontal `SingleChildScrollView` (the 3.3px overflow source).
  - Each fix was adversarially read-verified (tablet-safe, exact-match, Thai strings untouched).
- **LOW findings triage (re-scrutiny):**
  - **F001 (use `baht()`):** APPLIED — `settings_screen.dart` export summary now uses the
    canonical `baht()` and the bespoke `_grouped()` duplicate was deleted.
  - **F002 (checkout search placeholder):** DEFERRED — the field does match name+nameTH+partNo
    while the hint says only "ชื่อสินค้า", but changing a Thai UI string needs the JS source
    to stay parity-faithful (CLAUDE.md rule). Document/confirm wording before editing.
  - **F003 (today-filter timezone):** NOT A BUG — `_todayStr()` and stored sale dates both use
    local `DateTime.now()`; the JS app used local time too, so local is the parity-correct
    choice. Switching to UTC would *introduce* an off-by-one in Thailand (UTC+7). Left as-is.
  - **F004 (CreditPayments `method` column):** KNOWN LIMITATION (out of scope here) — JS filtered
    cash-drawer credit settlements by `method === 'เงินสด'`; the Drift table has no `method`
    column, so all credit payments count as cash inflow. Needs a schema change + `build_runner`.

## Where everything is
- **GitHub (canonical):** https://github.com/NuimanLP/srisurart-pos-flutter (private, branch `main`)
- **Local synced copy:** `D:\Beestation\ร้านศรี\Flutter` (BeeStation-synced — Thai path, so
  `build_runner` and `flutter analyze` WON'T run here; `dart analyze` / `flutter test` /
  `flutter build` do).
- **To work tomorrow:** `git clone https://github.com/NuimanLP/srisurart-pos-flutter C:\srisurart_pos`
  and work at that ASCII path (build_runner + the saved scrutiny workflow expect `C:\srisurart_pos`).
  Run `flutter pub get` first (the moved copy ships without `.dart_tool/`).
- Legacy JS app + full `PLAN.md`: `D:\Beestation\ร้านศรี\Srisurart Autopart Design System`
  (tag `v1.0-js-localstorage` = last pure-JS state).

## Build / test rules (CRITICAL — see CLAUDE.md)
- Build on an **ASCII path**. `build_runner` (Drift codegen) + `flutter analyze` break on the
  Thai path (`ร้านศรี` → `???????`). Generated `*.g.dart` ARE committed, so the app builds/runs
  without codegen; only a Drift schema change needs an ASCII-path codegen run.
- Use `dart analyze` (NOT `flutter analyze`). `flutter test`. `flutter build web --no-tree-shake-icons`.

## Current state (verified 2026-06-24)
- `dart analyze`: **CLEAN** (No issues found).
- `flutter test`: **110 pass, 0 fail** — all 22 route-smoke cases green at BOTH tablet
  (1280×800) and phone (400×800); all repository/unit tests pass; + 2 Quote→Checkout regression tests.
- `flutter build web --no-tree-shake-icons`: **succeeds** (`build/web` built).
- Commits: scaffold → data layer (76 tests) → deps → screens (W2) → W3 scrutiny fixes →
  **W4: phone-overflow fixes + LOW-finding F001 + this handoff (2026-06-24)**.

## What's done
- **W1 data layer:** 20 Drift tables porting `pos/db.js`; transactional repos (saveSale,
  createReturn, receivePO, openShift, quotes, parked, snapshot export/importLegacyBackup) +
  unit tests. Invariants verified faithful (Thai errors byte-exact, strict-vs-clamp stock,
  points=floor(total/10), proportional reversals, weighted-avg cost, auto-void, atomic restore).
- **W2:** 11 screens (1:1 with the JS screens) + shared UI kit + responsive nav shell +
  shifts data layer (10 tests). Theme toggle wired.
- **W3 scrutiny:** 5 adversarial auditors → 28 findings (13 high/medium) → 12 fixers applied.
  Fixed: quotes `validDays` default, snapshot unknown-key carry-forward, LowStockAlert full
  modal restored, cash-drawer credit-settlement-as-cash, checkout discount field, products
  no-op vehicle button, + 6 screen layout fixes. (The W3 final-gate agent died, leaving the 3
  phone overflows — those are now fixed in the W4/2026-06-24 session above.)
- **W4 (2026-06-24):** the 3 phone-overflow fixes + LOW-finding F001; re-scrutiny ran (see the
  triage above); **final gate green**; this handoff updated. *(All items below are now done.)*

## Remaining work — DONE (2026-06-24)
1. ~~Fix the 3 phone-overflow route-smoke fails~~ — **DONE** (`customers` LayoutBuilder,
   `purchase_orders` Flexible stats, `returns` horizontal-scroll tabs; all green, tablet unchanged).
2. ~~Re-scrutinize~~ — **DONE** via a diagnose→adversarial-verify workflow (this Mac path; the
   old `/srisurart-flutter-scrutiny` script hardcodes `C:\srisurart_pos` and is Windows-only).
3. ~~Address remaining LOW findings~~ — **DONE/triaged**: F001 applied; F002 deferred (Thai-string
   parity); F003 not-a-bug (local-time is parity-correct); F004 known limitation (schema change).
4. ~~Final gate~~ — **DONE**: `dart analyze` clean + `flutter test` 108/108 + `flutter build web`
   all green.

## Bigger follow-ups (post-parity; see CLAUDE.md)
- Cloud backup (Supabase, Phase 7a — stubbed/not wired; record-level sync = Phase 7b, optional
  until multi-device). Native thermal printer / barcode scanner /
  cash-drawer kick (Phase 8b; software hardening incl. PIN gate/audit/PDPA = Phase 8a).
  Bundle Sarabun/Barlow fonts (currently `google_fonts` runtime fetch;
  tests set `GoogleFonts.config.allowRuntimeFetching = false`). Re-capture `tutorial/` screenshots
  from the Flutter app (current ones are from the JS app). *(Drift web worker/wasm — DONE
  2026-06-24, see the "web DB" session note up top.)*

## Reference
- `CLAUDE.md` — build constraint + architecture + invariants. `CONTRACT.md` — binding spec
  (tables / repo signatures / providers / routes / Thai strings). `docs/PLAN.md` — migration plan.
- `!timersPending` in boot tests was investigated (W3): NOT a leaked app Timer — plugin/test
  async + a DB-close race; neutralize in tests via shared_preferences mock + `tester.runAsync` +
  closing the DB inside the test body.
