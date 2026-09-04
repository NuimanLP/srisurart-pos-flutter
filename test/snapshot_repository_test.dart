// SnapshotRepository tests — data-migration fidelity gate.
//
// Builds a representative JS-shape backup Map (the shape produced by the legacy
// DB.exportSnapshot() in pos/db.js), imports it into an in-memory Drift DB,
// asserts table row counts + key fields, then round-trips
// (import → exportSnapshot → re-import) and asserts counts are stable.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/snapshot_repository.dart';

/// A representative JS-shape backup, mirroring DB.exportSnapshot() output:
/// a couple of products, one sale with 2 items, one customer, settings,
/// one active shift with entries, plus a legacy-zone product and one parked bill.
Map<String, dynamic> buildLegacyBackup() {
  return <String, dynamic>{
    'sa_products': [
      {
        'id': 'p1',
        'partNo': 'HN-15412-KVB',
        'name': 'Oil Filter',
        'nameTH': 'กรองน้ำมันเครื่อง',
        'category': 'เครื่องยนต์',
        'brand': 'Honda OEM',
        'price': 85,
        'cost': 45,
        'stock': 48,
        'minStock': 10,
        'compat': 'Honda City',
      },
      // legacy product with a `zone` field and no `category` — must migrate.
      {
        'id': 'p2',
        'partNo': 'NGK-BR8ES-11',
        'name': 'Spark Plug NGK',
        'nameTH': 'หัวเทียน NGK',
        'zone': 'Electrical',
        'brand': 'NGK',
        'price': 120,
        'cost': 65,
        'stock': 32,
        'minStock': 15,
      },
    ],
    'sa_customers': [
      {
        'id': 'c1',
        'code': 'CUS001',
        'name': 'Somchai Jaidee',
        'nameTH': 'สมชาย ใจดี',
        'phone': '081-111-2222',
        'address': 'ขอนแก่น',
        'points': 450,
        'totalSpend': 4500,
        'createdAt': '2024-01-15',
      },
    ],
    'sa_sales': [
      {
        'id': 's1',
        'receiptNo': 'RC12345678ABCD',
        'subtotal': 205,
        'discount': 5,
        'total': 200,
        'paymentMethod': 'เงินสด',
        'customerId': 'c1',
        'customerName': 'Somchai Jaidee',
        'pointsGranted': 20,
        'date': '2024-05-01T03:00:00.000Z',
        'voided': false,
        'items': [
          {
            'productId': 'p1',
            'partNo': 'HN-15412-KVB',
            'name': 'Oil Filter',
            'nameTH': 'กรองน้ำมันเครื่อง',
            'qty': 1,
            'price': 85,
            // The JS app recorded the cost on the line; the second item below
            // deliberately omits it (older bills did not always have one).
            'cost': 40,
          },
          {
            'productId': 'p2',
            'partNo': 'NGK-BR8ES-11',
            'name': 'Spark Plug NGK',
            'qty': 1,
            'price': 120,
          },
        ],
      },
    ],
    'sa_pos': [
      {
        'id': 'po1',
        'poNo': 'PO12345678WXYZ',
        'supplier': 'Honda Parts Center',
        'status': 'open',
        'createdAt': '2024-04-20T02:00:00.000Z',
        'items': [
          {
            'partNo': 'HN-15412-KVB',
            'name': 'Oil Filter',
            'qty': 10,
            'cost': 42,
          },
        ],
      },
    ],
    'sa_settings': {
      'shopName': 'ศรีสุราษฎร์เจริญยนต์',
      'shopNameEN': 'Srisuras Charoen Yon',
      'taxRate': 7,
      'quoteValidDays': 30,
      'address': '76/1 หมู่ 3',
      'phone': '081-234-5678',
      'cashierName': 'แคชเชียร์',
    },
    'sa_mechanics': [
      {
        'id': 'm1',
        'code': 'M001',
        'name': 'Lung Manop',
        'nameTH': 'ลุงมานพ',
        'creditLimit': 5000,
        'creditBalance': 0,
        'totalSales': 0,
        'totalCredit': 0,
        'totalDiscount': 0,
        'totalMarkup': 0,
        'createdAt': '2024-02-10',
      },
    ],
    'sa_quotes': [
      {
        'id': 'q1',
        'quoteNo': 'QT12345678QQQQ',
        'status': 'open',
        'date': '2024-05-02T03:00:00.000Z',
        'validUntil': '2024-06-01T03:00:00.000Z',
        'subtotal': 85,
        'discount': 0,
        'total': 85,
        'customerName': 'Walk-in',
        'items': [
          {'productId': 'p1', 'name': 'Oil Filter', 'qty': 1, 'price': 85},
        ],
      },
    ],
    'sa_returns': [
      {
        'id': 'r1',
        'cnNo': 'CN12345678RRRR',
        'saleId': 's1',
        'receiptNo': 'RC12345678ABCD',
        'refundSubtotal': 85,
        'refundDiscount': 0,
        'refundTotal': 85,
        'refundMethod': 'เงินสด',
        'reason': '',
        'customerId': 'c1',
        'date': '2024-05-03T03:00:00.000Z',
        'items': [
          {
            'productId': 'p1',
            'name': 'Oil Filter',
            'qty': 1,
            'price': 85,
            'originalQty': 1,
          },
        ],
      },
    ],
    'sa_movements': [
      {
        'id': 'mv1',
        'productId': 'p1',
        'partNo': 'HN-15412-KVB',
        'name': 'Oil Filter',
        'delta': 10,
        'type': 'receive',
        'note': 'PO',
        'stockAfter': 58,
        'date': '2024-04-20T02:30:00.000Z',
      },
    ],
    'sa_suppliers': [
      {
        'id': 'sup1',
        'productId': 'p1',
        'name': 'Honda Parts Center',
        'unitCost': 42,
        'freight': 3,
      },
    ],
    'sa_categories': ['เครื่องยนต์', 'ไฟฟ้า', 'น้ำมัน', 'เบรก', 'ตัวถัง'],
    'sa_credit_payments': [
      {
        'id': 'cp1',
        'receiptNo': 'CP12345678CCCC',
        'mechanicId': 'm1',
        'amount': 500,
        'date': '2024-05-04T03:00:00.000Z',
        'note': 'จ่ายเครดิต',
      },
    ],
    'sa_cash_drawer': {
      'date': '2024-05-05',
      'startingCash': 1000,
      'openedAt': '2024-05-05T01:00:00.000Z',
      'closedAt': null,
      'physicalCash': null,
      'entries': [
        {
          'id': 'de1',
          'type': 'in',
          'amount': 200,
          'note': 'ขายสด',
          'createdAt': '2024-05-05T02:00:00.000Z',
        },
        {
          'id': 'de2',
          'type': 'out',
          'amount': 50,
          'note': 'ซื้อของ',
          'createdAt': '2024-05-05T03:00:00.000Z',
        },
      ],
    },
    'sa_shift_history': [
      {
        'date': '2024-05-04',
        'startingCash': 800,
        'openedAt': '2024-05-04T01:00:00.000Z',
        'closedAt': '2024-05-04T10:00:00.000Z',
        'physicalCash': 950,
        'entries': [
          {
            'id': 'de0',
            'type': 'in',
            'amount': 150,
            'note': '',
            'createdAt': '2024-05-04T02:00:00.000Z',
          },
        ],
      },
    ],
    'sa_parked': [
      {
        'id': 'pk1',
        'parkedAt': '2024-05-05T04:00:00.000Z',
        'discount': 0,
        'customerId': null,
        'items': [
          {'productId': 'p1', 'name': 'Oil Filter', 'qty': 2, 'price': 85},
        ],
      },
    ],
    'sa_schema_version': '2',
    '__meta': {
      'version': 2,
      'schemaVersion': 2,
      'exportedAt': '2024-05-06T00:00:00.000Z',
      'shopName': 'ศรีสุราษฎร์เจริญยนต์',
      'recordCounts': {'products': 2, 'sales': 1},
    },
  };
}

