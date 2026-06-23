# HANDOFF — Srisurart POS Flutter migration (2026-06-23)

## TL;DR
The Flutter port (Phase 0–6, offline parity) is built, pushed, and ~95% green.
Before calling it done: fix 3 phone-size layout overflows + a few low-severity parity
items, then a **final gate** (analyze + test + build web all green). Plan = re-run
scrutiny, fix, gate.

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

## Current state (verified 2026-06-23, this session)
- `dart analyze`: **CLEAN** (No issues found).
- `flutter test`: **105 pass, 3 fail** — all 3 are phone (400×800) route-smoke overflows:
  `customers`, `purchase_orders`, `returns`. Tablet (1280×800) = 100% clean. (These failing
  tests are the TODO markers; the POS targets tablets.)
- `flutter build web`: succeeds.
- Commits pushed: scaffold → data layer (76 tests) → deps → screens (W2) → W3 scrutiny fixes.

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
  no-op vehicle button, + 6 screen layout fixes. **Final gate agent died (returned null) — that
  is why the 3 phone overflows remain.**

## Remaining work (tomorrow)
1. **Fix the 3 phone-overflow route-smoke fails** (`customers`, `purchase_orders`, `returns`) —
   wrap rows in `Flexible`/`Expanded` or `SingleChildScrollView`. (MEDIUM; tablet already clean.)
2. **Re-scrutinize** to confirm the 12 fixes didn't regress and catch leftovers. The workflow is
   saved as `/srisurart-flutter-scrutiny` (its script hardcodes `C:\srisurart_pos`, so clone there).
3. **Address remaining LOW findings** from the W3 output, e.g.: export-summary should use `baht()`;
   misleading product search placeholder; 'today' filter timezone edge; credit-payment `method`
   folded into note (no `method` column). Decide which are worth doing.
4. **Final gate:** `dart analyze` + `flutter test` (incl. `route_smoke_test.dart`) + `flutter
   build web` ALL green → commit + push.

## Bigger follow-ups (post-parity; see CLAUDE.md)
- Cloud sync (Supabase, Phase 7 — stubbed/not wired). Native thermal printer / barcode scanner /
  cash-drawer kick (Phase 8). Bundle Sarabun/Barlow fonts (currently `google_fonts` runtime fetch;
  tests set `GoogleFonts.config.allowRuntimeFetching = false`). Re-capture `tutorial/` screenshots
  from the Flutter app (current ones are from the JS app). Drift web worker/wasm for full web DB.

## Reference
- `CLAUDE.md` — build constraint + architecture + invariants. `CONTRACT.md` — binding spec
  (tables / repo signatures / providers / routes / Thai strings). `docs/PLAN.md` — migration plan.
- `!timersPending` in boot tests was investigated (W3): NOT a leaked app Timer — plugin/test
  async + a DB-close race; neutralize in tests via shared_preferences mock + `tester.runAsync` +
  closing the DB inside the test body.
