// Drift table definitions — field names match pos/db.js data shapes.
//
// Conventions (from db.js):
//  • String ids ("p1","c1","m1","s…","r…") → TextColumn.
//  • Currency / cost → real(); stock / qty / points → integer().
//  • nullable() where the JS field can be absent.
//  • The JS `sa_cash_drawer` (single active shift) is the Shifts row where
//    isActive = true; `sa_shift_history` is the rest of the rows.
//  • ParkedSales keeps the cart snapshot as a JSON string in `payload`.

import 'package:drift/drift.dart';

@DataClassName('ProductRow')
class Products extends Table {
  TextColumn get id => text()();
  TextColumn get partNo => text()();
  TextColumn get name => text()();
  TextColumn get nameTH => text()();
  TextColumn get category => text()();
  TextColumn get brand => text()();
  RealColumn get price => real()();
  RealColumn get cost => real()();
  IntColumn get stock => integer()();
  IntColumn get minStock => integer()();
  TextColumn get compat => text().nullable()();
  TextColumn get zone =>
      text().nullable()(); // legacy field, migrated to category on read
  DateTimeColumn get updatedAt => dateTime().nullable()();

  /// Schema v3 (ADR-0010): may this line be sold while the client is degraded?
  /// Written ONLY from a server response — never derived here. Defaults to
  /// false so an unknown product is not sellable offline.
  BoolColumn get offlineOk => boolean().withDefault(const Constant(false))();

  /// Schema v4 (Ticket #55): soft delete timestamp from server so that
  /// `?updatedSince=` cursor does not re-resurrect deleted products.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('CategoryRow')
class Categories extends Table {
  TextColumn get name => text()();
  IntColumn get position => integer()(); // preserve order for color palette

  @override
  Set<Column> get primaryKey => {name};
}

@DataClassName('CustomerRow')
class Customers extends Table {
  TextColumn get id => text()();
  TextColumn get code => text()();
  TextColumn get name => text()();
  TextColumn get nameTH => text()();
  TextColumn get phone => text().nullable()();
  TextColumn get address => text().nullable()();
  IntColumn get points => integer().withDefault(const Constant(0))();
  RealColumn get totalSpend => real().withDefault(const Constant(0))();
  TextColumn get createdAt => text()();
  // Sync bookkeeping (schema v2) — see docs/Backend_design/adr/README.md.
  // updatedAt feeds the server's `?updatedSince=` refresh; deletedAt is the
  // tombstone slot for phase-2 sync. Delete is still a hard delete today.
  DateTimeColumn get updatedAt => dateTime().nullable()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MechanicRow')
class Mechanics extends Table {
  TextColumn get id => text()();
  TextColumn get code => text()();
  TextColumn get name => text()();
  TextColumn get nameTH => text().nullable()();
  TextColumn get nickname => text().nullable()();
  TextColumn get shopName => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get note => text().nullable()();
  RealColumn get creditLimit => real().withDefault(const Constant(0))();
  RealColumn get creditBalance => real().withDefault(const Constant(0))();
  RealColumn get totalSales => real().withDefault(const Constant(0))();
  RealColumn get totalCredit => real().withDefault(const Constant(0))();
  RealColumn get totalDiscount => real().withDefault(const Constant(0))();
  RealColumn get totalMarkup => real().withDefault(const Constant(0))();
  TextColumn get createdAt => text()();
  // Sync bookkeeping (schema v2) — see Customers above.
  DateTimeColumn get updatedAt => dateTime().nullable()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SaleRow')
class Sales extends Table {
  TextColumn get id => text()();
  TextColumn get receiptNo => text()();
  RealColumn get subtotal => real()();
  RealColumn get discount => real().withDefault(const Constant(0))();
  RealColumn get total => real()();
  TextColumn get paymentMethod => text()();
  TextColumn get customerId => text().nullable()();
  TextColumn get customerName => text().nullable()();
  TextColumn get mechanicId => text().nullable()();
  TextColumn get mechanicName => text().nullable()();
  RealColumn get mechanicDelta => real().nullable()();
  IntColumn get pointsGranted => integer().withDefault(const Constant(0))();
  DateTimeColumn get date => dateTime()();
  BoolColumn get voided => boolean().withDefault(const Constant(false))();
  DateTimeColumn get voidedAt => dateTime().nullable()();

