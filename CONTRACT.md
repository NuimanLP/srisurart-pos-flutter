# Srisurart POS — Flutter Migration CONTRACT

This is the **binding spec** for the parallel migration. The Contract agent has
made the whole project compile with stubs. Every service agent and screen agent
MUST follow this file so nothing collides. Source of truth for all behaviour:
`D:/Beestation/ร้านศรี/Srisurart Autopart Design System/pos/db.js`.

---

## 0. Hard environment rules (violating these breaks the build)

1. The Flutter project lives ONLY at `C:/srisurart_pos`. Edit with absolute
   paths under `C:/srisurart_pos/`. NEVER create app files under the `D:\` repo.
2. Build/test via the Bash tool with the exact prefix
   `cd /c/srisurart_pos && <cmd>` (cwd resets to the D: repo each call).
3. Use **`dart analyze`** for analysis. NEVER run `flutter analyze` (its LSP
   channel crashes on this machine).
4. Run **`dart run build_runner build`** ONLY if you changed Drift
   `@DataClassName` / `Table` / `@DriftDatabase` code (Schema agent only).
   No `--delete-conflicting-outputs` (removed/ignored). Most agents do NOT touch
   Drift tables and must NOT run build_runner.
5. Do NOT run `flutter pub get` or edit `pubspec.yaml` unless you are the Schema
   agent. Deps already installed: drift, sqlite3_flutter_libs, drift_flutter,
   flutter_bloc, bloc, go_router, intl, uuid, csv, path, path_provider,
   shared_preferences, equatable, google_fonts, flutter_localizations
   (+ dev: drift_dev, build_runner).
6. **Thai UI strings & Thai error messages are behaviour parity** — copy them
   EXACTLY from db.js / the .jsx files. Do not translate or paraphrase.
7. Money rounding must match JS exactly: `round2(v) = (v*100).round()/100`
   (in `lib/core/utils/money.dart`). points = `(total/10).floor()`
   (`pointsFor`). NEVER clamp stock to 0 on a SALE (strict arithmetic);
   manual `adjustStock` DOES clamp at 0.
8. Generate IDs/doc-numbers ONLY via `lib/core/utils/ids.dart`
   (`newId(prefix)`, `docNo(prefix)`). Never inline `DateTime.now()` for a
   document number.
9. Only create/edit the files you are explicitly assigned. Do NOT edit
   `lib/data/db/database.dart`, `lib/core/router/app_router.dart`,
   `pubspec.yaml`, or another agent's file. Need a new shared symbol? Add it
   inside your own file or note it in your final report.
10. After writing your files run `cd /c/srisurart_pos && dart analyze` and fix
    every error IN A FILE YOU OWN. Ignore errors in other agents' files.

---

## 1. Folder layout

```
lib/
  core/
    router/app_router.dart        ← GoRouter + AppRoutes constants (Contract — frozen)
    theme/app_theme.dart          ← AppTheme.light / AppTheme.dark (Schema)
    theme/app_colors.dart         ← brand colors (Schema)
    utils/ids.dart                ← newId(prefix), docNo(prefix) (Schema)
    utils/money.dart              ← baht(), round2(), pointsFor() (Schema)
    utils/csv_safe.dart           ← csvSafe(Object?) (Schema)
  data/
    db/database.dart              ← AppDatabase + @DriftDatabase + seed (Schema — frozen)
    db/database.g.dart            ← GENERATED (Schema)
    db/tables.dart                ← Drift tables (Schema — frozen)
    db/converters.dart            ← type converters (Schema)
    repositories/                 ← ONE file per repository (see §3)
  domain/
    models/aggregates.dart        ← read aggregates + input DTOs (Contract — frozen)
  presentation/
    repositories/repository_providers.dart ← flutter_bloc RepositoryProvider tree (Contract — frozen)
    blocs/                        ← Cubits (ThemeMode, FontScale, PendingQuote, Cart)
    screens/                      ← one stub file per screen (screen agents fill in)
    widgets/app_shell.dart        ← nav frame (Contract; screen agents may extend)
  app.dart                        ← SrisurartApp (Contract)
  main.dart                       ← entry point, DB override (Contract)
