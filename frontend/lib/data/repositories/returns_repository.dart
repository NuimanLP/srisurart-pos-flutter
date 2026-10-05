// ReturnsRepository — returns / credit notes (sa_returns + sa_return_items).
//
// Transactional port of db.js createReturn (db.js lines 272-385). The JS used a
// localStorage snapshot/rollback; here a Drift `transaction(() async {...})`
// gives the same all-or-nothing semantics — any throw rolls everything back.
//
// createReturn(ReturnInput):
//  • Look up the sale; throw 'Sale not found' / 'Bill already voided'.
//  • Over-refund guard per line (qty ≤ sold − already refunded), else throw
//    'คืนเกินจำนวนที่ขาย:\n' + lines (per-line: '<name>: ไม่อยู่ในบิลนี้' or
//    '<name>: คืนได้อีก <remaining> แต่ขอคืน <qty>').
//  • refundSubtotal = Σ price*qty; discountRatio = subtotal>0 ? discount/subtotal : 0;
//    refundDiscount = round2(refundSubtotal*ratio); refundTotal = round2(refundSubtotal-refundDiscount).
//  • cnNo = docNo('CN'); id = newUuid(); date = now.
//  • Restore stock (+qty per line).
//  • Reverse customer spend/points proportionally; clamp both at 0.
//  • Reverse mechanic stats proportionally; reduce creditBalance ONLY when
//    refundMethod == 'หักจากเครดิต'.
//  • Auto-void parent sale when total refunded qty ≥ total sold qty.

import 'package:drift/drift.dart';

import '../../core/utils/ids.dart';
import '../../domain/models/aggregates.dart';
import '../db/database.dart';
import '../db/product_stamp.dart';
import 'return_plan.dart';

class ReturnsRepository {
  final AppDatabase db;
  ReturnsRepository(this.db);

  /// Transactional. Returns the persisted ReturnRow. Throws Thai errors on
  /// not-found / already-voided / over-refund.
  Future<ReturnRow> createReturn(ReturnInput input) {
    final saleId = input.saleId;
    return db.transaction(() async {
      // 1. Find the sale + its items.
      final sale = await (db.select(
        db.sales,
      )..where((s) => s.id.equals(saleId))).getSingleOrNull();
      if (sale == null) throw Exception('Sale not found');
      if (sale.voided) throw Exception('Bill already voided');

      final soldItems = await (db.select(
        db.saleItems,
      )..where((i) => i.saleId.equals(saleId))).get();
      final customer = sale.customerId == null
          ? null
          : await (db.select(
              db.customers,
            )..where((c) => c.id.equals(sale.customerId!))).getSingleOrNull();
      final mechanic = sale.mechanicId == null
          ? null
          : await (db.select(
              db.mechanics,
            )..where((m) => m.id.equals(sale.mechanicId!))).getSingleOrNull();

      // 2-3. Over-refund guard, refund amounts, ledger reversals, auto-void —
      // the pure rules shared with the API build's offline credit note.
      final plan = planReturn(
        sale: sale,
        soldItems: soldItems,
        refundedSoFar: await refundedQtyOf(db, saleId),
        input: input,
        customer: customer,
        mechanic: mechanic,
      );

      final cnNo = docNo('CN');
      final returnId = newUuid();
      final now = DateTime.now();

      final newReturn = ReturnRow(
        id: returnId,
        cnNo: cnNo,
        saleId: saleId,
        receiptNo: sale.receiptNo,
        refundSubtotal: plan.refundSubtotal,
        refundDiscount: plan.refundDiscount,
        refundTotal: plan.refundTotal,
        refundMethod: input.refundMethod,
        reason: input.reason ?? '',
        customerId: sale.customerId,
        mechanicId: sale.mechanicId,
        mechanicName: sale.mechanicName,
        date: now,
      );
      await db.into(db.returns).insert(newReturn);

      // Return item rows.
      for (final i in input.items) {
        await db
            .into(db.returnItems)
            .insert(
              ReturnItemsCompanion.insert(
                returnId: returnId,
                productId: i.productId,
                name: i.name,
                qty: i.qty,
                price: i.price,
                originalQty: Value(i.originalQty),
              ),
            );
      }

      // 4. Restore stock (+qty per line).
      for (final i in input.items) {
        final p = await (db.select(
          db.products,
        )..where((x) => x.id.equals(i.productId))).getSingleOrNull();
        if (p != null) {
          await (db.update(db.products)..where((x) => x.id.equals(p.id))).write(
            ProductsCompanion(stock: Value(p.stock + i.qty)).stamped,
          );
        }
      }

      // 5. Reverse customer spend & points.
      final c = plan.customerAfter;
      if (c != null) {
        await (db.update(
          db.customers,
        )..where((x) => x.id.equals(sale.customerId!))).write(
          CustomersCompanion(
            totalSpend: Value(c.totalSpend),
            points: Value(c.points),
            updatedAt: Value(DateTime.now()),
          ),
        );
      }

      // 6. Reverse mechanic stats.
      final m = plan.mechanicAfter;
      if (m != null) {
        await (db.update(
          db.mechanics,
        )..where((x) => x.id.equals(sale.mechanicId!))).write(
          MechanicsCompanion(
            totalSales: Value(m.totalSales),
            totalDiscount: Value(m.totalDiscount),
            totalMarkup: Value(m.totalMarkup),
            creditBalance: Value(m.creditBalance),
            updatedAt: Value(DateTime.now()),
          ),
        );
      }

      // 7. Mark sale as fully voided if all items returned (this return included).
      if (plan.voidsSale) {
        await (db.update(db.sales)..where((s) => s.id.equals(saleId))).write(
          SalesCompanion(voided: const Value(true), voidedAt: Value(now)),
        );
      }

      return newReturn;
    });
  }

  /// Returns, newest first (with their items). With no bounds: all returns.
  /// [from] is inclusive, [to] exclusive (#417).
  Future<List<ReturnWithItems>> getReturns({
    DateTime? from,
    DateTime? to,
  }) async {
    final query = db.select(db.returns)
      ..orderBy([(t) => OrderingTerm.desc(t.date)]);
    if (from != null) query.where((t) => t.date.isBiggerOrEqualValue(from));
    if (to != null) query.where((t) => t.date.isSmallerThanValue(to));
    final headers = await query.get();
    final result = <ReturnWithItems>[];
    for (final r in headers) {
      final items = await (db.select(
        db.returnItems,
      )..where((i) => i.returnId.equals(r.id))).get();
      result.add(ReturnWithItems(r, items));
    }
    return result;
  }
}
