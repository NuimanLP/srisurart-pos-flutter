// Unit tests for SalesRepository (port of db.js saveSale invariants).

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';

void main() {
  late AppDatabase db;
  late SalesRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = SalesRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<ProductRow> product(String id) =>
      (db.select(db.products)..where((t) => t.id.equals(id))).getSingle();

  test(
    'insufficient stock throws Thai message and leaves data unchanged',
    () async {
      // p8 has stock 5 in seed data; request 6.
      final before = await product('p8');
      expect(before.stock, 5);

      final input = SaleInput(
        subtotal: 3200,
        discount: 0,
        total: 3200,
        paymentMethod: 'เงินสด',
        items: const [
          SaleLineInput(
            productId: 'p8',
            name: 'Piston Kit STD',
            qty: 6,
            price: 3200,
          ),
        ],
      );

      await expectLater(
        repo.saveSale(input),
        throwsA(
          predicate(
            (e) =>
                e.toString().contains('สต็อกไม่พอ:\n') &&
                e.toString().contains('Piston Kit STD: สต็อก 5 แต่ต้องการ 6'),
          ),
        ),
      );

      // Stock unchanged, no sale recorded (transaction never started — but assert anyway).
      final after = await product('p8');
      expect(after.stock, 5);
      final sales = await repo.getSales();
      expect(sales, isEmpty);
    },
  );

  test('missing product throws ไม่พบในสต็อก and records nothing', () async {
    final input = SaleInput(
      subtotal: 10,
      discount: 0,
      total: 10,
      paymentMethod: 'เงินสด',
      items: const [
        SaleLineInput(productId: 'NOPE', name: 'Ghost', qty: 1, price: 10),
      ],
    );
    await expectLater(
      repo.saveSale(input),
      throwsA(
        predicate(
          (e) =>
              e.toString().contains('สต็อกไม่พอ:\n') &&
              e.toString().contains('Ghost: ไม่พบในสต็อก'),
        ),
      ),
    );
    expect(await repo.getSales(), isEmpty);
  });

  test(
    'good sale decrements stock exactly and sets points/receiptNo',
    () async {
      final p1Before = await product('p1'); // stock 48
      expect(p1Before.stock, 48);

      final input = SaleInput(
        subtotal: 255,
        discount: 0,
        total: 255, // pointsFor(255) = 25
        paymentMethod: 'เงินสด',
        items: const [
          SaleLineInput(
            productId: 'p1',
            name: 'Oil Filter',
            qty: 3,
            price: 85,
            partNo: 'HN-15412-KVB',
          ),
        ],
      );

      final sale = await repo.saveSale(input);

      expect(sale.pointsGranted, 25); // floor(255/10)
      expect(sale.receiptNo.isNotEmpty, true);
      expect(sale.id.isNotEmpty, true);
      expect(sale.total, 255);

      final p1After = await product('p1');
      expect(p1After.stock, 45); // 48 - 3, strict

      final sales = await repo.getSales();
      expect(sales.length, 1);
      expect(sales.first.items.length, 1);
      expect(sales.first.items.first.qty, 3);
      expect(sales.first.items.first.partNo, 'HN-15412-KVB');
    },
  );

  test('customer sale increases points + totalSpend', () async {
    final cBefore = await (db.select(
      db.customers,
    )..where((t) => t.id.equals('c1'))).getSingle();
    expect(cBefore.points, 450);
    expect(cBefore.totalSpend, 4500);

    final input = SaleInput(
      subtotal: 120,
      discount: 0,
      total: 120, // pointsFor = 12
      paymentMethod: 'เงินสด',
      customerId: 'c1',
      customerName: 'Somchai Jaidee',
      items: const [
        SaleLineInput(
          productId: 'p2',
          name: 'Spark Plug NGK',
          qty: 1,
          price: 120,
        ),
      ],
    );
    final sale = await repo.saveSale(input);
    expect(sale.pointsGranted, 12);

    final cAfter = await (db.select(
      db.customers,
    )..where((t) => t.id.equals('c1'))).getSingle();
    expect(cAfter.points, 462); // 450 + 12
    expect(cAfter.totalSpend, 4620); // 4500 + 120
  });

  test('mechanic credit sale increases creditBalance by total', () async {
    final mBefore = await (db.select(
      db.mechanics,
    )..where((t) => t.id.equals('m1'))).getSingle();
    expect(mBefore.creditBalance, 0);
    expect(mBefore.totalSales, 0);

    final input = SaleInput(
      subtotal: 350,
      discount: 0,
      total: 350,
      paymentMethod: 'เครดิตช่าง',
      mechanicId: 'm1',
      mechanicName: 'Lung Manop',
      mechanicDelta: -50, // discount given
      items: const [
        SaleLineInput(
          productId: 'p3',
          name: 'Drive Chain #520',
          qty: 1,
          price: 350,
        ),
      ],
    );
    await repo.saveSale(input);

    final mAfter = await (db.select(
      db.mechanics,
    )..where((t) => t.id.equals('m1'))).getSingle();
    expect(mAfter.creditBalance, 350); // isCredit → += total
    expect(mAfter.totalSales, 350);
    expect(mAfter.totalDiscount, 50); // delta < 0 → += -delta
    expect(mAfter.totalMarkup, 0);
  });

  test(
    'mechanic non-credit sale with markup: no creditBalance, markup added',
    () async {
      final input = SaleInput(
        subtotal: 350,
        discount: 0,
        total: 350,
        paymentMethod: 'เงินสด',
        mechanicId: 'm2',
        mechanicName: 'Chang Tao',
        mechanicDelta: 30, // markup
        items: const [
          SaleLineInput(
            productId: 'p3',
            name: 'Drive Chain #520',
            qty: 1,
            price: 350,
          ),
        ],
      );
      await repo.saveSale(input);

      final m = await (db.select(
        db.mechanics,
      )..where((t) => t.id.equals('m2'))).getSingle();
      expect(m.creditBalance, 0); // not credit
      expect(m.totalMarkup, 30);
      expect(m.totalDiscount, 0);
      expect(m.totalSales, 350);
    },
  );

  test('getSales returns newest first', () async {
    Future<void> sell(String productId, double total) => repo.saveSale(
      SaleInput(
        subtotal: total,
        discount: 0,
        total: total,
        paymentMethod: 'เงินสด',
        items: [
          SaleLineInput(productId: productId, name: 'x', qty: 1, price: total),
        ],
      ),
    );
    await sell('p1', 85);
    // Drift stores DateTime as unix SECONDS by default, so two sales in the
    // same second tie on `date`. Cross a full second boundary to make the
    // date-desc ordering deterministic.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await sell('p2', 120);

    final sales = await repo.getSales();
    expect(sales.length, 2);
    expect(sales.first.sale.total, 120); // newest first
  });

  test('getRefundedQty sums ReturnItems across returns for a sale', () async {
    final sale = await repo.saveSale(
      SaleInput(
        subtotal: 170,
        discount: 0,
        total: 170,
        paymentMethod: 'เงินสด',
        items: const [
          SaleLineInput(productId: 'p1', name: 'Oil Filter', qty: 2, price: 85),
        ],
      ),
    );

    // No returns yet.
    expect(await repo.getRefundedQty(sale.id), isEmpty);

    // Manually insert a Return + ReturnItem referencing the sale.
    await db
        .into(db.returns)
        .insert(
          ReturnRow(
            id: 'r1',
            cnNo: 'CN1',
            saleId: sale.id,
            receiptNo: sale.receiptNo,
            refundSubtotal: 85,
            refundDiscount: 0,
            refundTotal: 85,
            refundMethod: 'เงินสด',
            reason: '',
            date: DateTime.now(),
          ),
        );
    await db
        .into(db.returnItems)
        .insert(
          ReturnItemsCompanion.insert(
            returnId: 'r1',
            productId: 'p1',
            name: 'Oil Filter',
            qty: 1,
            price: 85,
          ),
        );

    final refunded = await repo.getRefundedQty(sale.id);
    expect(refunded['p1'], 1);
  });
}
