// Unit tests for ReturnsRepository.createReturn — ports db.js createReturn
// invariants (db.js lines 272-385).
//
// Invariants asserted:
//  • over-refund throws ('คืนเกินจำนวนที่ขาย:\n…').
//  • partial return restores stock and reverses customer points proportionally.
//  • full return auto-voids the parent sale.
//  • refundMethod 'หักจากเครดิต' reduces mechanic creditBalance, but a cash
//    refund ('เงินสด') does NOT.

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/returns_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';

void main() {
  late AppDatabase db;
  late ReturnsRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = ReturnsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  // Helper — insert a sale header + items directly so we control the scenario.
  Future<void> insertSale({
    required String id,
    required String receiptNo,
    required double subtotal,
    double discount = 0,
    required double total,
    String paymentMethod = 'เงินสด',
    String? customerId,
    String? customerName,
    String? mechanicId,
    String? mechanicName,
    double? mechanicDelta,
    int pointsGranted = 0,
    bool voided = false,
    required List<({String productId, String name, int qty, double price})>
        items,
  }) async {
    await db.into(db.sales).insert(SalesCompanion.insert(
          id: id,
          receiptNo: receiptNo,
          subtotal: subtotal,
          discount: Value(discount),
          total: total,
          paymentMethod: paymentMethod,
          customerId: Value(customerId),
          customerName: Value(customerName),
          mechanicId: Value(mechanicId),
          mechanicName: Value(mechanicName),
          mechanicDelta: Value(mechanicDelta),
          pointsGranted: Value(pointsGranted),
          date: DateTime.now(),
          voided: Value(voided),
        ));
    for (final it in items) {
      await db.into(db.saleItems).insert(SaleItemsCompanion.insert(
            saleId: id,
            productId: it.productId,
            name: it.name,
            qty: it.qty,
            price: it.price,
          ));
    }
  }

  test('Sale not found throws', () async {
    expect(
      () => repo.createReturn(const ReturnInput(
        saleId: 'nope',
        items: [],
        refundMethod: 'เงินสด',
      )),
      throwsA(predicate((e) => e.toString().contains('Sale not found'))),
    );
  });

  test('Bill already voided throws', () async {
    await insertSale(
      id: 's_void',
      receiptNo: 'R1',
      subtotal: 85,
      total: 85,
      voided: true,
      items: [(productId: 'p1', name: 'Oil Filter', qty: 1, price: 85)],
    );
    expect(
      () => repo.createReturn(const ReturnInput(
        saleId: 's_void',
        items: [ReturnLineInput(productId: 'p1', name: 'Oil Filter', qty: 1, price: 85)],
        refundMethod: 'เงินสด',
      )),
      throwsA(predicate((e) => e.toString().contains('Bill already voided'))),
    );
  });

  test('over-refund throws with Thai message (qty exceeds sold)', () async {
    await insertSale(
      id: 's_over',
      receiptNo: 'R2',
      subtotal: 170,
      total: 170,
      items: [(productId: 'p1', name: 'Oil Filter', qty: 2, price: 85)],
    );

    // Capture original product stock to confirm rollback.
    final before =
        await (db.select(db.products)..where((p) => p.id.equals('p1'))).getSingle();

    expect(
      () => repo.createReturn(const ReturnInput(
        saleId: 's_over',
        items: [ReturnLineInput(productId: 'p1', name: 'Oil Filter', qty: 5, price: 85)],
        refundMethod: 'เงินสด',
      )),
      throwsA(predicate((e) =>
          e.toString().contains('คืนเกินจำนวนที่ขาย:') &&
          e.toString().contains('Oil Filter: คืนได้อีก 2 แต่ขอคืน 5'))),
    );

    // No partial write — stock unchanged, no return persisted.
    final after =
        await (db.select(db.products)..where((p) => p.id.equals('p1'))).getSingle();
    expect(after.stock, before.stock);
    expect(await repo.getReturns(), isEmpty);
  });

  test('item not in bill throws "ไม่อยู่ในบิลนี้"', () async {
    await insertSale(
      id: 's_notin',
      receiptNo: 'R3',
      subtotal: 85,
      total: 85,
      items: [(productId: 'p1', name: 'Oil Filter', qty: 1, price: 85)],
    );
    expect(
      () => repo.createReturn(const ReturnInput(
        saleId: 's_notin',
        items: [ReturnLineInput(productId: 'p2', name: 'Spark Plug', qty: 1, price: 120)],
        refundMethod: 'เงินสด',
      )),
      throwsA(predicate(
          (e) => e.toString().contains('Spark Plug: ไม่อยู่ในบิลนี้'))),
    );
  });

  test('partial return restores stock and reverses customer points proportionally',
      () async {
    // Sale: c1 buys 4 oil filters @85 = 340 total, no discount.
    // pointsGranted = floor(340/10) = 34.
    await insertSale(
      id: 's_partial',
      receiptNo: 'R4',
      subtotal: 340,
      total: 340,
      customerId: 'c1',
      customerName: 'Somchai Jaidee',
      pointsGranted: 34,
      items: [(productId: 'p1', name: 'Oil Filter', qty: 4, price: 85)],
    );

    final stockBefore =
        (await (db.select(db.products)..where((p) => p.id.equals('p1'))).getSingle())
            .stock;
    final custBefore =
        await (db.select(db.customers)..where((c) => c.id.equals('c1'))).getSingle();
    // Seed c1: points 450, totalSpend 4500.
    expect(custBefore.points, 450);
    expect(custBefore.totalSpend, 4500);

    // Refund 1 of 4 → refundTotal 85. ratio = 85/340 = 0.25.
    // pointsToReverse = floor(34 * 0.25) = floor(8.5) = 8.
    final ret = await repo.createReturn(const ReturnInput(
      saleId: 's_partial',
      items: [ReturnLineInput(productId: 'p1', name: 'Oil Filter', qty: 1, price: 85)],
      refundMethod: 'เงินสด',
    ));

    expect(ret.refundSubtotal, 85);
    expect(ret.refundDiscount, 0);
    expect(ret.refundTotal, 85);
    expect(ret.cnNo, startsWith('CN'));

    // Stock restored +1.
    final stockAfter =
        (await (db.select(db.products)..where((p) => p.id.equals('p1'))).getSingle())
            .stock;
    expect(stockAfter, stockBefore + 1);

    // Customer spend −85, points −8.
    final custAfter =
        await (db.select(db.customers)..where((c) => c.id.equals('c1'))).getSingle();
    expect(custAfter.totalSpend, 4500 - 85);
    expect(custAfter.points, 450 - 8);

    // Sale NOT voided (partial).
    final sale =
        await (db.select(db.sales)..where((s) => s.id.equals('s_partial'))).getSingle();
    expect(sale.voided, isFalse);
  });

  test('full return auto-voids the sale', () async {
    await insertSale(
      id: 's_full',
      receiptNo: 'R5',
      subtotal: 240,
      total: 240,
      items: [
        (productId: 'p1', name: 'Oil Filter', qty: 2, price: 85),
        (productId: 'p2', name: 'Spark Plug', qty: 1, price: 70),
      ],
    );

    // Return everything in two steps to prove cumulative qty drives the void.
    await repo.createReturn(const ReturnInput(
      saleId: 's_full',
      items: [ReturnLineInput(productId: 'p1', name: 'Oil Filter', qty: 1, price: 85)],
      refundMethod: 'เงินสด',
    ));
    var sale =
        await (db.select(db.sales)..where((s) => s.id.equals('s_full'))).getSingle();
    expect(sale.voided, isFalse, reason: 'still partial after 1 of 3 units');

    await repo.createReturn(const ReturnInput(
      saleId: 's_full',
      items: [
        ReturnLineInput(productId: 'p1', name: 'Oil Filter', qty: 1, price: 85),
        ReturnLineInput(productId: 'p2', name: 'Spark Plug', qty: 1, price: 70),
      ],
      refundMethod: 'เงินสด',
    ));
    sale =
        await (db.select(db.sales)..where((s) => s.id.equals('s_full'))).getSingle();
    expect(sale.voided, isTrue);
    expect(sale.voidedAt, isNotNull);
  });

  test('refundMethod "หักจากเครดิต" reduces mechanic creditBalance; cash does NOT',
      () async {
    // m1 seeded creditBalance 0 — set it up with a balance + totals for the test.
    await (db.update(db.mechanics)..where((m) => m.id.equals('m1'))).write(
      const MechanicsCompanion(
        creditBalance: Value(500),
        totalSales: Value(1000),
        totalMarkup: Value(200),
      ),
    );

    // Mechanic credit sale: markup +50 (mechanicDelta>0), total 200.
    await insertSale(
      id: 's_credit',
      receiptNo: 'R6',
      subtotal: 200,
      total: 200,
      paymentMethod: 'เครดิตช่าง',
      mechanicId: 'm1',
      mechanicName: 'Lung Manop',
      mechanicDelta: 50,
      items: [(productId: 'p1', name: 'Oil Filter', qty: 1, price: 200)],
    );

    // Cash refund — does NOT reduce creditBalance.
    await repo.createReturn(const ReturnInput(
      saleId: 's_credit',
      items: [ReturnLineInput(productId: 'p1', name: 'Oil Filter', qty: 1, price: 200)],
      refundMethod: 'เงินสด',
    ));
    var mech =
        await (db.select(db.mechanics)..where((m) => m.id.equals('m1'))).getSingle();
    expect(mech.creditBalance, 500, reason: 'cash refund must NOT touch credit balance');
    // totalSales reduced by refundTotal (200) → 800.
    expect(mech.totalSales, 800);
    // ratio = 200/200 = 1; reverseMarkup = 50 → totalMarkup 200-50 = 150.
    expect(mech.totalMarkup, 150);

    // Now a credit-deduction refund on a second credit sale.
    await insertSale(
      id: 's_credit2',
      receiptNo: 'R7',
      subtotal: 300,
      total: 300,
      paymentMethod: 'เครดิตช่าง',
      mechanicId: 'm1',
      mechanicName: 'Lung Manop',
      mechanicDelta: 0,
      items: [(productId: 'p2', name: 'Spark Plug', qty: 1, price: 300)],
    );
    await repo.createReturn(const ReturnInput(
      saleId: 's_credit2',
      items: [ReturnLineInput(productId: 'p2', name: 'Spark Plug', qty: 1, price: 300)],
      refundMethod: 'หักจากเครดิต',
    ));
    mech =
        await (db.select(db.mechanics)..where((m) => m.id.equals('m1'))).getSingle();
    // creditBalance reduced by refundTotal (300): 500 - 300 = 200.
    expect(mech.creditBalance, 200);
  });

  test('getReturns returns newest first', () async {
    await insertSale(
      id: 's_order',
      receiptNo: 'R8',
      subtotal: 170,
      total: 170,
      items: [(productId: 'p1', name: 'Oil Filter', qty: 2, price: 85)],
    );
    final r1 = await repo.createReturn(const ReturnInput(
      saleId: 's_order',
      items: [ReturnLineInput(productId: 'p1', name: 'Oil Filter', qty: 1, price: 85)],
      refundMethod: 'เงินสด',
    ));
    // DateTime columns store unix SECONDS (Drift default) — sub-second ties have
    // undefined order. Cross a whole-second boundary so 'newest first' is
    // deterministic.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final r2 = await repo.createReturn(const ReturnInput(
      saleId: 's_order',
      items: [ReturnLineInput(productId: 'p1', name: 'Oil Filter', qty: 1, price: 85)],
      refundMethod: 'เงินสด',
    ));

    final all = await repo.getReturns();
    expect(all.length, 2);
    expect(all.first.ret.id, r2.id);
    expect(all.last.ret.id, r1.id);
  });
}
