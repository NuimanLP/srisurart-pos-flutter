# HANDOFF — Srisurart POS Flutter migration (updated 2026-06-24)

## TL;DR
The Flutter port (Phase 0–6, offline parity) is built and the **final gate is GREEN**:
`dart analyze` clean, **112/112 tests pass** (incl. all 22 route-smoke cases at tablet
AND phone), `flutter build web` succeeds. The 3 phone-size overflows are fixed and the
LOW findings triaged. **The web runtime now boots in Chrome with the home screen
pixel-verified** — the Drift web DB was wired up (see "2026-06-24 (web DB)" below).
A **15-agent scrutiny audit** (107 verified findings → `SCRUTINY_REPORT.md`) ran this
session; its **1 CRITICAL + both HIGH** findings are now fixed (dead Quote→Checkout hand-off,
web-only-broken backup/CSV export, ClosingReport phone overflow — see the two entries below).
Remaining work is the audit's medium/low backlog plus the bigger post-parity follow-ups
(cloud sync, native hardware, font bundling, etc.).

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
- Cloud sync (Supabase, Phase 7 — stubbed/not wired). Native thermal printer / barcode scanner /
  cash-drawer kick (Phase 8). Bundle Sarabun/Barlow fonts (currently `google_fonts` runtime fetch;
  tests set `GoogleFonts.config.allowRuntimeFetching = false`). Re-capture `tutorial/` screenshots
  from the Flutter app (current ones are from the JS app). *(Drift web worker/wasm — DONE
  2026-06-24, see the "web DB" session note up top.)*

## Reference
- `CLAUDE.md` — build constraint + architecture + invariants. `CONTRACT.md` — binding spec
  (tables / repo signatures / providers / routes / Thai strings). `docs/PLAN.md` — migration plan.
- `!timersPending` in boot tests was investigated (W3): NOT a leaked app Timer — plugin/test
  async + a DB-close race; neutralize in tests via shared_preferences mock + `tester.runAsync` +
  closing the DB inside the test body.
