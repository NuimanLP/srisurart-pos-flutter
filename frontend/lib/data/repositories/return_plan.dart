// planReturn — the arithmetic of a credit note, with no database access.
//
// Extracted from `ReturnsRepository.createReturn` (#452) so the Drift build and
// the API build's OFFLINE credit note (`ApiReturnsRepository`, queued as
// `return.create`) apply the same rules without the API repository ever calling
// the Drift transactional service (`api_repository_contract_test.dart`). Each
// caller reads the rows, calls this, and writes the result inside its own local
// transaction.
//
// Rules (db.js createReturn, lines 272-385):
//  • Over-refund guard per line (qty ≤ sold − already refunded), else throw
//    'คืนเกินจำนวนที่ขาย:\n' + lines.
//  • refundDiscount = round2(refundSubtotal × sale.discount/sale.subtotal).
//  • Customer spend/points reversed in proportion, both clamped at 0.
//  • Mechanic stats reversed in proportion; creditBalance reduced ONLY for
//    'หักจากเครดิต'.
//  • The parent bill is voided once every unit on it has come back.

import 'dart:math' as math;

import '../../core/utils/money.dart';
import '../../domain/models/aggregates.dart';
import '../db/database.dart';

class ReturnPlan {
  const ReturnPlan({
    required this.refundSubtotal,
    required this.refundDiscount,
    required this.refundTotal,
    required this.customerAfter,
    required this.mechanicAfter,
    required this.voidsSale,
  });

  final double refundSubtotal;
  final double refundDiscount;
  final double refundTotal;

  /// The customer's spend and points after the reversal — null when no
  /// customer row was given.
  final ({double totalSpend, int points})? customerAfter;

  /// The mechanic's four running totals after the reversal — null when no
  /// mechanic row was given.
  final ({
    double totalSales,
    double totalDiscount,
    double totalMarkup,
    double creditBalance,
  })?
  mechanicAfter;

  /// This credit note brings the last unit of the bill back.
  final bool voidsSale;
}

/// Throws `Exception('คืนเกินจำนวนที่ขาย:\n…')` when a line asks for more than is
/// left to refund. [refundedSoFar] is qty per productId across the bill's
/// earlier credit notes.
ReturnPlan planReturn({
  required SaleRow sale,
  required List<SaleItemRow> soldItems,
  required Map<String, int> refundedSoFar,
  required ReturnInput input,
  CustomerRow? customer,
  MechanicRow? mechanic,
}) {
  final overs = <String>[];
  for (final i in input.items) {
    final sold = soldItems
        .where((x) => x.productId == i.productId)
        .fold<int?>(null, (acc, x) => (acc ?? 0) + x.qty);
    final remaining = (sold ?? 0) - (refundedSoFar[i.productId] ?? 0);
    if (sold == null) {
      overs.add('${i.name}: ไม่อยู่ในบิลนี้');
    } else if (i.qty > remaining) {
      overs.add('${i.name}: คืนได้อีก $remaining แต่ขอคืน ${i.qty}');
    }
  }
  if (overs.isNotEmpty) {
    throw Exception('คืนเกินจำนวนที่ขาย:\n${overs.join('\n')}');
  }

  final refundSubtotal = input.items.fold<double>(
    0,
    (s, i) => s + i.price * i.qty,
  );
  final discountRatio = sale.subtotal > 0 ? sale.discount / sale.subtotal : 0.0;
  final refundDiscount = round2(refundSubtotal * discountRatio);
  final refundTotal = round2(refundSubtotal - refundDiscount);
  final ratio = sale.total > 0 ? refundTotal / sale.total : 0.0;

  ({double totalSpend, int points})? customerAfter;
  if (customer != null) {
    final basePoints = sale.pointsGranted > 0
        ? sale.pointsGranted
        : (sale.total / 10).floor();
    final pointsToReverse = (basePoints * ratio).floor();
    customerAfter = (
      totalSpend: math.max(0.0, customer.totalSpend - refundTotal),
      points: math.max(0, customer.points - pointsToReverse),
    );
  }

  ({
    double totalSales,
    double totalDiscount,
    double totalMarkup,
    double creditBalance,
  })?
  mechanicAfter;
  if (mechanic != null) {
    final origDelta = sale.mechanicDelta ?? 0;
    final reverseCredit = origDelta < 0 ? -origDelta * ratio : 0.0;
    final reverseMarkup = origDelta > 0 ? origDelta * ratio : 0.0;
    final reduceBalance = input.refundMethod == 'หักจากเครดิต'
        ? refundTotal
        : 0.0;
    // db.js used (totalDiscount || totalCredit) for the discount base.
    final discountBase = mechanic.totalDiscount != 0
        ? mechanic.totalDiscount
        : mechanic.totalCredit;
    mechanicAfter = (
      totalSales: math.max(0.0, mechanic.totalSales - refundTotal),
      totalDiscount: math.max(0.0, discountBase - reverseCredit),
      totalMarkup: math.max(0.0, mechanic.totalMarkup - reverseMarkup),
      creditBalance: math.max(0.0, mechanic.creditBalance - reduceBalance),
    );
  }

  final refundedBefore = refundedSoFar.values.fold<int>(0, (s, q) => s + q);
  final refundedNow = input.items.fold<int>(0, (s, i) => s + i.qty);
  final soldQty = soldItems.fold<int>(0, (s, i) => s + i.qty);

  return ReturnPlan(
    refundSubtotal: refundSubtotal,
    refundDiscount: refundDiscount,
    refundTotal: refundTotal,
    customerAfter: customerAfter,
    mechanicAfter: mechanicAfter,
    voidsSale: refundedBefore + refundedNow >= soldQty,
  );
}