test/widget_test.dart            ← trivial passing test (Contract)
```

**Frozen** = do not edit without coordinating; service/screen agents consume but
do not modify. Repositories list their owning agent in §3.

---

## 2. Drift tables + columns (from `lib/data/db/tables.dart`)

Row classes are generated with the **`Row` suffix** via `@DataClassName`.
Screens & services consume these row classes DIRECTLY for flat entities.

| Table | Row class | Companion | Key columns |
|---|---|---|---|
| Products | `ProductRow` | `ProductsCompanion` | id, partNo, name, nameTH, category, brand, price(real), cost(real), stock(int), minStock(int), compat?, zone?(legacy), updatedAt?, offlineOk(bool=false — v3, server-written only) |
| Categories | `CategoryRow` | `CategoriesCompanion` | name (PK), position(int — palette order) |
| Customers | `CustomerRow` | `CustomersCompanion` | id, code, name, nameTH, phone?, address?, points(int=0), totalSpend(real=0), createdAt(text) |
| Mechanics | `MechanicRow` | `MechanicsCompanion` | id, code, name, nameTH?, nickname?, shopName?, phone?, note?, creditLimit(real=0), creditBalance(real=0), totalSales(real=0), totalCredit(real=0), totalDiscount(real=0), totalMarkup(real=0), createdAt(text) |
| Sales | `SaleRow` | `SalesCompanion` | id, receiptNo, subtotal, discount(=0), total, paymentMethod, customerId?, customerName?, mechanicId?, mechanicName?, mechanicDelta?(real), pointsGranted(int=0), date(dateTime), voided(bool=false), voidedAt?, shiftId?(text — v3, server-issued) |
| SaleItems | `SaleItemRow` | `SaleItemsCompanion` | rowId(autoInc PK), saleId→Sales.id, productId, partNo?, name, nameTH?, qty(int), price(real) |
| PurchaseOrders | `PurchaseOrderRow` | `PurchaseOrdersCompanion` | id, poNo, supplier, status(='open'), createdAt, receivedAt?, cancelledAt? |
| PoItems | `PoItemRow` | `PoItemsCompanion` | rowId(autoInc PK), poId→PurchaseOrders.id, partNo, name, qty(int), cost(real) |
| Returns | `ReturnRow` | `ReturnsCompanion` | id, cnNo, saleId, receiptNo, refundSubtotal, refundDiscount, refundTotal, refundMethod, reason(=''), customerId?, mechanicId?, mechanicName?, date |
| ReturnItems | `ReturnItemRow` | `ReturnItemsCompanion` | rowId(autoInc PK), returnId→Returns.id, productId, name, qty(int), price(real), originalQty?(int) |
| Quotes | `QuoteRow` | `QuotesCompanion` | id, quoteNo, status(='open'), date, validUntil, convertedAt?, subtotal?, discount?, total?, customerName?, customerPhone?, notes?, validDays?(int) |
| QuoteItems | `QuoteItemRow` | `QuoteItemsCompanion` | rowId(autoInc PK), quoteId→Quotes.id, productId?, name, qty(int), price(real) |
| Movements | `MovementRow` | `MovementsCompanion` | id, productId, partNo, name, delta(int), type, note?, stockAfter(int), date |
| Suppliers | `SupplierRow` | `SuppliersCompanion` | id, productId, name, unitCost(real), freight(real=0) |
| CreditPayments | `CreditPaymentRow` | `CreditPaymentsCompanion` | id, receiptNo, mechanicId, amount(real), date, note? |
| Shifts | `ShiftRow` | `ShiftsCompanion` | id(text PK — v3, `newId('sh')` offline / server-issued online), dateStr(yyyy-MM-dd), startingCash(real), openedAt, closedAt?, physicalCash?(real), isActive(bool=false), autoArchived(bool=false), archivedAt? |
| DrawerEntries | `DrawerEntryRow` | `DrawerEntriesCompanion` | id, shiftId(text)→Shifts.id, type, amount(real), note?, createdAt |
| ParkedSales | `ParkedSaleRow` | `ParkedSalesCompanion` | id, parkedAt, payload(JSON string) |
| SettingsRow | `SettingsRowData` | `SettingsRowCompanion` | id(singleton=0), shopName, shopNameEN, taxRate(real=7), quoteValidDays(int=30), address?, phone?, cashierName?, taxId?, branchNo? |
| AppMeta | `AppMetaRow` | `AppMetaCompanion` | key(PK), value |

**Mapping notes (db.js → Drift):**
- The JS `sa_cash_drawer` (single active shift) is the `Shifts` row with
  `isActive = true`; `sa_shift_history` is every other `Shifts` row.
- `ParkedSales.payload` holds the cart blob (items/customer/mechanic/discount)
  as a JSON string.
- AppMeta seeds `schema_version=2` and `backup_format_version=2` (these are the
  JS `SCHEMA_VERSION` / `BACKUP_FORMAT_VERSION`).
- Drift's own `schemaVersion => 3` (v2 = sync bookkeeping + costAtSale; v3 =
  the columns the server's shape forces, ADR-0010); the JS migration counter
  value (2) lives in AppMeta, NOT in Drift's schemaVersion — the two numbers
  are unrelated and coincide only by accident.
- Every write that changes a `Products` row stamps `updatedAt` via
  `ProductsCompanion.stamped` (ADR-0010: the client fetches with
  `?updatedSince=`), and a companion that already carries a stamp keeps it, so
  a server timestamp is never overwritten by the local clock. Two paths are
  deliberately exempt and leave the value as-is: `_seed()` and
  `importLegacyBackup()`, which restore rows rather than change them — so a
  freshly seeded or freshly imported database has null stamps, which `fe.2`
  (#55) has to treat as "never synced" rather than "unchanged".
- `offlineOk` and `Sales.shiftId` are the server's to write; nothing offline
  derives them. Neither appears in `exportSnapshot()` — the backup keeps the JS
  `sa_*` shape, so a shiftId written online does not survive a backup/restore.

---

## 3. Repositories — class + methods + owning agent

All repositories live in `lib/data/repositories/`, take an `AppDatabase` in the
constructor, and are exposed through a flutter_bloc `RepositoryProvider` (§4).
Screens MUST go through these repos — never touch `AppDatabase` directly from
a screen.

Three repos are **already fully implemented** by the Contract agent (low-risk).
The other nine are **stubs that `throw UnimplementedError('<name>: pending <agent>')`**
— the owning service agent replaces the bodies (keep the signatures).

### Fully implemented (Contract agent — do not re-stub)

| File | Class | Methods |
|---|---|---|
| `movements_repository.dart` | `MovementsRepository` | `Future<List<MovementRow>> getMovements()`; `Future<MovementRow> addMovement({productId,partNo,name,delta,type,note?,stockAfter})` |
| `suppliers_repository.dart` | `SuppliersRepository` | `getSuppliers()`; `getSuppliersForProduct(productId)`; `addSupplier({productId,name,unitCost,freight=0})`; `updateSupplier(id,{...Value patches})`; `deleteSupplier(id)` |
| `settings_repository.dart` | `SettingsRepository` | `Future<SettingsRowData> getSettings()`; `Stream<SettingsRowData> watchSettings()`; `Future<void> updateSettings(SettingsRowCompanion patch)` |
| `shifts_repository.dart` | `ShiftsRepository` | `Future<ShiftWithEntries?> getCashDrawer()` (single active shift, entries newest-first, or null); `Future<List<ShiftWithEntries>> getShiftHistory()` (inactive shifts, newest openedAt first); `Future<ShiftRow> openShift(double startingCash)` (same-day → returns existing unchanged; else archives prior active shift FIRST — autoArchived+archivedAt if it was never closed — then inserts a new active shift; wrapped in a txn); `Future<DrawerEntryRow> addDrawerEntry(String type, double amount, String? note)` (throws `'No open shift'` if none active; throws Thai `'ลิ้นชักปิดแล้ว ไม่สามารถบันทึกรายการเงินเพิ่มได้'` once the active shift is closed); `Future<ShiftRow?> closeShift(double physicalCash)` (stamps closedAt+physicalCash, shift stays isActive=true as the current drawer until next openShift archives it; null if none) |

### Stubs (each owned by a service agent)

| File | Class | Owning agent | Method signatures |
|---|---|---|---|
| `products_repository.dart` | `ProductsRepository` | **Products** | `Future<List<ProductRow>> getAll()`; `Stream<List<ProductRow>> watchAll()`; `Future<ProductRow?> getById(id)`; `Future<ProductRow?> add(ProductsCompanion)` (null on dup/blank partNo); `Future<bool> update(id, ProductsCompanion)` (false on partNo collision); `Future<void> delete(id)`; `Future<void> adjustStock(productId,delta,type,note?)` (CLAMPS at 0 + movement); `Future<List<String>> getCategories()`; `Future<void> addCategory(name)`; `Future<void> deleteCategory(name)`; `Future<String> catColor(name)` |
| `sales_repository.dart` | `SalesRepository` | **Sales** | `Future<SaleRow> saveSale(SaleInput)` (transactional, Thai 'สต็อกไม่พอ…' throw, strict stock); `Future<List<SaleWithItems>> getSales()`; `Stream<List<SaleWithItems>> watchSales()`; `Future<Map<String,int>> getRefundedQty(saleId)` |
| `returns_repository.dart` | `ReturnsRepository` | **Returns** | `Future<ReturnRow> createReturn(ReturnInput)` (transactional, over-refund/void Thai throws, auto-void parent); `Future<List<ReturnWithItems>> getReturns()` |
| `purchase_orders_repository.dart` | `PurchaseOrdersRepository` | **Purchase Orders** | `Future<List<PurchaseOrderWithItems>> getPOs()`; `Future<PurchaseOrderRow> savePO(PoInput)`; `Future<List<String>> receivePO(id)` (weighted-avg cost, returns unmatched partNos); `Future<void> cancelPO(id)`; `Future<void> deletePO(id)` |
| `quotes_repository.dart` | `QuotesRepository` | **Quotes** | `Future<List<QuoteWithItems>> getQuotes()`; `Future<QuoteRow> saveQuote(QuoteInput)`; `Future<void> updateQuote(id, QuotesCompanion)`; `Future<QuoteRow?> duplicateQuote(id)`; `Future<int> purgeOldQuotes({olderThanDays=90})`; `Future<void> deleteQuote(id)` |
| `parked_repository.dart` | `ParkedRepository` | **Parked** | `Future<List<ParkedSaleRow>> getParked()`; `Future<ParkedSaleRow> parkSale(ParkedInput)`; `Future<void> deleteParked(id)` |
| `mechanics_repository.dart` | `MechanicsRepository` | **Mechanics** | `Future<List<MechanicRow>> getMechanics()`; `Future<MechanicRow> addMechanic(MechanicsCompanion)` (auto M### code); `Future<void> updateMechanic(id, MechanicsCompanion)`; `Future<void> deleteMechanic(id)`; `Future<CreditPaymentRow> addCreditPayment({mechanicId,amount,note?})` (reduces balance, clamp 0); `Future<List<CreditPaymentRow>> getCreditPayments()` |
| `customers_repository.dart` | `CustomersRepository` | **Customers** | `Future<List<CustomerRow>> getCustomers()`; `Future<CustomerRow> addCustomer(CustomersCompanion)` (auto CUS### code); `Future<void> updateCustomer(id, CustomersCompanion)`; `Future<void> deleteCustomer(id)` |
| `snapshot_repository.dart` | `SnapshotRepository` | **Snapshot** | `Future<Map<String,dynamic>> exportSnapshot()` (sa_* keyed + __meta); `Future<void> importLegacyBackup(Map<String,dynamic>)` (atomic; Thai 'ไฟล์สำรองไม่ถูกต้อง — ไม่พบข้อมูล __meta' throw on missing __meta) |

**Behaviour details for the implementers are documented inline at the top of
each stub file** (ported directly from db.js). Read your stub file's header
comment before implementing.

---

## 4. Dependency injection (`lib/presentation/repositories/repository_providers.dart` + `lib/presentation/blocs/`)

Repositories are wired via flutter_bloc's `RepositoryProvider`, not Riverpod.

```dart
repositoryProviders(
  AppDatabase db, {
  AuthRepository? authRepository,   // #54
  ApiClient? apiClient,             // #54
  bool useApi = const bool.fromEnvironment('USE_API_WRITES'),  // #56 — WRITES
  bool useApiRepositories = true,                              // #55 — READS
})
```

There are **two switches and they default differently**, because they gate
different halves of the cutover: `useApi` swaps in #56's API **write** paths
(sales, returns, shifts) and is **off** unless a developer passes
`--dart-define=USE_API_WRITES=true`; `useApiRepositories` swaps in #55's API
**read** paths (products, customers, mechanics, purchase orders, quotes) and is
**on**. Read that pairing before changing either: with reads on and writes off,
a Drift `saveSale` moves local stock and the ledger for a bill the server never
saw, and the next sync overwrites those rows with the server's numbers.

It returns the 13 `RepositoryProvider` entries below **plus `AuthRepository`,
`ApiClient` and `BootstrapService`** (#54/#55), 16 in all; `main.dart` wires them via
`MultiRepositoryProvider`, wrapping `AppDatabase.open()`'s single instance.
Screens read a repo with `context.read<XRepository>()` (never `context.watch` —
repos are DI, not reactive state).

`useApi` (#56) is the phase-1 cutover switch and **defaults to false**: the shop
keeps running the Drift build (CLAUDE.md, *"no cutover is planned for phase 1"*),
and `--dart-define=USE_API_WRITES=true` is what a developer flips to test against
a server. When true, three of the entries below are swapped for their
write-through API implementations from `lib/data/repositories/api/` —
`SalesRepository` → `ApiSalesRepository`, `ReturnsRepository` →
`ApiReturnsRepository`, `ShiftsRepository` → `ApiShiftsRepository`. **The types
in the table do not change**, which is the whole point of ADR-0010: each API
class `implements` the concrete Drift class's implicit interface and keeps a
Drift instance to delegate its reads to, so no screen can tell the difference.

| Repository | Type |
|---|---|
| `ProductsRepository` | `RepositoryProvider<ProductsRepository>` |
| `CustomersRepository` | `RepositoryProvider<CustomersRepository>` |
| `MechanicsRepository` | `RepositoryProvider<MechanicsRepository>` |
| `SalesRepository` | `RepositoryProvider<SalesRepository>` |
| `ReturnsRepository` | `RepositoryProvider<ReturnsRepository>` |
| `PurchaseOrdersRepository` | `RepositoryProvider<PurchaseOrdersRepository>` |
| `QuotesRepository` | `RepositoryProvider<QuotesRepository>` |
| `ParkedRepository` | `RepositoryProvider<ParkedRepository>` |
| `MovementsRepository` | `RepositoryProvider<MovementsRepository>` |
| `SuppliersRepository` | `RepositoryProvider<SuppliersRepository>` |
| `SettingsRepository` | `RepositoryProvider<SettingsRepository>` |
| `SnapshotRepository` | `RepositoryProvider<SnapshotRepository>` |
| `ShiftsRepository` | `RepositoryProvider<ShiftsRepository>` |
| `AuthRepository` | `RepositoryProvider<AuthRepository>` (#54) |
| `ApiClient` | `RepositoryProvider<ApiClient>` (#54) |
| `BootstrapService` | `RepositoryProvider<BootstrapService>` (#55 — fills the cache at login) |

Cross-screen/app-wide UI state lives in Cubits under `lib/presentation/blocs/`
(plus `ThemeModeCubit`/`FontScaleCubit` in `lib/presentation/widgets/`, kept
alongside their persistence helpers), wired via `MultiBlocProvider` in
`main.dart`:

| Cubit | State | Purpose |
|---|---|---|
| `ThemeModeCubit` | `ThemeMode` | app-wide light/dark, persisted `sa_pos_theme` |
| `FontScaleCubit` | `double` | app-wide text scale, persisted `sa_pos_font_scale` |
| `PendingQuoteCubit` | `QuoteWithItems?` | QuotesScreen → CheckoutScreen quote hand-off |
| `CartCubit` | `List<CartLine>` | checkout cart (add/setQty/setPrice/clear) |

Screen agents may add their own Cubit **inside their own screen file or a new
file under `lib/presentation/blocs/`** — do not add repositories to
`repository_providers.dart` (Contract-owned).

---

## 5. Screens — class + file + route + sub-views + owning agent

All screens are `StatelessWidget`/`StatefulWidget` stubs returning a
`Scaffold`. The router imports them by these exact class names. Each screen
agent fills in its file (and may create additional widget files under
`lib/presentation/`).

Screens consume **Drift row classes + repository injection** (rule §3) —
never `AppDatabase`. One-shot loads use a `FutureBuilder` fed by a future
created in `initState` (or an explicit `_refresh()` that calls `setState`) —
never inline in `build`.

| File (`lib/presentation/screens/`) | Class | Route path (AppRoutes) | Sub-views OWNED by this screen agent |
|---|---|---|---|
| `checkout_screen.dart` | `CheckoutScreen` | `/` (`checkout`, home) | Receipt modal, LowStockAlert, park strip, save-quote, mechanic override |
| `products_screen.dart` | `ProductsScreen` | `/products` (`products`) | LabelPrinter (barcode print), stock report, supplier editor |
| `purchase_orders_screen.dart` | `PurchaseOrdersScreen` | `/purchase-orders` (`purchaseOrders`) | PO create + receive |
| `vehicle_search_screen.dart` | `VehicleSearchScreen` | `/vehicle-search` (`vehicleSearch`) | — |
| `customers_screen.dart` | `CustomersScreen` | `/customers` (`customers`) | — |
| `mechanics_screen.dart` | `MechanicsScreen` | `/mechanics` (`mechanics`) | credit-payment intake |
| `returns_screen.dart` | `ReturnsScreen` | `/returns` (`returns`) | credit-note view |
| `quotes_screen.dart` | `QuotesScreen` | `/quotes` (`quotes`) | QuotesManager (list/filter/convert/edit/duplicate/CSV/purge), Quote A4 preview |
| `reports_screen.dart` | `ReportsScreen` | `/reports` (`reports`) | KPIs, top products, by-category |
| `settings_screen.dart` | `SettingsScreen` | `/settings` (`settings`) | BackupRestore (export/import snapshot), ExportCSV |
| `cash_drawer_screen.dart` | `CashDrawerScreen` | `/cash-drawer` (`cashDrawer`) | ClosingReport popup, open/close shift, cash in/out |

`lib/presentation/widgets/app_shell.dart` (`AppShell`) is the persistent nav
frame (NavigationRail on wide, Drawer on narrow). Contract-owned; a screen agent
may extend nav affordances only by coordinating.

**Sub-views need no stub now** — the owning screen agent creates them. They are
the Flutter equivalents of these JSX files:
Receipt.jsx, ClosingReport.jsx, LabelPrinter.jsx, LowStockAlert.jsx,
QuotesManager (in Quote.jsx), BackupRestore.jsx / SettingsScreen backup sub-tab.

---

## 6. Domain models (`lib/domain/models/aggregates.dart`) — Contract-owned, frozen

**Read aggregates** (header row + item rows):
- `SaleWithItems(SaleRow sale, List<SaleItemRow> items)`
- `PurchaseOrderWithItems(PurchaseOrderRow po, List<PoItemRow> items)`
- `QuoteWithItems(QuoteRow quote, List<QuoteItemRow> items)`
- `ReturnWithItems(ReturnRow ret, List<ReturnItemRow> items)`
- `ShiftWithEntries(ShiftRow shift, List<DrawerEntryRow> entries)`

**Input DTOs** (what transactional services accept):
- `SaleInput { double subtotal, discount, total; String paymentMethod;
  String? customerId, customerName, mechanicId, mechanicName; double? mechanicDelta;
  bool overrideCreditLimit = false; List<SaleLineInput> items }`
  - `overrideCreditLimit` (#56) is the counter's answer to
    'ยืนยันขายเครดิต?', **carried** rather than re-derived: the server refuses an
    over-limit credit bill with `409 CREDIT_LIMIT_EXCEEDED` unless it is set, and
    consent cannot be worked out from a mechanic row a later reader sees.
  - `SaleLineInput { String productId, name; int qty; double price; String? partNo, nameTH }`
- `ReturnInput { String saleId; List<ReturnLineInput> items; String refundMethod; String? reason }`
  - `ReturnLineInput { String productId, name; int qty; double price; int? originalQty }`
- `PoInput { String supplier; List<PoLineInput> items }`
  - `PoLineInput { String partNo, name; int qty; double cost }`
- `QuoteInput { double? subtotal, discount, total; String? customerName,
  customerPhone, notes; int? validDays; String? status; List<QuoteLineInput> items }`
  - `QuoteLineInput { String? productId; String name; int qty; double price }`
- `ParkedInput { List<SaleLineInput> items; String? customerId, customerName,
  mechanicId, mechanicName; double? discount; Map<String,dynamic> extra }`

The services compute id / docNo / date / pointsGranted / receiptNo themselves —
those are NOT input fields.

---

## 7. Shared helper signatures (`lib/core/utils/`) — Schema-owned

- `String newId(String prefix)` — `prefix + base36(nowMs) + "_" + uuidShort + "_" + base36(++counter)`
- `String docNo(String prefix)` — `prefix + last-8-digits(nowMs) + uppercase(first-4 uuidShort)`
- `double round2(num v)` — `(v*100).round()/100` (JS `Math.round(v*100)/100`)
- `int pointsFor(num total)` — `(total/10).floor()`
- `String baht(num v)` — `'฿' + #,##0.##` formatted
- `String baht2(num v)` — `'฿' + #,##0.00` (fixed 2-decimal, for cost/margin views)
- `String csvSafe(Object? v)` — prefixes `'` when value starts with `= + - @ \t \r`
- `dates.dart`: `String dateKey(DateTime)` (yyyy-MM-dd), `String todayKey()`,
  `String monthKey()` (yyyy-MM) — the db.js `toISOString().slice(…)` key idiom,
  in LOCAL time; never re-slice `toIso8601String()` inline

