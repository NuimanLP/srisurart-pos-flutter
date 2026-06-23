# Srisurart Autopart POS — Flutter (Project Knowledge Base)

Flutter migration of a Thai auto-parts shop POS, ported from the React-in-browser +
localStorage app (the "Srisurart Autopart Design System" repo; origin
github.com/NuimanLP/Sri-SuRat_Store). **Offline-first**: Drift/SQLite + Riverpod +
go_router. Thai-first UI with EN labels. Targets **Android/iOS + Web**.

> **🔒 Read first — private operating instructions (machine-local, NOT in this repo).**
> Also read these from the local toolkit folder `D:\Beestation\A_Tooling\claude-portable\`:
> - `CLAUDE.md` — global working guidelines for this machine.
> - `skills-for-claude.md` — skill-routing table (trigger → skill); invoke via the Skill tool.
>
> These live **outside** this repo on purpose and must stay private. Do **NOT** copy, paste,
> summarize, or commit their contents here — only this pointer belongs in the repo.

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
    providers/               ← Riverpod providers (databaseProvider + one per repo)
    screens/                 ← 11 screens, 1:1 with the JS screens
    widgets/                 ← shared UI kit + AppShell nav + sub-views (receipt, A4 quote,
                               label printer, closing report)
  app.dart / main.dart       ← MaterialApp.router + ProviderScope(databaseProvider override)
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
adversarial scrutiny + fix pass. App `dart analyze`-clean, tests green, `flutter build web` ok.

**Pending follow-ups (not yet built):**
- **Cloud backup/sync (Supabase)** — Phase 7, stubbed/not wired (needs project creds).
- **Native hardware** — thermal printer / cash-drawer kick / barcode **scanning** (camera)
  deferred to Phase 8; scan actions currently use manual entry.
- **Bundle Sarabun/Barlow fonts as assets** (currently `google_fonts` runtime fetch — set
  `GoogleFonts.config.allowRuntimeFetching = false` in tests to avoid a pending-timer leak).
- **Re-capture tutorial screenshots** from the Flutter app (current images are from the JS app).
- **Drift web worker / sqlite3.wasm** assets for full web-DB support.
- Carried from JS: manager-PIN gate, audit log, PDPA, full tax invoice (ใบกำกับภาษีเต็มรูป).

---

## Conventions

- **Thai UI strings = behaviour parity** — copy exactly from `db.js` / the `.jsx`; never translate.
- Money via `baht()` / `round2()`; never inline currency formatting.
- Screens consume **repository providers + Drift row classes** — never touch `AppDatabase`
  directly from a screen.
- Each screen file owns its sub-views (Receipt, ClosingReport, QuotesManager, etc.) per
  `CONTRACT.md §5`.

## Legacy app & full plan

The legacy JS app (source-of-truth-until-cutover) and the full migration `PLAN.md` live in the
**"Srisurart Autopart Design System"** repo. Tag **`v1.0-js-localstorage`** there marks the last
pure-JS/localStorage state.