  /// Schema v3 (ADR-0010): the shift this bill belongs to, as issued by the
  /// server (`sales.shift_id`). Nullable because every bill written by the
  /// offline build has none. Deliberately NOT a `references(Shifts, #id)`:
  /// a patched bill can name a shift this cache has never seen.
  TextColumn get shiftId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SaleItemRow')
class SaleItems extends Table {
  IntColumn get rowId => integer().autoIncrement()();
  TextColumn get saleId => text().references(Sales, #id)();
  TextColumn get productId => text()();
  TextColumn get partNo => text().nullable()();
  TextColumn get name => text()();
  TextColumn get nameTH => text().nullable()();
  IntColumn get qty => integer()();
  RealColumn get price => real()();
  // Cost snapshot at the moment of sale (ADR-0008). NULL on bills created
  // before schema v2 — reports must label those periods as estimated, never
  // backfill them. products.cost changes on every weighted-average PO receive,
  // so it can NOT be used to reconstruct historical profit.
  RealColumn get costAtSale => real().nullable()();
}

@DataClassName('PurchaseOrderRow')
class PurchaseOrders extends Table {
  TextColumn get id => text()();
  TextColumn get poNo => text()();
  TextColumn get supplier => text()();
  TextColumn get status => text().withDefault(const Constant('open'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get receivedAt => dateTime().nullable()();
  DateTimeColumn get cancelledAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('PoItemRow')
class PoItems extends Table {
  IntColumn get rowId => integer().autoIncrement()();
  TextColumn get poId => text().references(PurchaseOrders, #id)();
  TextColumn get partNo => text()();
  TextColumn get name => text()();
  IntColumn get qty => integer()();
  RealColumn get cost => real()();
}

@DataClassName('ReturnRow')
class Returns extends Table {
  TextColumn get id => text()();
  TextColumn get cnNo => text()();
  TextColumn get saleId => text()();
  TextColumn get receiptNo => text()();
  RealColumn get refundSubtotal => real()();
  RealColumn get refundDiscount => real()();
  RealColumn get refundTotal => real()();
  TextColumn get refundMethod => text()();
  TextColumn get reason => text().withDefault(const Constant(''))();
  TextColumn get customerId => text().nullable()();
  TextColumn get mechanicId => text().nullable()();
  TextColumn get mechanicName => text().nullable()();
  DateTimeColumn get date => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ReturnItemRow')
class ReturnItems extends Table {
  IntColumn get rowId => integer().autoIncrement()();
  TextColumn get returnId => text().references(Returns, #id)();
  TextColumn get productId => text()();
  TextColumn get name => text()();
  IntColumn get qty => integer()();
  RealColumn get price => real()();
  IntColumn get originalQty => integer().nullable()();
}

@DataClassName('QuoteRow')
class Quotes extends Table {
  TextColumn get id => text()();
  TextColumn get quoteNo => text()();
  TextColumn get status => text().withDefault(const Constant('open'))();
  DateTimeColumn get date => dateTime()();
  DateTimeColumn get validUntil => dateTime()();
  DateTimeColumn get convertedAt => dateTime().nullable()();
  RealColumn get subtotal => real().nullable()();
  RealColumn get discount => real().nullable()();
  RealColumn get total => real().nullable()();
  TextColumn get customerName => text().nullable()();
  TextColumn get customerPhone => text().nullable()();
  TextColumn get notes => text().nullable()();
  IntColumn get validDays => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('QuoteItemRow')
class QuoteItems extends Table {
  IntColumn get rowId => integer().autoIncrement()();
  TextColumn get quoteId => text().references(Quotes, #id)();
  TextColumn get productId => text().nullable()();
  TextColumn get name => text()();
  IntColumn get qty => integer()();
  RealColumn get price => real()();
  // Cost snapshot at the moment of sale (ADR-0008). NULL on bills created
  // before schema v2 — reports must label those periods as estimated, never
  // backfill them. products.cost changes on every weighted-average PO receive,
  // so it can NOT be used to reconstruct historical profit.
  RealColumn get costAtSale => real().nullable()();
}

@DataClassName('MovementRow')
class Movements extends Table {
  TextColumn get id => text()();
  TextColumn get productId => text()();
  TextColumn get partNo => text()();
  TextColumn get name => text()();
  IntColumn get delta => integer()();
  TextColumn get type => text()();
  TextColumn get note => text().nullable()();
  IntColumn get stockAfter => integer()();
  DateTimeColumn get date => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SupplierRow')
class Suppliers extends Table {
  TextColumn get id => text()();
  TextColumn get productId => text()();
  TextColumn get name => text()();
  RealColumn get unitCost => real()();
  RealColumn get freight => real().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('CreditPaymentRow')
class CreditPayments extends Table {
  TextColumn get id => text()();
  TextColumn get receiptNo => text()();
  TextColumn get mechanicId => text()();
  RealColumn get amount => real()();
  DateTimeColumn get date => dateTime()();
  TextColumn get note => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ShiftRow')
class Shifts extends Table {
  /// Schema v3 (ADR-0010): TEXT, not an autoincrement integer — the server
  /// issues shift ids (TEXT + `device_id`) and an integer column cannot hold
  /// one. Offline-issued ids come from `newId('sh')`.
  TextColumn get id => text()();
  TextColumn get dateStr => text()(); // yyyy-MM-dd
  RealColumn get startingCash => real()();
  DateTimeColumn get openedAt => dateTime()();
  DateTimeColumn get closedAt => dateTime().nullable()();
  RealColumn get physicalCash => real().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(false))();
  BoolColumn get autoArchived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get archivedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('DrawerEntryRow')
class DrawerEntries extends Table {
  TextColumn get id => text()();
  TextColumn get shiftId => text().references(Shifts, #id)();
  TextColumn get type => text()();
  RealColumn get amount => real()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ParkedSaleRow')
class ParkedSales extends Table {
  TextColumn get id => text()();
  DateTimeColumn get parkedAt => dateTime()();
  TextColumn get payload =>
      text()(); // JSON string: items, customerId, mechanicId, discount, etc.

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SettingsRowData')
class SettingsRow extends Table {
  IntColumn get id => integer()(); // singleton, always 0
  TextColumn get shopName => text()();
  TextColumn get shopNameEN => text()();
  RealColumn get taxRate => real().withDefault(const Constant(7))();
  IntColumn get quoteValidDays => integer().withDefault(const Constant(30))();
  TextColumn get address => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get cashierName => text().nullable()();
  TextColumn get taxId => text().nullable()();
  TextColumn get branchNo => text().nullable()();
  // Sync bookkeeping (schema v2) — see Customers above. Settings is a singleton
  // so deletedAt is unused, but kept for a uniform sync shape across tables.
  DateTimeColumn get updatedAt => dateTime().nullable()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('AppMetaRow')
class AppMeta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