**Use these — never inline equivalents.** All CSV exporters MUST pass values
through `csvSafe` before quote-escaping. ID/doc numbers come ONLY from `ids.dart`.

---

## 8. Money / stock / Thai-string rules (parity-critical)

- Round money with `round2`. Points = `pointsFor(total)`.
- **SALE stock = strict** (never clamp to 0; underflow is a bug → throw).
  **Manual `adjustStock` clamps at 0.**
- Weighted-average cost on PO receive:
  `round2((oldStock*oldCost + newQty*newCost)/(oldStock+newQty))`.
- Copy Thai error strings EXACTLY from db.js. Key ones:
  - insufficient stock header: `สต็อกไม่พอ:\n` + per-line
    `<name>: ไม่พบในสต็อก` / `<p.name>: สต็อก <stock> แต่ต้องการ <qty>`
  - over-refund header: `คืนเกินจำนวนที่ขาย:\n` + per-line
    `<name>: ไม่อยู่ในบิลนี้` / `<name>: คืนได้อีก <remaining> แต่ขอคืน <qty>`
  - sale not found / voided: `Sale not found` / `Bill already voided`
  - bad backup: `ไฟล์สำรองไม่ถูกต้อง — ไม่พบข้อมูล __meta`
  - payment method literals: `เครดิตช่าง` (mechanic credit sale),
    refund methods `เงินสด` / `หักจากเครดิต` / `โอน`.

