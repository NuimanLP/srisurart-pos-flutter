// AppDatabase — Drift database root.
//
// Seeds _DEFAULT_SETTINGS + SEED_CATEGORIES on first create (onCreate),
// matching pos/db.js EXACTLY; the JS SEED_* demo business data only on the
// Drift-only build (`seedDemoData`) — the API build starts as an empty shop.
//
//  • App runtime:   AppDatabase.open()  → drift_flutter driftDatabase(name: 'srisurart')
//  • Tests:         AppDatabase(NativeDatabase.memory())
//
// IMPORTANT: run `dart run build_runner build` after editing this file or
// tables.dart so database.g.dart regenerates.

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'tables.dart';

part 'database.g.dart';

const _useApiWrites = bool.fromEnvironment('USE_API_WRITES');

@DriftDatabase(
  tables: [
    Products,
    Categories,
    Customers,
    Mechanics,
    Sales,
    SaleItems,
    PurchaseOrders,
    PoItems,
    Returns,
    ReturnItems,
    Quotes,
    QuoteItems,
    Movements,
    Suppliers,
    CreditPayments,
    PendingCreditPayments,
    Shifts,
    DrawerEntries,
    ParkedSales,
    SettingsRow,
    DocCounters,
    DocCounterSeeds,
    AppMeta,
    OutboxOps,
    SyncCursors,
    OpEffects,
  ],
)
class AppDatabase extends _$AppDatabase {
  /// [seedDemoData]: whether a fresh DB gets the db.js demo business data
  /// (products, customers, mechanics, suppliers). The Drift-only build keeps
  /// it; the API build (`USE_API_WRITES`) must not — there the server is the
  /// truth and a seeded row reads as the tenant's own (a new tenant is an
  /// empty shop). On the API build an existing DB also has any untouched
  /// seed rows purged on open ([purgeDemoSeed]).
  AppDatabase(super.e, {this.seedDemoData = !_useApiWrites});

  final bool seedDemoData;

