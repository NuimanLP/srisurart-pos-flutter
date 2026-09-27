// #455: `patchSaleFromPushReply` copies the full `POST /sales`-shaped push reply
// onto an offline bill — and leaves alone what it must not touch.

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/sync/sale_push_patch.dart';

OutboxOpRow _op(
  String id,
  Map<String, dynamic> payload,
  List<String> aggregates,
) => OutboxOpRow(
  opId: 'op_$id',
  idempotencyKey: 'k_$id',
  type: 'sale.create',
  payload: jsonEncode(payload),
  aggregates: jsonEncode(aggregates),
  createdAt: DateTime.utc(2026, 9, 15),
  status: 'pending',
  attempts: 0,
);

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db
        .into(db.sales)
        .insert(
          SaleRow(
            id: 's1',
            receiptNo: 'RC01-2569-09-0001',
            subtotal: 170,
            discount: 0,
            total: 170,
            paymentMethod: 'เครดิตช่าง',
            customerId: 'c1',
            mechanicId: 'm1',
            pointsGranted: 17,
            date: DateTime.utc(2026, 9, 15, 1),
            voided: false,
            shiftId: 'sh_local',
            soldOffline: true,
          ),
        );
    // Same product on two lines at different prices: the cost joins on lineNo.
    for (final price in [85.0, 0.0]) {
      await db
          .into(db.saleItems)
          .insert(
            SaleItemsCompanion.insert(
              saleId: 's1',
              productId: 'p1',
              name: 'Oil Filter',
              qty: 1,
              price: price,
            ),
          );
    }
  });

  tearDown(() => db.close());

  final payload = {
    'id': 's1',
    'items': [
      {'lineNo': 1, 'productId': 'p1', 'qty': 1, 'price': '85.00'},
      {'lineNo': 2, 'productId': 'p1', 'qty': 1, 'price': '0.00'},
    ],
  };
  final reply = {
    'id': 's1',
    'date': '2026-09-15T02:00:00.000Z',
    'shiftId': 'sh_srv',
    'items': [
      {'lineNo': 2, 'productId': 'p1', 'costAtSale': '12.00'},
      {'lineNo': 1, 'productId': 'p1', 'costAtSale': '50.00'},
    ],
    'movements': [
      {
        'id': 'mv_1',
        'productId': 'p1',
        'partNo': 'HN-15412-KVB',
        'name': 'Oil Filter',
        'delta': -2,
        'type': 'sale',
        'note': null,
        'stockAfter': 40,
        'date': '2026-09-15T02:05:00.000Z',
      },
    ],
    'customerAfter': {'id': 'c1', 'points': 467, 'totalSpend': '4670.00'},
    'mechanicAfter': {
      'id': 'm1',
      'totalSales': '170.00',
      'totalDiscount': '0.00',
      'totalMarkup': '0.00',
      'creditBalance': '170.00',
    },
  };

  test(
    'patches header, per-line cost by lineNo, ledgers and movements',
    () async {
      final op = _op('1', payload, ['sale:s1', 'customer:c1', 'mechanic:m1']);
      await db.transaction(
        () => patchSaleFromPushReply(db, op, reply, const []),
      );

      final sale = await (db.select(
        db.sales,
      )..where((t) => t.id.equals('s1'))).getSingle();
      expect(sale.shiftId, 'sh_srv');
      expect(sale.date.isAtSameMomentAs(DateTime.utc(2026, 9, 15, 2)), isTrue);
      final lines =
          await (db.select(db.saleItems)
                ..where((t) => t.saleId.equals('s1'))
                ..orderBy([(t) => OrderingTerm.asc(t.rowId)]))
              .get();
      expect(lines.map((l) => l.costAtSale), [50.0, 12.0]);
      final c1 = await (db.select(
        db.customers,
      )..where((t) => t.id.equals('c1'))).getSingle();
      expect((c1.points, c1.totalSpend), (467, 4670.0));
      final m1 = await (db.select(
        db.mechanics,
      )..where((t) => t.id.equals('m1'))).getSingle();
      expect((m1.totalSales, m1.creditBalance), (170.0, 170.0));
      expect((await db.select(db.movements).get()).map((m) => m.id), ['mv_1']);

      // A replayed reply is a no-op, not a second log row.
      await db.transaction(
        () => patchSaleFromPushReply(db, op, reply, const []),
      );
      expect(await db.select(db.movements).get(), hasLength(1));
    },
  );

  test(
    'a customer/mechanic a still-queued op names keeps its local totals',
    () async {
      final later = _op(
        '2',
        {'id': 's2'},
        ['sale:s2', 'customer:c1', 'mechanic:m1'],
      );
      await db.transaction(
        () => patchSaleFromPushReply(
          db,
          _op('1', payload, ['sale:s1']),
          reply,
          [later],
        ),
      );

      final c1 = await (db.select(
        db.customers,
      )..where((t) => t.id.equals('c1'))).getSingle();
      expect((c1.points, c1.totalSpend), (450, 4500.0));
      final m1 = await (db.select(
        db.mechanics,
      )..where((t) => t.id.equals('m1'))).getSingle();
      expect(m1.creditBalance, 0.0);
    },
  );

  test(
    'a thin reply (key recorded before #455) leaves every row alone',
    () async {
      await db.transaction(
        () => patchSaleFromPushReply(db, _op('1', payload, ['sale:s1']), {
          'id': 's1',
          'receiptNo': 'RC01-2569-09-0001',
          'total': '170.00',
          'pointsGranted': 17,
        }, const []),
      );

      final sale = await (db.select(
        db.sales,
      )..where((t) => t.id.equals('s1'))).getSingle();
      expect(sale.shiftId, 'sh_local');
      expect(sale.date.isAtSameMomentAs(DateTime.utc(2026, 9, 15, 1)), isTrue);
      final lines = await (db.select(
        db.saleItems,
      )..where((t) => t.saleId.equals('s1'))).get();
      expect(lines.map((l) => l.costAtSale), [null, null]);
      expect(await db.select(db.movements).get(), isEmpty);
    },
  );

  test('lines that do not pair with the payload keep a null cost', () async {
    final mismatched = {
      'id': 's1',
      'items': [
        {'lineNo': 1, 'productId': 'p2', 'qty': 1, 'price': '85.00'},
        {'lineNo': 2, 'productId': 'p1', 'qty': 1, 'price': '0.00'},
      ],
    };
    await db.transaction(
      () => patchSaleFromPushReply(
        db,
        _op('1', mismatched, ['sale:s1']),
        reply,
        const [],
      ),
    );
    final lines = await (db.select(
      db.saleItems,
    )..where((t) => t.saleId.equals('s1'))).get();
    expect(lines.map((l) => l.costAtSale), [null, null]);
  });
}
