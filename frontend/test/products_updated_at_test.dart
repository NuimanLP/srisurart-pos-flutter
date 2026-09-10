// products.updatedAt must be stamped by every path that changes a product row.
//
// Schema v2 added the column; nothing ever wrote it, so it only round-tripped
// through snapshots (ADR-0010's red flag). `fe.2` plans to fetch with
// `?updatedSince=`, which silently returns nothing when the column stays null,
// so each write path gets its own case here rather than one blanket test.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/repositories/purchase_orders_repository.dart';
import 'package:srisurart_pos/data/repositories/returns_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  /// Clear the stamp so a test cannot pass on a value written by the seed or
  /// by an earlier step, and return the baseline to compare against.
  ///
  /// The baseline is floored to a whole second because drift stores DateTime as
  /// unix **seconds**: a stamp written 40 ms after `DateTime.now()` comes back
  /// with its milliseconds truncated and would otherwise read as earlier.
  Future<DateTime> clearStamp(String id) async {
    await (db.update(db.products)..where((t) => t.id.equals(id))).write(
      const ProductsCompanion(updatedAt: Value(null)),
    );
    final now = DateTime.now();
    return DateTime.fromMillisecondsSinceEpoch(
      (now.millisecondsSinceEpoch ~/ 1000) * 1000,
    );
  }

  Future<DateTime?> stampOf(String id) async {
    final row = await (db.select(
      db.products,
    )..where((t) => t.id.equals(id))).getSingle();
    return row.updatedAt;
  }

  test('add stamps the new row', () async {
    final added = await ProductsRepository(db).add(
      ProductsCompanion.insert(
        id: 'IGNORED',
        partNo: 'STAMP-001',
        name: 'Stamped Part',
        nameTH: 'ของใหม่',
        category: 'ไฟฟ้า',
        brand: 'Acme',
        price: 100,
        cost: 50,
        stock: 5,
        minStock: 1,
      ),
    );
    expect(added, isNotNull);
    expect(added!.updatedAt, isNotNull);
  });

  test('update stamps even when the patch does not mention updatedAt', () async {
    final before = await clearStamp('p1');
    final ok = await ProductsRepository(
      db,
    ).update('p1', const ProductsCompanion(price: Value(999)));

    expect(ok, isTrue);
    final stamp = await stampOf('p1');
    expect(stamp, isNotNull);
    expect(stamp!.isBefore(before), isFalse);
  });

  test('adjustStock stamps', () async {
    final before = await clearStamp('p1');
    await ProductsRepository(db).adjustStock('p1', -2, 'adjust', 'นับสต็อก');

    final stamp = await stampOf('p1');
    expect(stamp, isNotNull);
    expect(stamp!.isBefore(before), isFalse);
  });

  test('saveSale stamps every line it decrements', () async {
    final before = await clearStamp('p1');
    await clearStamp('p2');

    await SalesRepository(db).saveSale(
      SaleInput(
        subtotal: 100,
        discount: 0,
        total: 100,
        paymentMethod: 'เงินสด',
        items: const [
          SaleLineInput(productId: 'p1', name: 'A', qty: 1, price: 50),
          SaleLineInput(productId: 'p2', name: 'B', qty: 1, price: 50),
        ],
      ),
    );

    for (final id in ['p1', 'p2']) {
      final stamp = await stampOf(id);
      expect(stamp, isNotNull, reason: '$id was decremented without a stamp');
      expect(stamp!.isBefore(before), isFalse);
    }
  });

  test('createReturn stamps the lines it restores', () async {
    final sale = await SalesRepository(db).saveSale(
      SaleInput(
        subtotal: 50,
        discount: 0,
        total: 50,
        paymentMethod: 'เงินสด',
        items: const [
          SaleLineInput(productId: 'p1', name: 'A', qty: 1, price: 50),
        ],
      ),
    );
    final before = await clearStamp('p1');

    await ReturnsRepository(db).createReturn(
      ReturnInput(
        saleId: sale.id,
        items: const [
          ReturnLineInput(productId: 'p1', name: 'A', qty: 1, price: 50),
        ],
        refundMethod: 'เงินสด',
      ),
    );

    final stamp = await stampOf('p1');
    expect(stamp, isNotNull);
    expect(stamp!.isBefore(before), isFalse);
  });

  test('a caller-supplied stamp is kept, not overwritten by the local clock',
      () async {
    // ADR-0010 decision 3: once ApiRepository patches rows from a server
    // response, the server's timestamp is the one that counts.
    final fromServer = DateTime(2026, 1, 1, 12);
    await clearStamp('p1');
    final ok = await ProductsRepository(db).update(
      'p1',
      ProductsCompanion(price: const Value(999), updatedAt: Value(fromServer)),
    );

    expect(ok, isTrue);
    expect(await stampOf('p1'), fromServer);
  });

  test('receivePO stamps the line whose cost it recomputed', () async {
    final repo = PurchaseOrdersRepository(db);
    final p1 = await (db.select(
      db.products,
    )..where((t) => t.id.equals('p1'))).getSingle();

    final po = await repo.savePO(
      PoInput(
        supplier: 'Acme',
        items: [
          PoLineInput(partNo: p1.partNo, name: p1.name, qty: 5, cost: 160),
        ],
      ),
    );
    final before = await clearStamp('p1');
    final unmatched = await repo.receivePO(po.id);
    expect(unmatched, isEmpty);

    final stamp = await stampOf('p1');
    expect(stamp, isNotNull);
    expect(stamp!.isBefore(before), isFalse);
  });
}