  /// App entry point — opens the on-device SQLite DB via drift_flutter.
  /// Tests should instead construct `AppDatabase(NativeDatabase.memory())`.
  ///
  /// On the web, drift needs the compiled `sqlite3.wasm` module and the
  /// `drift_worker.js` worker, both served from the app's `web/` folder
  /// (relative URIs resolve against the deployed base href). These options
  /// are ignored on native platforms.
  factory AppDatabase.open() => AppDatabase(
    driftDatabase(
      name: 'srisurart',
      web: DriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.js'),
      ),
    ),
  );

  /// Matches SCHEMA_VERSION = 2 in db.js (localStorage migration counter),
  /// but Drift's own schemaVersion starts at 1 for this fresh native schema.
  /// The JS schema-version value (2) is seeded into AppMeta as 'schema_version'.
  @override
  int get schemaVersion => 13;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _seed();
      // Nothing to purge on a DB that never had the seed — and the marker
      // keeps a later restored backup's seed-id rows safe (see purgeDemoSeed).
      if (!seedDemoData) await _markDemoSeedPurged();
    },
    // API build: a DB created by an older build (or the Drift build) may still
    // hold the demo seed — purge it before the first screen reads anything.
    beforeOpen: (details) async {
      if (!seedDemoData && !details.wasCreated) await purgeDemoSeed();
    },
    // v1 → v2: sync bookkeeping columns + the cost snapshot on sale lines.
    // All are nullable, so existing rows stay valid and no data is rewritten —
    // bills sold before this upgrade keep costAtSale = NULL on purpose
    // (ADR-0008: never backfill a guessed cost, it is indistinguishable from
    // a real one once written).
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(customers, customers.updatedAt);
        await m.addColumn(customers, customers.deletedAt);
        await m.addColumn(mechanics, mechanics.updatedAt);
        await m.addColumn(mechanics, mechanics.deletedAt);
        await m.addColumn(settingsRow, settingsRow.updatedAt);
        await m.addColumn(settingsRow, settingsRow.deletedAt);
        await m.addColumn(saleItems, saleItems.costAtSale);
      }
      // v2 → v3: the columns the server's shape forces on the client
      // (ADR-0010 decision 2). Sales.shiftId is a plain addition;
      // Shifts.id changes type, which SQLite cannot do in place —
      // both it and the DrawerEntries.shiftId that points at it are rebuilt,
      // CASTing the old integer ids to their text form so every entry stays
      // attached to the shift it already had.
      if (from < 3) {
        await m.addColumn(sales, sales.shiftId);
        await m.alterTable(
          TableMigration(
            shifts,
            columnTransformer: {shifts.id: shifts.id.cast<String>()},
          ),
        );
        await m.alterTable(
          TableMigration(
            drawerEntries,
            columnTransformer: {
              drawerEntries.shiftId: drawerEntries.shiftId.cast<String>(),
            },
          ),
        );
      }
      // v3 → v4 (Ticket #55): Products.deletedAt for soft delete sync
      // (ADR-0010 decision 2: cursor ?updatedSince= sees deletions).
      if (from < 4) {
        await m.addColumn(products, products.deletedAt);
      }
      // v4 → v5 (#24): the credit-payment outbox. A new table, so nothing to
      // rewrite — and nothing to backfill, since only the API build writes it.
      if (from < 5) {
        await m.createTable(pendingCreditPayments);
      }
      // v5 → v6 (#188): the document-number counter and its seed record. New
      // tables only; they start empty and the next seed fills them.
      if (from < 6) {
        await m.createTable(docCounters);
        await m.createTable(docCounterSeeds);
      }
      // v6 → v7 (Ticket #272): Drop Products.offlineOk (ADR-0010 / Phase 2 spec:
      // Postgres never had this column, client drops it).
      if (from < 7) {
        await m.alterTable(TableMigration(products));
      }
      // v7 → v8 (Ticket #274, C16): Clear doc_counter_seeds upon upgrade so
      // stale seed markers from before switch-over are wiped.
      if (from < 8) {
        await delete(docCounterSeeds).go();
      }
      // v8 → v9 (#228, Slice 8-c, 08_PHASE2_SPEC.md §7): outbox_ops table for
      // background sync push and offline-first queue.
      if (from < 9) {
        await m.createTable(outboxOps);
      }
      // v9 → v10 (#276, Slice 11-c): Add soldOffline and voidReason to Sales table.
      if (from < 10) {
        await m.addColumn(sales, sales.soldOffline);
        await m.addColumn(sales, sales.voidReason);
      }
      // v10 → v11 (#212, Slice 13b, 08_PHASE2_SPEC.md §15): sync_cursors table
      // for keyset pull sync and 30s rewind window.
      if (from < 11) {
        await m.createTable(syncCursors);
      }
      // v11 → v12 (#417): indexes only (declared by @TableIndex in
      // tables.dart). No data is rewritten.
      if (from < 12) {
        for (final index in [
          idxProductsPartNoLower,
          idxProductsPartNo,
          idxSalesDate,
          idxSaleItemsSaleId,
          idxPoItemsPoId,
          idxReturnsSaleId,
          idxReturnItemsReturnId,
          idxQuoteItemsQuoteId,
          idxSuppliersProductId,
          idxDrawerEntriesShiftId,
        ]) {
          await m.createIndex(index);
        }
      }
      // v12 → v13 (#488): op_effects, the applied deltas discard reverses
      // from. Starts empty — ops queued before it take the legacy path.
      if (from < 13) {
        await m.createTable(opEffects);
      }
    },
  );

  /// Ids of the db.js SEED_* demo rows [_seed] inserts when [seedDemoData].
  static const seedProductIds = [
    'p1',
    'p2',
    'p3',
    'p4',
    'p5',
    'p6',
    'p7',
    'p8',
    'p9',
    'p10',
    'p11',
    'p12',
  ];
  static const seedCustomerIds = ['c1', 'c2', 'c3'];
  static const seedMechanicIds = ['m1', 'm2', 'm3'];
  static const seedSupplierIds = [
    'sup1',
    'sup2',
    'sup3',
    'sup4',
    'sup5',
    'sup6',
  ];

  /// app_meta key set once the API build's DB is known seed-free.
  static const demoSeedPurgedKey = 'demo_seed_purged';

  Future<void> _markDemoSeedPurged() => into(appMeta).insertOnConflictUpdate(
    const AppMetaCompanion(key: Value(demoSeedPurgedKey), value: Value('1')),
  );

  /// Seed product/customer/mechanic ids that any local record still names —
  /// sale/return/quote/PO lines, movements, credit payments, parked bills.
  /// Such a row is real history (a pre-v2/v3 DB has no `updatedAt` even on an
  /// edited row), so [purgeDemoSeed] keeps it. PO lines carry only a part
  /// number, so those are matched through the seed product's `partNo`.
  Future<Set<String>> _seedIdsInUse() async {
    final ids = <String>{};
    Future<void> add(TableInfo t, GeneratedColumn<String> c) async {
      final q = selectOnly(t, distinct: true)..addColumns([c]);
      for (final r in await q.get()) {
        final v = r.read(c);
        if (v != null) ids.add(v);
      }
    }

    await add(saleItems, saleItems.productId);
    await add(returnItems, returnItems.productId);
    await add(quoteItems, quoteItems.productId);
    await add(movements, movements.productId);
    await add(sales, sales.customerId);
    await add(sales, sales.mechanicId);
    await add(returns, returns.customerId);
    await add(returns, returns.mechanicId);
    await add(creditPayments, creditPayments.mechanicId);
    final poParts = (await select(poItems).get()).map((r) => r.partNo).toSet();
    for (final p in await (select(
      products,
    )..where((t) => t.id.isIn(seedProductIds))).get()) {
      if (poParts.contains(p.partNo)) ids.add(p.id);
    }
    // Parked bills are a JSON blob; a quoted-id match is conservative.
    final parked = await select(parkedSales).get();
    for (final id in [
      ...seedProductIds,
      ...seedCustomerIds,
      ...seedMechanicIds,
    ]) {
      if (parked.any((r) => r.payload.contains('"$id"'))) ids.add(id);
    }
    return ids;
  }

  /// Removes the untouched demo seed from an existing DB (API build), ONCE.
  /// Returns how many rows went, or `null` when it did not run.
  ///
  /// • One-time: a successful run (or a fresh API-build create) writes the
  ///   [demoSeedPurgedKey] marker and every later call is a no-op — a legacy
  ///   backup restored afterwards (`importLegacyBackup`) may carry `c1`/`p1`…
  ///   with no `updatedAt`, and must never be deleted on the next open.
  /// • Refuses while ANY `outbox_ops` row (pending/stuck/rejected) or queued
  ///   credit payment exists — unsent local work may name a seed row; the
  ///   next app open retries.
  /// • Only rows still exactly as seeded go: `updatedAt IS NULL`. A row the
  ///   server sent (pull/upsert stamps the server's `updatedAt`) or a local
  ///   edit stamped is kept — a tenant that imported a legacy backup may
  ///   really own `p1`.
  /// • Never a seed row any local sale/return/quote/PO/movement/credit
  ///   payment/parked bill still names ([_seedIdsInUse]).
  /// • Seed suppliers go only once their product is gone.
  /// Categories, settings and app_meta are left alone: categories are the
  /// same default list the server answers with, and the settings row is the
  /// singleton `GET /settings` patches.
  Future<int?> purgeDemoSeed() => transaction(() async {
    final marker = await (select(
      appMeta,
    )..where((t) => t.key.equals(demoSeedPurgedKey))).getSingleOrNull();
    if (marker != null) return null;
    final queued = await (select(outboxOps)..limit(1)).get();
    final credit = await (select(pendingCreditPayments)..limit(1)).get();
    if (queued.isNotEmpty || credit.isNotEmpty) {
      debugPrint(
        'purgeDemoSeed: skipped — unsent local work '
        '(outbox_ops rows: ${queued.isNotEmpty}, pending credit payments: '
        '${credit.isNotEmpty}); retrying on next open',
      );
      return null;
    }
    final used = await _seedIdsInUse();
    var n =
        await (delete(products)..where(
              (t) =>
                  t.id.isIn(seedProductIds.where((i) => !used.contains(i))) &
                  t.updatedAt.isNull(),
            ))
            .go();
    n +=
        await (delete(customers)..where(
              (t) =>
                  t.id.isIn(seedCustomerIds.where((i) => !used.contains(i))) &
                  t.updatedAt.isNull(),
            ))
            .go();
    n +=
        await (delete(mechanics)..where(
              (t) =>
                  t.id.isIn(seedMechanicIds.where((i) => !used.contains(i))) &
                  t.updatedAt.isNull(),
            ))
            .go();
    n +=
        await (delete(suppliers)..where(
              (t) =>
                  t.id.isIn(seedSupplierIds) &
                  t.productId.isNotInQuery(
                    selectOnly(products)..addColumns([products.id]),
                  ),
            ))
            .go();
    await _markDemoSeedPurged();
    return n;
  });

  /// app_meta keys that describe this DB file, not a shop's data — the only
  /// ones [resetTenantCache] keeps.
  static const _deviceMetaKeys = {
    'schema_version',
    'backup_format_version',
    demoSeedPurgedKey,
  };

  /// Empties the shop cache (API build, tenant switch): every table but
  /// app_meta, and every app_meta key but [_deviceMetaKeys] — that includes
  /// the offline-PIN keys (the old shop's user) and carried-forward `sa_*`
  /// stores. Sync cursors go with it, so the next pull starts from zero. The
  /// default categories and settings row a new DB starts with are put back
  /// (`SettingsRepository.getSettings` needs the singleton).
  ///
  /// Checks nothing: `TenantCacheGuard` decides it is safe and runs this
  /// inside its own transaction.
  Future<void> resetTenantCache() async {
    // Children first: allTables lists every referenced table before its child.
    for (final table in allTables.toList().reversed) {
      if (table == appMeta) continue;
      await delete(table).go();
    }
    await (delete(appMeta)..where((t) => t.key.isNotIn(_deviceMetaKeys))).go();
    await _seedCategories();
    await _seedDefaultSettings();
  }

  Future<void> _seed() async {
    await _seedCategories();

    // ── Demo business data — Drift-only build only (see [seedDemoData]) ──
    if (seedDemoData) await _seedDemoBusinessData();

    // ── Default settings row (_DEFAULT_SETTINGS) — singleton id = 0 ──
    await _seedSettingsAndMeta();
  }

  Future<void> _seedCategories() async {
    // ── Categories (SEED_CATEGORIES, order preserved for color palette) ──
    const seedCategories = ['เครื่องยนต์', 'ไฟฟ้า', 'น้ำมัน', 'เบรก', 'ตัวถัง'];
    await batch((b) {
      for (var i = 0; i < seedCategories.length; i++) {
        b.insert(
          categories,
          CategoriesCompanion.insert(name: seedCategories[i], position: i),
        );
      }
    });
  }

  Future<void> _seedDemoBusinessData() async {
    // ── Products (SEED_PRODUCTS) ──
    await batch((b) {
      b.insertAll(products, [
        ProductsCompanion.insert(
          id: 'p1',
          partNo: 'HN-15412-KVB',
          name: 'Oil Filter',
          nameTH: 'กรองน้ำมันเครื่อง',
          category: 'เครื่องยนต์',
          brand: 'Honda OEM',
          price: 85,
          cost: 45,
          stock: 48,
          minStock: 10,
          compat: const Value('Honda City, Honda Civic, Honda Jazz'),
        ),
        ProductsCompanion.insert(
          id: 'p2',
          partNo: 'NGK-BR8ES-11',
          name: 'Spark Plug NGK',
          nameTH: 'หัวเทียน NGK',
          category: 'ไฟฟ้า',
          brand: 'NGK',
          price: 120,
          cost: 65,
          stock: 32,
          minStock: 15,
          compat: const Value('Toyota Hilux, Toyota Vios, Isuzu D-Max'),
        ),
        ProductsCompanion.insert(
          id: 'p3',
          partNo: 'DID-520VX-110',
          name: 'Drive Chain #520',
          nameTH: 'โซ่ขับ 520',
          category: 'เครื่องยนต์',
          brand: 'DID',
          price: 350,
          cost: 190,
          stock: 14,
          minStock: 5,
          compat: const Value('Ford Ranger, Mitsubishi Triton, Nissan Navara'),
        ),
        ProductsCompanion.insert(
          id: 'p4',
          partNo: 'HN-17210-KWB',
          name: 'Air Filter',
          nameTH: 'กรองอากาศ',
          category: 'เครื่องยนต์',
          brand: 'Honda OEM',
          price: 180,
          cost: 90,
          stock: 22,
          minStock: 8,
          compat: const Value('Honda City, Honda Jazz'),
        ),
        ProductsCompanion.insert(
          id: 'p5',
          partNo: 'YTZ5S-BS-GS',
          name: 'Battery 12V 60Ah',
          nameTH: 'แบตเตอรี่ 12V 60Ah',
          category: 'ไฟฟ้า',
          brand: 'GS Yuasa',
          price: 2800,
          cost: 1900,
          stock: 8,
          minStock: 3,
          compat: const Value('Toyota Camry, Honda Civic, Mazda 2'),
        ),
        ProductsCompanion.insert(
          id: 'p6',
          partNo: 'RK-FA323-R',
          name: 'Brake Pad Set',
          nameTH: 'ผ้าเบรกชุด',
          category: 'เบรก',
          brand: 'RK Excel',
          price: 650,
          cost: 350,
          stock: 19,
          minStock: 6,
          compat: const Value('Toyota Vios, Toyota Hilux, Isuzu D-Max'),
        ),
        ProductsCompanion.insert(
          id: 'p7',
          partNo: 'LED-H4-6000K',
          name: 'LED Headlight H4',
          nameTH: 'ไฟหน้า LED H4',
          category: 'ไฟฟ้า',
          brand: 'Generic',
          price: 480,
          cost: 240,
          stock: 11,
          minStock: 4,
          compat: const Value('Universal H4 socket'),
        ),
        ProductsCompanion.insert(
          id: 'p8',
          partNo: 'TY-13101-0L010',
          name: 'Piston Kit STD',
          nameTH: 'ลูกสูบชุด STD',
          category: 'เครื่องยนต์',
          brand: 'Toyota OEM',
          price: 3200,
          cost: 1900,
          stock: 5,
          minStock: 2,
          compat: const Value('Toyota Hilux 2015+, Toyota Fortuner'),
        ),
        ProductsCompanion.insert(
          id: 'p9',
          partNo: 'IS-8971385180',
          name: 'Fuel Injector',
          nameTH: 'หัวฉีดน้ำมัน',
          category: 'เครื่องยนต์',
          brand: 'Isuzu OEM',
          price: 1800,
          cost: 1100,
          stock: 7,
          minStock: 3,
          compat: const Value('Isuzu D-Max, Isuzu MU-X'),
        ),
        ProductsCompanion.insert(
          id: 'p10',
          partNo: '3M-08080-TAPE',
          name: 'Wiring Tape',
          nameTH: 'เทปพันสายไฟ',
          category: 'ไฟฟ้า',
          brand: '3M',
          price: 35,
          cost: 15,
          stock: 65,
          minStock: 20,
          compat: const Value('Universal'),
        ),
        ProductsCompanion.insert(
          id: 'p11',
          partNo: 'MOTUL-3100-1L',
          name: 'Engine Oil 10W40 1L',
          nameTH: 'น้ำมันเครื่อง 10W40',
          category: 'น้ำมัน',
          brand: 'Motul',
          price: 220,
          cost: 130,
          stock: 40,
          minStock: 12,
          compat: const Value('4-stroke petrol engines'),
        ),
        ProductsCompanion.insert(
          id: 'p12',
          partNo: 'FD-AX7-2020-DS',
          name: 'Disc Brake Rotor',
          nameTH: 'จานเบรกหน้า',
          category: 'เบรก',
          brand: 'Brembo',
          price: 1450,
          cost: 850,
          stock: 6,
          minStock: 3,
          compat: const Value('Ford Ranger, Mazda 2, Mazda 3'),
        ),
      ]);
    });

    // ── Customers (SEED_CUSTOMERS) ──
    await batch((b) {
      b.insertAll(customers, [
        CustomersCompanion.insert(
          id: 'c1',
          code: 'CUS001',
          name: 'Somchai Jaidee',
          nameTH: 'สมชาย ใจดี',
          phone: const Value('081-111-2222'),
          address: const Value('ขอนแก่น'),
          points: const Value(450),
          totalSpend: const Value(4500),
          createdAt: '2024-01-15',
        ),
        CustomersCompanion.insert(
          id: 'c2',
          code: 'CUS002',
          name: 'Nipa Wongsai',
          nameTH: 'นิภา วงศ์ใส',
          phone: const Value('089-333-4444'),
          address: const Value('มหาสารคาม'),
          points: const Value(120),
          totalSpend: const Value(1200),
          createdAt: '2024-03-20',
        ),
        CustomersCompanion.insert(
          id: 'c3',
          code: 'CUS003',
          name: 'Prasit Garage',
          nameTH: 'ประสิทธิ์ การาจ',
          phone: const Value('043-456-7890'),
          address: const Value('ถ.มิตรภาพ ขอนแก่น'),
          points: const Value(2800),
          totalSpend: const Value(28000),
          createdAt: '2023-11-01',
        ),
      ]);
    });

    // ── Mechanics (SEED_MECHANICS) ──
    // JS seed omits totalDiscount (defaults to 0); totalCredit seeded as 0.
    await batch((b) {
      b.insertAll(mechanics, [
        MechanicsCompanion.insert(
          id: 'm1',
          code: 'M001',
          name: 'Lung Manop',
          nameTH: const Value('ลุงมานพ'),
          nickname: const Value('ลุง'),
          shopName: const Value('อู่ลุงมานพ'),
          phone: const Value('081-555-1111'),
          note: const Value('ลูกค้าประจำ ซ่อมรถมอไซต์'),
          creditLimit: const Value(5000),
          creditBalance: const Value(0),
          totalSales: const Value(0),
          totalCredit: const Value(0),
          totalMarkup: const Value(0),
          createdAt: '2024-02-10',
        ),
        MechanicsCompanion.insert(
          id: 'm2',
          code: 'M002',
          name: 'Chang Tao',
          nameTH: const Value('ช่างเต่า'),
          nickname: const Value('เต่า'),
          shopName: const Value('เต่ามอเตอร์'),
          phone: const Value('089-222-3344'),
          note: const Value('รับงานช่วงเช้า'),
          creditLimit: const Value(3000),
          creditBalance: const Value(0),
          totalSales: const Value(0),
          totalCredit: const Value(0),
          totalMarkup: const Value(0),
          createdAt: '2024-04-05',
        ),
        MechanicsCompanion.insert(
          id: 'm3',
          code: 'M003',
          name: 'Pi Boy',
          nameTH: const Value('พี่บอย'),
          nickname: const Value('บอย'),
          shopName: const Value('-'),
          phone: const Value('063-789-0001'),
          note: const Value('อิสระ'),
          creditLimit: const Value(2000),
          creditBalance: const Value(0),
          totalSales: const Value(0),
          totalCredit: const Value(0),
          totalMarkup: const Value(0),
          createdAt: '2024-06-12',
        ),
      ]);
    });

    // ── Suppliers (SEED_SUPPLIERS) ──
    await batch((b) {
      b.insertAll(suppliers, [
        SuppliersCompanion.insert(
          id: 'sup1',
          productId: 'p1',
          name: 'Honda Parts Center',
          unitCost: 42,
          freight: const Value(3),
        ),
        SuppliersCompanion.insert(
          id: 'sup2',
          productId: 'p1',
          name: 'Auto Zone TH',
          unitCost: 38,
          freight: const Value(7),
        ),
        SuppliersCompanion.insert(
          id: 'sup3',
          productId: 'p2',
          name: 'NGK Thailand',
          unitCost: 62,
          freight: const Value(3),
        ),
        SuppliersCompanion.insert(
          id: 'sup4',
          productId: 'p2',
          name: 'Spark King',
          unitCost: 58,
          freight: const Value(8),
        ),
        SuppliersCompanion.insert(
          id: 'sup5',
          productId: 'p5',
          name: 'GS Yuasa Official',
          unitCost: 375,
          freight: const Value(5),
        ),
        SuppliersCompanion.insert(
          id: 'sup6',
          productId: 'p5',
          name: 'Battery World',
          unitCost: 360,
          freight: const Value(20),
        ),
      ]);
    });
  }

  Future<void> _seedSettingsAndMeta() async {
    await _seedDefaultSettings();

    // ── AppMeta — schema_version (2) + backup_format_version (2) from db.js ──
    await batch((b) {
      b.insertAll(appMeta, const [
        AppMetaCompanion(key: Value('schema_version'), value: Value('2')),
        AppMetaCompanion(
          key: Value('backup_format_version'),
          value: Value('2'),
        ),
      ]);
    });
  }

  Future<void> _seedDefaultSettings() async {
    await into(settingsRow).insert(
      SettingsRowCompanion.insert(
        id: const Value(0),
        shopName: 'ศรีสุราษฎร์เจริญยนต์',
        shopNameEN: 'Srisuras Charoen Yon',
        taxRate: const Value(7),
        quoteValidDays: const Value(30),
        address: const Value(
          '76/1 หมู่ 3 ถนนลพบุรีราเมศวร์ ต.คลองแห อ.หาดใหญ่ จ.สงขลา 90110',
        ),
        phone: const Value('081-234-5678'),
        cashierName: const Value('แคชเชียร์'),
      ),
    );
  }
}