---

## 9. Routes (frozen — `lib/core/router/app_router.dart`)

`AppRoutes` constants:

| Constant | Path |
|---|---|
| `AppRoutes.checkout` | `/` |
| `AppRoutes.products` | `/products` |
| `AppRoutes.purchaseOrders` | `/purchase-orders` |
| `AppRoutes.vehicleSearch` | `/vehicle-search` |
| `AppRoutes.customers` | `/customers` |
| `AppRoutes.mechanics` | `/mechanics` |
| `AppRoutes.returns` | `/returns` |
| `AppRoutes.quotes` | `/quotes` |
| `AppRoutes.reports` | `/reports` |
| `AppRoutes.settings` | `/settings` |
| `AppRoutes.cashDrawer` | `/cash-drawer` |

All wrapped in a `ShellRoute` → `AppShell(child: …)`. Navigate with
`context.go(AppRoutes.x)`.

---

## 10. Workflow reminder for every later agent

1. Read your stub file's header comment + the matching section of db.js.
2. Implement ONLY your assigned file(s). Keep the public signatures in §3 / §5.
3. Use providers (§4) + Drift row classes (§2) + helpers (§7). Never touch
   `AppDatabase` from a screen; never re-inline ids/money/csvSafe.
4. Run `cd /c/srisurart_pos && dart analyze`; fix every error in YOUR files.
5. Do NOT run build_runner / pub get / edit pubspec (Schema agent only).

