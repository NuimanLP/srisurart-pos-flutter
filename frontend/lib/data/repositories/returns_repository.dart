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
//  • cnNo = docNo('CN'); id = newId('r'); date = now.
//  • Restore stock (+qty per line).
//  • Reverse customer spend/points proportionally; clamp both at 0.
//  • Reverse mechanic stats proportionally; reduce creditBalance ONLY when
//    refundMethod == 'หักจากเครดิต'.
//  • Auto-void parent sale when total refunded qty ≥ total sold qty.

import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../../core/utils/ids.dart';
import '../../core/utils/money.dart';
import '../../domain/models/aggregates.dart';
import '../db/database.dart';

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

      // 2. Over-refund guard — qty per line must not exceed (sold − already refunded).
      final refunded = await _refundedQty(saleId);
      final overs = <String>[];
      for (final i in input.items) {
        final sold = soldItems
            .where((x) => x.productId == i.productId)
            .fold<int?>(null, (acc, x) => (acc ?? 0) + x.qty);
        final remaining = (sold ?? 0) - (refunded[i.productId] ?? 0);
        if (sold == null) {
          overs.add('${i.name}: ไม่อยู่ในบิลนี้');
        } else if (i.qty > remaining) {
          overs.add('${i.name}: คืนได้อีก $remaining แต่ขอคืน ${i.qty}');
        }
      }
      if (overs.isNotEmpty) {
        throw Exception('คืนเกินจำนวนที่ขาย:\n${overs.join('\n')}');
      }

      // 3. Compute refund amounts (apply same discount ratio as the original sale).
      final refundSubtotal = input.items.fold<double>(
        0,
        (s, i) => s + i.price * i.qty,
      );
      final discountRatio = sale.subtotal > 0
          ? (sale.discount) / sale.subtotal
          : 0.0;
      final refundDiscount = round2(refundSubtotal * discountRatio);
      final refundTotal = round2(refundSubtotal - refundDiscount);

      final cnNo = docNo('CN');
      final returnId = newId('r');
      final now = DateTime.now();

      final newReturn = ReturnRow(
        id: returnId,
        cnNo: cnNo,
        saleId: saleId,
        receiptNo: sale.receiptNo,
        refundSubtotal: refundSubtotal,
        refundDiscount: refundDiscount,
        refundTotal: refundTotal,
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

      // 5. Reverse customer spend & points — points reversal proportional to the
      // refund ratio of THIS sale's originally-granted points.
      if (sale.customerId != null) {
        final cust = await (db.select(
          db.customers,
        )..where((c) => c.id.equals(sale.customerId!))).getSingleOrNull();
        if (cust != null) {
          final ratio = sale.total > 0 ? refundTotal / sale.total : 0.0;
          final basePoints = sale.pointsGranted > 0
              ? sale.pointsGranted
              : (sale.total / 10).floor();
          final pointsToReverse = (basePoints * ratio).floor();
          await (db.update(
            db.customers,
          )..where((c) => c.id.equals(sale.customerId!))).write(
            CustomersCompanion(
              totalSpend: Value(math.max(0.0, cust.totalSpend - refundTotal)),
              points: Value(math.max(0, cust.points - pointsToReverse)),
              updatedAt: Value(DateTime.now()),
            ),
          );
        }
      }

      // 6. Reverse mechanic stats — only if this sale was a mechanic sale.
      if (sale.mechanicId != null) {
        final mech = await (db.select(
          db.mechanics,
        )..where((m) => m.id.equals(sale.mechanicId!))).getSingleOrNull();
        if (mech != null) {
          final ratio = sale.total > 0 ? refundTotal / sale.total : 0.0;
          final origDelta = sale.mechanicDelta ?? 0;
          final reverseCredit = origDelta < 0 ? -origDelta * ratio : 0.0;
          final reverseMarkup = origDelta > 0 ? origDelta * ratio : 0.0;
          // Reduce mechanic's credit balance ONLY when explicitly refunding to credit.
          final reduceBalance = input.refundMethod == 'หักจากเครดิต'
              ? refundTotal
              : 0.0;
          // db.js used (totalDiscount || totalCredit) for the discount base.
          final discountBase = mech.totalDiscount != 0
              ? mech.totalDiscount
              : mech.totalCredit;
          await (db.update(
            db.mechanics,
          )..where((m) => m.id.equals(sale.mechanicId!))).write(
            MechanicsCompanion(
              totalSales: Value(math.max(0.0, mech.totalSales - refundTotal)),
              totalDiscount: Value(math.max(0.0, discountBase - reverseCredit)),
              totalMarkup: Value(
                math.max(0.0, mech.totalMarkup - reverseMarkup),
              ),
              creditBalance: Value(
                math.max(0.0, mech.creditBalance - reduceBalance),
              ),
              updatedAt: Value(DateTime.now()),
            ),
          );
        }
      }

      // 7. Mark sale as fully voided if all items returned (this new return included).
      final allReturns = await _refundedQty(saleId);
      final totalRefundedSoFar = allReturns.values.fold<int>(
        0,
        (s, q) => s + q,
      );
      final totalSoldQty = soldItems.fold<int>(0, (s, i) => s + i.qty);
      if (totalRefundedSoFar >= totalSoldQty) {
        await (db.update(db.sales)..where((s) => s.id.equals(saleId))).write(
          SalesCompanion(voided: const Value(true), voidedAt: Value(now)),
        );
      }

      return newReturn;
    });
  }

  /// All returns, newest first (with their items).
  Future<List<ReturnWithItems>> getReturns() async {
    final headers = await (db.select(
      db.returns,
    )..orderBy([(t) => OrderingTerm.desc(t.date)])).get();
    final result = <ReturnWithItems>[];
    for (final r in headers) {
      final items = await (db.select(
        db.returnItems,
      )..where((i) => i.returnId.equals(r.id))).get();
      result.add(ReturnWithItems(r, items));
    }
    return result;
  }

  /// How much of each item has already been returned for a given sale.
  /// Mirrors db.js getRefundedQty: sums ReturnItems.qty per productId across all
  /// returns whose saleId matches.
  Future<Map<String, int>> _refundedQty(String saleId) async {
    final query = db.select(db.returnItems).join([
      innerJoin(db.returns, db.returns.id.equalsExp(db.returnItems.returnId)),
    ])..where(db.returns.saleId.equals(saleId));
    final rows = await query.get();
    final result = <String, int>{};
    for (final row in rows) {
      final item = row.readTable(db.returnItems);
      result[item.productId] = (result[item.productId] ?? 0) + item.qty;
    }
    return result;
  }
}
