# Srisurart Autopart POS — Architecture Migration Plan

> **Status:** In progress — Phases 0–6 complete, Phase 7 next · **Created:** 2026-06-23 · **Updated:** 2026-07-03 · **Owner:** TBD
> **Goal:** Re-architect the POS from the current **React-in-browser + localStorage**
> single-station web app to **Flutter**, targeting **Android/iOS tablet & mobile + Web**,
> with an **offline-first local database and cloud backup/sync**.

This document is the canonical migration plan. `CLAUDE.md` and `MAINTENANCE.md` point here.
It describes *what we are moving to and in what order* — it is not a line-by-line porting log.

> **Related (same folder):** [`data-durability-architecture.draft.html`](data-durability-architecture.draft.html)
> — earlier cloud/data-durability analysis that informs §6; and
> [`step0-fsa-persistence-test.html`](step0-fsa-persistence-test.html) — the FSA persistence probe.

---

## 1. Why migrate

The current app (see `CLAUDE.md`) is a single `POS.html` shell loading
`<script type="text/babel">` React files, with all data in browser `localStorage`.
It works, but has hard limits:

- **Data lives in one browser only.** Clearing the browser or switching devices loses
  everything (documented constraint: shop runs Brave; FSA silent-write is blocked — see
  the `data-durability-browser-constraint` memo). Cloud backup/sync fixes this.
- **No native mobile experience.** Counter staff want a tablet; stock/quotes on a phone.
- **In-browser Babel transpile** is fine for a kiosk but not a real distribution model
  (no app store, no offline install, no OS integration for printers/scanners/cash drawer).
- **localStorage is a string blob**, not a queryable store — reporting and larger
  catalogs will not scale.