void main() {
  late AppDatabase db;
  late SnapshotRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = SnapshotRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('importLegacyBackup throws Thai error when __meta missing', () async {
    final bad = buildLegacyBackup()..remove('__meta');
    expect(
      () => repo.importLegacyBackup(bad),
      throwsA(
        predicate(
          (e) =>
              e.toString().contains('ไฟล์สำรองไม่ถูกต้อง — ไม่พบข้อมูล __meta'),
        ),
      ),
    );
  });

  test('importLegacyBackup seeds Drift with correct row counts', () async {
    await repo.importLegacyBackup(buildLegacyBackup());

    expect((await db.select(db.products).get()).length, 2);
    expect((await db.select(db.customers).get()).length, 1);
    expect((await db.select(db.sales).get()).length, 1);
    expect((await db.select(db.saleItems).get()).length, 2);
    expect((await db.select(db.purchaseOrders).get()).length, 1);
    expect((await db.select(db.poItems).get()).length, 1);
    expect((await db.select(db.mechanics).get()).length, 1);
    expect((await db.select(db.quotes).get()).length, 1);
    expect((await db.select(db.quoteItems).get()).length, 1);
    expect((await db.select(db.returns).get()).length, 1);
    expect((await db.select(db.returnItems).get()).length, 1);
    expect((await db.select(db.movements).get()).length, 1);
    expect((await db.select(db.suppliers).get()).length, 1);
    expect((await db.select(db.categories).get()).length, 5);
    expect((await db.select(db.creditPayments).get()).length, 1);
    expect((await db.select(db.parkedSales).get()).length, 1);
    // active shift (1) + history shift (1) = 2 shifts
    expect((await db.select(db.shifts).get()).length, 2);
    // 2 active-shift entries + 1 history entry = 3 drawer entries
    expect((await db.select(db.drawerEntries).get()).length, 3);
  });

  test('importLegacyBackup migrates legacy zone -> category', () async {
    await repo.importLegacyBackup(buildLegacyBackup());
    final p2 = await (db.select(
      db.products,
    )..where((t) => t.id.equals('p2'))).getSingle();
    // zone 'Electrical' must become category 'ไฟฟ้า'.
    expect(p2.category, 'ไฟฟ้า');
  });

  test('importLegacyBackup nests sale items + key fields correct', () async {
    await repo.importLegacyBackup(buildLegacyBackup());

    final sale = await (db.select(
      db.sales,
    )..where((t) => t.id.equals('s1'))).getSingle();
    expect(sale.receiptNo, 'RC12345678ABCD');
    expect(sale.total, 200);
    expect(sale.discount, 5);
    expect(sale.paymentMethod, 'เงินสด');
    expect(sale.customerId, 'c1');
    expect(sale.pointsGranted, 20);
    expect(sale.voided, false);

    final items = await (db.select(
      db.saleItems,
    )..where((t) => t.saleId.equals('s1'))).get();
    expect(items.length, 2);
    final oilFilter = items.firstWhere((i) => i.productId == 'p1');
    expect(oilFilter.name, 'Oil Filter');
    expect(oilFilter.qty, 1);
    expect(oilFilter.price, 85);
    // ADR-0008: a cost recorded by the JS app must survive the import, and a
    // line without one stays NULL — absent means unknown, never 0 (which would
    // silently read as 100% profit).
    expect(oilFilter.costAtSale, 40);
    final sparkPlug = items.firstWhere((i) => i.productId == 'p2');
    expect(sparkPlug.costAtSale, isNull);
  });

  test('active shift becomes isActive=true with its entries', () async {
    await repo.importLegacyBackup(buildLegacyBackup());
    final active = await (db.select(
      db.shifts,
    )..where((t) => t.isActive.equals(true))).get();
    expect(active.length, 1);
    expect(active.first.dateStr, '2024-05-05');
    expect(active.first.startingCash, 1000);

    final entries = await (db.select(
      db.drawerEntries,
    )..where((t) => t.shiftId.equals(active.first.id))).get();
    expect(entries.length, 2);

    final history = await (db.select(
      db.shifts,
    )..where((t) => t.isActive.equals(false))).get();
    expect(history.length, 1);
    expect(history.first.dateStr, '2024-05-04');
    expect(history.first.physicalCash, 950);
  });

  test('exportSnapshot emits JS shape with __meta + recordCounts', () async {
    await repo.importLegacyBackup(buildLegacyBackup());
    final snap = await repo.exportSnapshot();

    expect(snap.containsKey('__meta'), true);
    final meta = snap['__meta'] as Map<String, dynamic>;
    expect(meta['version'], 2);
    expect(meta['shopName'], 'ศรีสุราษฎร์เจริญยนต์');

    final counts = meta['recordCounts'] as Map<String, int>;
    expect(counts['products'], 2);
    expect(counts['sales'], 1);
    expect(counts['customers'], 1);
    expect(counts['mechanics'], 1);
    expect(counts['quotes'], 1);
    expect(counts['returns'], 1);
    expect(counts['movements'], 1);
    expect(counts['suppliers'], 1);
    expect(counts['categories'], 5);
    expect(counts['creditPayments'], 1);
    expect(counts['parked'], 1);
    expect(counts['shiftHistory'], 1);
    expect(counts['cashDrawer'], 1);

    // schema version preserved as raw string
    expect(snap['sa_schema_version'], '2');

    // sales nest their items[]
    final sales = snap['sa_sales'] as List;
    expect((sales.first as Map)['items'].length, 2);

    // categories is an ordered array of names
    expect(snap['sa_categories'], [
      'เครื่องยนต์',
      'ไฟฟ้า',
      'น้ำมัน',
      'เบรก',
      'ตัวถัง',
    ]);

    // cash drawer is the single active shift object with entries[]
    final cd = snap['sa_cash_drawer'] as Map;
    expect((cd['entries'] as List).length, 2);
    expect(cd['date'], '2024-05-05');
  });

  test(
    'round-trip: import -> export -> re-import keeps counts stable',
    () async {
      await repo.importLegacyBackup(buildLegacyBackup());

      Future<Map<String, int>> counts() async => {
        'products': (await db.select(db.products).get()).length,
        'customers': (await db.select(db.customers).get()).length,
        'sales': (await db.select(db.sales).get()).length,
        'saleItems': (await db.select(db.saleItems).get()).length,
        'pos': (await db.select(db.purchaseOrders).get()).length,
        'poItems': (await db.select(db.poItems).get()).length,
        'mechanics': (await db.select(db.mechanics).get()).length,
        'quotes': (await db.select(db.quotes).get()).length,
        'quoteItems': (await db.select(db.quoteItems).get()).length,
        'returns': (await db.select(db.returns).get()).length,
        'returnItems': (await db.select(db.returnItems).get()).length,
        'movements': (await db.select(db.movements).get()).length,
        'suppliers': (await db.select(db.suppliers).get()).length,
        'categories': (await db.select(db.categories).get()).length,
        'creditPayments': (await db.select(db.creditPayments).get()).length,
        'parked': (await db.select(db.parkedSales).get()).length,
        'shifts': (await db.select(db.shifts).get()).length,
        'drawerEntries': (await db.select(db.drawerEntries).get()).length,
      };

      final before = await counts();

      final exported = await repo.exportSnapshot();
      await repo.importLegacyBackup(exported);

      final after = await counts();
      expect(after, before);

      // active shift still exactly one after the round-trip
      final active = await (db.select(
        db.shifts,
      )..where((t) => t.isActive.equals(true))).get();
      expect(active.length, 1);

      // zone migration still holds (p2 stayed in category, not zone)
      final p2 = await (db.select(
        db.products,
      )..where((t) => t.id.equals('p2'))).getSingle();
      expect(p2.category, 'ไฟฟ้า');
    },
  );
}