---

## 11. Shared widgets (`lib/presentation/widgets/`) — UIKit agent

Brand-styled, mostly-const building blocks for all 11 screens. Import the file
you need; do NOT re-implement these. Money goes through `MoneyText`/`baht()`,
confirmations through `showConfirm`, never `showDialog` ad-hoc for yes/no.

| File | Public API | One-liner usage |
|---|---|---|
| `app_button.dart` | `AppButton({required String label, required VoidCallback? onPressed, AppButtonVariant variant = primary, IconData? icon, bool busy=false, bool fullWidth=false})`; named ctors `AppButton.secondary(...)`, `AppButton.danger(...)`; enum `AppButtonVariant { primary, secondary, danger }` | `AppButton(label: 'บันทึก', onPressed: _save, icon: Icons.save)` |
| `app_card.dart` | `AppCard({String? title, Widget? trailing, required Widget child, EdgeInsetsGeometry padding = EdgeInsets.all(16)})` | `AppCard(title: 'สรุป', child: ...)` |
| `app_text_field.dart` | `AppTextField({String? label, hint, TextEditingController? controller, String? initialValue, ValueChanged<String>? onChanged, VoidCallback? onSubmitted, bool numeric=false, autofocus=false, enabled=true, String? errorText, Widget? suffix, TextInputAction? textInputAction, int? maxLines=1})`; named ctor `AppTextField.numeric(...)` (decimal keyboard, digit/`.` filter) | `AppTextField.numeric(label: 'ราคา', controller: _price)` |
| `money_text.dart` | `MoneyText(num value, {bool emphasis=false, TextStyle? style, Color? color})` — uses `baht()`; `emphasis` = large orange bold price | `MoneyText(total, emphasis: true)` |
| `confirm_dialog.dart` | `Future<bool> showConfirm(BuildContext context, String title, String message, {bool danger=false, String confirmLabel='ตกลง', String cancelLabel='ยกเลิก'})` — replaces JS `window.confirm` | `if (await showConfirm(context, 'ลบ', 'ยืนยัน?', danger: true)) ...` |
| `empty_state.dart` | `EmptyState({IconData icon=Icons.inbox_outlined, required String message, String? hint, Widget? action})` | `const EmptyState(message: 'ยังไม่มีรายการ')` |
| `loading_view.dart` | `LoadingView({String? message})` | `loading: () => const LoadingView()` |
| `search_field.dart` | `SearchField({String hint='ค้นหา…', ValueChanged<String>? onChanged, TextEditingController? controller, bool autofocus=false})` — leading magnifier + auto clear (✕) button | `SearchField(hint: 'ค้นหาอะไหล่…', onChanged: (q)=>...)` |
| `section_header.dart` | `SectionHeader(String title, {String? subtitle, Widget? trailing})` | `SectionHeader('สินค้าทั้งหมด', trailing: addBtn)` |
| `status_chip.dart` | `StatusChip(String label, {StatusTone tone = neutral})`; factory `StatusChip.of(String status)` maps open/converted/received/expired/cancelled/voided → Thai label+tone; enum `StatusTone { success, info, warning, danger, neutral }` | `StatusChip.of('converted')` or `StatusChip('ค้างชำระ', tone: StatusTone.warning)` |
| `thai_format.dart` | top-level fns: `String thaiInt(num)`; `String thaiDate(DateTime)` (พ.ศ.); `String thaiDateTime(DateTime)`; `String thaiTime(DateTime)`; `String thaiDateSlash(DateTime)` (numeric "23/06/2569", CSV/receipt shape); `String thaiDateTimeSlash(DateTime)` — dates only; money stays in `baht()` | `Text(thaiDate(sale.date))` |
| `theme_controller.dart` | `ThemeModeCubit extends Cubit<ThemeMode> { Future<void> toggle(); Future<void> set(ThemeMode) }`; persists to shared_preferences key `sa_pos_theme` | `context.read<ThemeModeCubit>().toggle()` |
| `app_shell.dart` | `AppShell({required Widget child})` — Contract+UIKit owned nav frame; topbar (shop name/cashier/date + theme toggle) + NavigationRail(>=1000px)/Drawer; do not edit | router `ShellRoute → AppShell(child: ...)` |

**Coordination note (theme toggle):** the topbar toggle flips
`ThemeModeCubit` and persists it; the root `MaterialApp` in `lib/app.dart`
(Contract-owned) reads it via `themeMode: context.watch<ThemeModeCubit>().state`
so the switch repaints the app. Read and write sides must stay on the same
Cubit — converting one without the other compiles clean but breaks silently
at runtime (see `handoff_log/riverpod-to-bloc.md`'s silent-coupling risks).