Flutter gives us one Dart codebase for **Android, iOS, and Web**, a real **SQLite**
local store with transactions (matching today's transactional data layer), and clean
hooks to native **thermal printers, barcode scanners, and cash drawers**.

---

## 2. Target architecture (decisions)

| Area | Decision | Notes |
|---|---|---|
| **Framework** | Flutter (Dart 3) | Single codebase for mobile + web |
| **Targets** | Android, iOS, **Flutter Web** | Web replaces the role of `POS.html` |
| **Local DB** | **Drift** (SQLite) | Transactions + migrations; runs on mobile **and** web (WASM/sql.js) |
| **Sync model** | **Offline-first local DB + cloud backup/sync** | App always works offline; syncs when online |
| **Cloud** | **Supabase** (Postgres + Auth + Storage) — *primary candidate* | Relational data maps to Postgres; Firebase/Firestore is the fallback option |
| **State mgmt** | **Riverpod** | Providers per screen/repository; testable |
| **Layers** | data (Drift + repositories) → domain (models + services) → presentation (screens + providers) | Mirrors today's `db.js` ⟶ screen split |
| **Printing** | `esc_pos_*` for thermal 58 mm; `pdf` + `printing` for A4 quotes | Web printing falls back to browser/PDF |
| **Barcode** | `mobile_scanner` (scan) + `barcode_widget` (labels) | Replaces jsbarcode |
| **Fonts** | Sarabun (Thai) + Barlow/Barlow Condensed (brand) | Keep Thai-first, EN labels |

**Non-goals for v1:** real-time multi-station shared editing (the chosen sync model is
backup/sync, not concurrent multi-writer). That can come later — see §9.

---

## 3. Data layer mapping (localStorage `sa_*` → Drift tables)

The current store keys (`DB_KEYS` in `pos/db.js`) become relational tables. The
transactional invariants in `db.js` MUST be preserved as Dart service methods.

| Today (`sa_*` / JSON) | Flutter (Drift table) | Carry-over rules to preserve |
|---|---|---|
| `sa_products` | `products` | strict stock arithmetic (no `max(0,…)` masking); weighted-avg `cost` |
| `sa_sales` | `sales` + `sale_items` | `saveSale` = transactional snapshot/rollback; store `pointsGranted` |
| `sa_customers` | `customers` | loyalty points; (future: `taxId`/`branchNo` for tax invoice) |
| `sa_mechanics` | `mechanics` | credit limit; credit-payment intake |
| `sa_purchase_orders` | `purchase_orders` + `po_items` | `receivePO` weighted-average cost |
| `sa_returns` | `returns` + credit notes | `createReturn` transactional; per-line over-refund guard; auto-void |
| `sa_quotes` | `quotes` + `quote_items` | quotes never touch stock; `quoteValidDays` default |
| `sa_parked` | `parked_sales` | cart snapshots only; re-validate stock on resume |
| `sa_shift_history` / current shift | `shifts` | `openShift` archives prior shift; never lose a day |
| `sa_settings` | `settings` (key/value or typed row) | frozen defaults; stable reads |
| `sa_schema_version` | Drift `schemaVersion` + `onUpgrade` | migrations run only when stored < current |

**Document numbers / IDs:** port `_newId(prefix)` and `_docNo('XX')` to Dart helpers
(UUID + base36 timestamp). Never inline `DateTime.now()` for doc numbers.

**Output-safety helpers:** `htmlEsc` is no longer needed (no `document.write` popups in
Flutter). `csvSafe` (CSV formula-injection guard) **must** be ported for CSV export.

---

## 4. Screen parity (1:1 port)

Each current screen maps to a Flutter screen + Riverpod provider. Behaviour parity first,
redesign second.

| Current file | Flutter screen | Priority |
|---|---|---|
| `CheckoutScreen.jsx` | `checkout_screen.dart` | P0 (MVP) |
| `Receipt.jsx` | `receipt_view.dart` (thermal/PDF) | P0 |
| `CashDrawer.jsx` / `ClosingReport.jsx` | `cash_drawer_screen.dart` / closing report | P0 |
| `ProductsScreen.jsx` | `products_screen.dart` | P1 |
| `PurchaseOrdersScreen.jsx` | `purchase_orders_screen.dart` | P1 |
| `LabelPrinter.jsx` / `LowStockAlert.jsx` | label print / low-stock toast | P1 |
| `VehicleSearch.jsx` | `vehicle_search.dart` | P1 |
| `CustomersScreen.jsx` / `MechanicsScreen.jsx` | customers / mechanics | P2 |
| `ReturnsScreen.jsx` | `returns_screen.dart` | P2 |
| `Quote.jsx` (+ QuotesManager) | `quote_screen.dart` + manager | P2 |
| `ReportsScreen.jsx` | `reports_screen.dart` | P3 |
| `SettingsScreen.jsx` + `BackupRestore.jsx` / `ExportCSV.jsx` | settings + backup/restore + CSV | P3 |

---

## 5. Phased roadmap

> Each phase ends in something runnable + tested. Don't start the next phase until the
> current one's data-layer invariants have unit tests.

- **Phase 0 — Setup.** Flutter project, package selection, lint/CI, app theme (navy/orange,
  Sarabun + Barlow). Decide Supabase vs Firebase (spike). *Exit:* empty app builds on
  Android, iOS, Web.
- **Phase 1 — Data layer.** Drift schema (tables in §3), repositories, and the
  transactional services (`saveSale`, `createReturn`, `receivePO`, `openShift`, quotes,
  parked). Port `_newId`/`_docNo`/`csvSafe`. **Unit tests for every transactional rule.**
  *Exit:* data layer green on tests, no UI.
- **Phase 2 — Compatibility import.** Importer that reads the existing
  `DB.exportSnapshot()` JSON (the `__meta` + `sa_*` backup format) and seeds Drift, so the
  live shop data carries over. *Exit:* a real backup file imports cleanly.
- **Phase 3 — Core sales (MVP).** Checkout + Receipt + Cash Drawer/Closing. Usable at the
  counter offline. *Exit:* can ring a sale, print, close a shift on a tablet.
- **Phase 4 — Inventory & purchasing.** Products, PO + receive (weighted-avg), barcode
  label print, low-stock alert, vehicle search.
- **Phase 5 — Customers, mechanics, returns, quotes.** Loyalty, credit + repayment,
  partial returns/void/credit notes, A4 quotation + manager.
- **Phase 6 — Reports, settings, local backup/restore + CSV.** Net-revenue KPIs, top
  products, by-category; settings; local backup/restore + CSV export (with `csvSafe`).
- **Phase 7a — Cloud backup (do this first; it alone meets the exit criterion).**
  First: **dev/prod env split** (`--dart-define=ENV`, separate Supabase projects/keys per
  env) so cloud work never touches live shop data. Then: Supabase auth; scheduled +
  manual **snapshot backup** (`exportSnapshot()` shape) to Supabase Storage; restore path
  mirroring the atomic import; **one full backup→restore drill on a dev project**.
  *Exit:* device loss no longer means data loss. **Safe pause point** — 7b can wait
  until a second device actually exists.
- **Phase 7b — Record-level sync (optional until multi-device).** Push/pull sync queue +
  conflict policy (§6). **Schema prerequisite:** LWW-by-`updatedAt` needs an `updatedAt`
  column on every mutable table — today only `products` has one; `customers`,
  `mechanics`, `settings` need it added. That is a Drift schema change + migration, so it
  requires a `build_runner` run **on an ASCII path** (see `CLAUDE.md` build-path
  constraint). *Exit:* two devices converge after offline edits.
- **Phase 8a — Software hardening (no shop visit needed; can run parallel to 7).**
  **Manager-PIN role gate (SEC-003)**; audit log (QA-001); PDPA (SEC-004); bundle
  Sarabun/Barlow fonts as assets; fold in remaining software follow-ups from `CLAUDE.md`.
- **Phase 8b — Hardware validation (needs physical access to shop devices).** Real
  thermal-printer + barcode-scanner + cash-drawer-kick testing; Flutter Web build & print
  path on the shop PC.
- **Phase 9 — Pilot & cutover.** **Cutover rehearsal first**: at least once before the
  real day, freeze the JS app, export a live backup, import via the Phase-2 importer, and
  verify against the golden file — zero loss. Then run the Flutter app in parallel with
  the JS app, do the real migration the same way, train staff, and decommission
  `POS.html`.

---

## 6. Sync & conflict policy (Phase 7a backup · 7b sync)

- **Offline-first:** all writes hit local Drift first; a sync queue pushes changes when
  online. Reads never block on network.
- **Backup:** full snapshot (same logical shape as `exportSnapshot`) uploaded to Supabase
  Storage on a schedule + manual trigger. Restore mirrors today's **atomic** import.
- **Sync (record-level):** sales/returns/POs are **append-only events** → push-only, no
  merge conflict. Mutable rows (products, customers, mechanics, settings) use
  **last-write-wins by `updatedAt`** for v1; flag conflicts for review rather than silently
  dropping. (True multi-writer CRDT is out of scope for v1.)
- Keep "last backup time" **out** of any restorable snapshot (today it lives outside
  `DB_KEYS_ALL`); store sync/backup control state in device-local prefs so a restore can't
  rewrite it.

---

## 7. Key packages (proposed)

| Concern | Package(s) |
|---|---|
| Local DB | `drift`, `sqlite3_flutter_libs`, `drift_flutter` (web: `drift` WASM) |
| State | `flutter_riverpod`, `riverpod_annotation` |
| Cloud | `supabase_flutter` (or `firebase_core` + `cloud_firestore` fallback) |
| Thermal print | `esc_pos_utils_plus`, `print_bluetooth_thermal` / `flutter_esc_pos_network` |
| A4 / PDF | `pdf`, `printing` |
| Barcode | `mobile_scanner`, `barcode_widget` |
| CSV | `csv` (+ ported `csvSafe`) |
| Models/codegen | `freezed`, `json_serializable` |
| Routing | `go_router` |

*All version pins decided in Phase 0; lock them like the current `POS.html` CDN pins.*

---

## 8. Risks & open questions

| Risk / question | Mitigation / who decides |
|---|---|
| **Thermal printing on Flutter Web** is limited (no direct USB/BT ESC-POS). | Web prints via browser/PDF; native thermal stays on mobile. Confirm acceptable. |
| **Drift on Web** (WASM/sql.js) maturity & bundle size. | Spike in Phase 0; fallback: web uses IndexedDB-backed store. |
| **Cash-drawer kick** needs a printer/driver that exposes it. | Validate against the shop's actual hardware in Phase 8b. |
| **Data-migration fidelity** from localStorage JSON. | Phase-2 importer + golden-file test against a real backup. |
| **Supabase vs Firebase** final pick. | Phase-0 spike; Postgres relational fit favors Supabase. |
| **Thai rendering / fonts** across platforms. | Bundle Sarabun; test receipts + A4 + web. |
| **Who maintains the JS app during the build?** | JS app stays the source of truth until Phase 9 cutover. |

---

## 9. Out of scope for v1 (future)

- Real-time concurrent multi-station editing (beyond backup/sync).
- Tax Invoice (ใบกำกับภาษีเต็มรูป A4) — needs `taxId`/`branchNo`; planned, not v1.
- Vehicle↔Part fitment linkage, service history, bundle/kit pricing (carried from
  `CLAUDE.md` follow-ups; revisit after parity is reached).

---

## 10. Definition of done (migration complete)

1. Flutter app runs on Android, iOS, and Web with **feature parity** to the JS app.
2. Every transactional rule from `db.js` has a passing Dart unit test.
3. A real shop backup imports with **zero data loss** (golden-file verified).
4. Cloud backup/sync works; device loss is recoverable.
5. Receipts (58 mm) and quotes (A4) print correctly on shop hardware.
6. Staff trained; `POS.html` decommissioned; this plan archived with a post-mortem.

---

## 11. Progress log

- **2026-07-03 — Plan revised after Phase 0–6 completion (see `CLAUDE.md` for build status).**
  - Status header updated: Phases 0–6 are done (all 11 screens, data layer + tests,
    shifts, web-DB runtime); Phase 7 is next.
  - **Phase 7 split into 7a (snapshot backup — meets the exit criterion alone) and
    7b (record-level sync — optional until a second device exists).** 7a keeps the
    dev/prod env split as its first step.
  - Flagged 7b's hidden prerequisite: `updatedAt` column missing on `customers` /
    `mechanics` / `settings` (only `products` has it) → Drift schema change →
    `build_runner` on an ASCII path.
  - **Phase 8 split into 8a (software: PIN gate, audit log, PDPA, bundled fonts — can
    run parallel to Phase 7) and 8b (hardware: printer/scanner/drawer — needs shop
    access).**
  - Phase 9 now requires a **cutover rehearsal** (freeze → export → import → golden-file
    verify) before the real migration day.
- **2026-06-23 — Pre-`git init` preparation complete.**
  - Migration plan authored (this file); pointers added in `CLAUDE.md` + `MAINTENANCE.md`.
  - Repo hygiene added: `.gitignore`, `.gitattributes`, `.editorconfig`, `.env.example`
    (verified in a throwaway repo — ignores/tracks resolve correctly).
  - Root `README.md` given a project header (run steps + doc map + license/credit);
    design-system brand guide kept below it (the `srisurart-design` skill still reads it).
  - `PLAN.md` moved into `docs/plans/` next to `data-durability-architecture.draft.html`
    + `step0-fsa-persistence-test.html`; cross-linked.
  - **Decisions:** target = Flutter on **Android/iOS + Web**; **offline-first Drift/SQLite
    + Supabase cloud backup/sync**; app stays at repo root for now (Flutter → `app/`).
  - **Next:** `git init` (ideally in a non-cloud-synced path) → commit baseline →
    `git tag v1.0-js-localstorage` → start **Phase 0** (Flutter scaffold; Supabase-vs-Firebase spike).
