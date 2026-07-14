// AppDatabase — Drift database root.
//
// Schema v1. Seeds the JS SEED_* demo data and _DEFAULT_SETTINGS on first
// create (onCreate), matching pos/db.js EXACTLY.
//
//  • App runtime:   AppDatabase.open()  → drift_flutter driftDatabase(name: 'srisurart')
//  • Tests:         AppDatabase(NativeDatabase.memory())
//
// IMPORTANT: run `dart run build_runner build` after editing this file or
// tables.dart so database.g.dart regenerates.

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'database.g.dart';

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
    Shifts,
    DrawerEntries,
    ParkedSales,
    SettingsRow,
    AppMeta,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

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
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _seed();
    },
  );

  Future<void> _seed() async {
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

    // ── Default settings row (_DEFAULT_SETTINGS) — singleton id = 0 ──
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
}
