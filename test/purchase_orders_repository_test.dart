// Unit tests for PurchaseOrdersRepository — parity with pos/db.js receivePO /
// savePO weighted-average-cost logic. Each test builds an in-memory AppDatabase.
//
// NOTE: AppDatabase seeds default SEED_PRODUCTS on creation (ids p1..pN with
// real Honda/NGK part numbers). Tests therefore use a dedicated test product
// (id 'tp1', partNo 'TEST-1') that cannot collide with the seed.

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/purchase_orders_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';

void main() {
  late AppDatabase db;
  late PurchaseOrdersRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = PurchaseOrdersRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> insertProduct({
    required String id,
    required String partNo,
    required int stock,
    required double cost,
    String name = 'Test Part',
  }) async {
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: id,
            partNo: partNo,
            name: name,
            nameTH: name,
            category: 'general',
            brand: 'X',
            price: 200,
            cost: cost,
            stock: stock,
            minStock: 0,
          ),
        );
  }

  test('savePO assigns id (po…), poNo (PO…), status open, and writes items',
      () async {
    final po = await repo.savePO(const PoInput(
      supplier: 'Acme',
      items: [
        PoLineInput(partNo: 'TEST-1', name: 'Widget', qty: 5, cost: 160),
      ],
    ));

    expect(po.id, startsWith('po'));
    expect(po.poNo, startsWith('PO'));
    expect(po.status, 'open');
    expect(po.supplier, 'Acme');

    final all = await repo.getPOs();
    final mine = all.where((x) => x.po.id == po.id).toList();
    expect(mine.length, 1);
    expect(mine.first.items.length, 1);
    expect(mine.first.items.first.partNo, 'TEST-1');
    expect(mine.first.items.first.qty, 5);
    expect(mine.first.items.first.cost, 160);
  });

  test(
      'receivePO applies exact weighted-average cost (10@100 + 5@160 => 120.0, stock 15)',
      () async {
    await insertProduct(id: 'tp1', partNo: 'TEST-1', stock: 10, cost: 100);

    final po = await repo.savePO(const PoInput(
      supplier: 'Acme',
      items: [
        PoLineInput(partNo: 'TEST-1', name: 'Widget', qty: 5, cost: 160),
      ],
    ));

    final unmatched = await repo.receivePO(po.id);
    expect(unmatched, isEmpty);

    final product =
        await (db.select(db.products)..where((t) => t.id.equals('tp1')))
            .getSingle();
    // (10*100 + 5*160) / 15 = 1800/15 = 120.0
    expect(product.cost, 120.0);
    expect(product.stock, 15);
  });

  test('receivePO returns unmatched partNo and leaves stock untouched for it',
      () async {
    await insertProduct(id: 'tp1', partNo: 'TEST-1', stock: 10, cost: 100);

    final po = await repo.savePO(const PoInput(
      supplier: 'Acme',
      items: [
        PoLineInput(partNo: 'TEST-1', name: 'Widget', qty: 5, cost: 160),
        PoLineInput(partNo: 'NOPE-9', name: 'Ghost', qty: 3, cost: 50),
      ],
    ));

    final unmatched = await repo.receivePO(po.id);
    expect(unmatched, ['NOPE-9']);

    // Matched product still received.
    final matched =
        await (db.select(db.products)..where((t) => t.id.equals('tp1')))
            .getSingle();
    expect(matched.stock, 15);
    expect(matched.cost, 120.0);

    // No product was created for the unmatched partNo.
    final ghost = await (db.select(db.products)
          ..where((t) => t.partNo.equals('NOPE-9')))
        .get();
    expect(ghost, isEmpty);
  });

  test('receivePO matches partNo case-insensitively', () async {
    await insertProduct(id: 'tp1', partNo: 'TeST-1', stock: 10, cost: 100);

    final po = await repo.savePO(const PoInput(
      supplier: 'Acme',
      items: [
        PoLineInput(partNo: 'test-1', name: 'Widget', qty: 5, cost: 160),
      ],
    ));

    final unmatched = await repo.receivePO(po.id);
    expect(unmatched, isEmpty);

    final product =
        await (db.select(db.products)..where((t) => t.id.equals('tp1')))
            .getSingle();
    expect(product.stock, 15);
    expect(product.cost, 120.0);
  });

  test('receivePO marks the PO received and sets receivedAt', () async {
    await insertProduct(id: 'tp1', partNo: 'TEST-1', stock: 10, cost: 100);

    final po = await repo.savePO(const PoInput(
      supplier: 'Acme',
      items: [PoLineInput(partNo: 'TEST-1', name: 'Widget', qty: 5, cost: 160)],
    ));

    await repo.receivePO(po.id);

    final updated =
        await (db.select(db.purchaseOrders)..where((t) => t.id.equals(po.id)))
            .getSingle();
    expect(updated.status, 'received');
    expect(updated.receivedAt, isNotNull);
  });

  test('receivePO writes a receive movement row with stockAfter and note',
      () async {
    await insertProduct(id: 'tp1', partNo: 'TEST-1', stock: 10, cost: 100);

    final po = await repo.savePO(const PoInput(
      supplier: 'Acme',
      items: [PoLineInput(partNo: 'TEST-1', name: 'Widget', qty: 5, cost: 160)],
    ));

    await repo.receivePO(po.id);

    final movements = await db.select(db.movements).get();
    expect(movements.length, 1);
    final mv = movements.first;
    expect(mv.type, 'receive');
    expect(mv.delta, 5);
    expect(mv.stockAfter, 15);
    expect(mv.productId, 'tp1');
    expect(mv.partNo, 'TEST-1');
    // Integer-valued wac renders WITHOUT a trailing .0 (JS template parity).
    expect(mv.note, 'PO ${po.poNo} จาก Acme · ทุนใหม่ ฿120');
  });

  test('receivePO uses newCost=item.cost when cost>0; falls back to oldCost',
      () async {
    // cost == 0 → newCost should fall back to the product's existing cost,
    // so the weighted average stays at the old cost.
    await insertProduct(id: 'tp1', partNo: 'TEST-1', stock: 10, cost: 100);

    final po = await repo.savePO(const PoInput(
      supplier: 'Acme',
      items: [PoLineInput(partNo: 'TEST-1', name: 'Widget', qty: 5, cost: 0)],
    ));

    await repo.receivePO(po.id);

    final product =
        await (db.select(db.products)..where((t) => t.id.equals('tp1')))
            .getSingle();
    expect(product.cost, 100.0); // unchanged: (10*100 + 5*100)/15 = 100
    expect(product.stock, 15);
  });

  test('receivePO on a non-existent PO returns empty list', () async {
    final unmatched = await repo.receivePO('po-missing');
    expect(unmatched, isEmpty);
  });

  test('cancelPO sets status cancelled + cancelledAt', () async {
    final po = await repo.savePO(const PoInput(
      supplier: 'Acme',
      items: [PoLineInput(partNo: 'TEST-1', name: 'Widget', qty: 5, cost: 160)],
    ));

    await repo.cancelPO(po.id);

    final updated =
        await (db.select(db.purchaseOrders)..where((t) => t.id.equals(po.id)))
            .getSingle();
    expect(updated.status, 'cancelled');
    expect(updated.cancelledAt, isNotNull);
  });

  test('deletePO removes the PO and its items', () async {
    final po = await repo.savePO(const PoInput(
      supplier: 'Acme',
      items: [PoLineInput(partNo: 'TEST-1', name: 'Widget', qty: 5, cost: 160)],
    ));

    await repo.deletePO(po.id);

    final remaining = await (db.select(db.purchaseOrders)
          ..where((t) => t.id.equals(po.id)))
        .get();
    expect(remaining, isEmpty);
    final items = await (db.select(db.poItems)
          ..where((t) => t.poId.equals(po.id)))
        .get();
    expect(items, isEmpty);
  });

  test('getPOs returns newest first', () async {
    final first = await repo.savePO(const PoInput(
      supplier: 'A',
      items: [PoLineInput(partNo: 'X', name: 'x', qty: 1, cost: 1)],
    ));
    final second = await repo.savePO(const PoInput(
      supplier: 'B',
      items: [PoLineInput(partNo: 'Y', name: 'y', qty: 1, cost: 1)],
    ));
    // Force a later createdAt for the second PO so ordering is deterministic.
    await (db.update(db.purchaseOrders)..where((t) => t.id.equals(second.id)))
        .write(PurchaseOrdersCompanion(
            createdAt: Value(DateTime.now().add(const Duration(seconds: 5)))));

    final pos = await repo.getPOs();
    expect(pos.length, 2);
    expect(pos.first.po.id, second.id);
    expect(pos.last.po.id, first.id);
  });
}
