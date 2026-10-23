// credit_statement.dart — the arithmetic of a mechanic's credit statement /
// ใบวางบิล with debt aging (pain-points survey 2026-10-23 §4.2, item 2).
//
// Pure functions only (no Flutter, no repositories): the screen reads the
// mechanic, the sales and the returns through repositories and passes them in.
//
// 🔴 The mechanic's stored `creditBalance` is the truth. Bills and payments do
// NOT add up to it by construction, so the balance is never recomputed here:
//   • it is clamped at 0 on a payment (`mechanics_repository.dart`
//     addCreditPayment), on a void (`sales_repository.dart` voidSaleOffline)
//     and on a return (`return_plan.dart`);
//   • a legacy import writes it directly (`snapshot_repository.dart`);
//   • `หักจากเครดิต` can be chosen on ANY bill with a mechanic, a cash bill too;
//   • a full return auto-voids the bill without taking credit off twice
//     (`returns_repository.dart`);
//   • on the API build `getSales`/`getReturns` read the local Drift copy only,
//     so a credit bill rung up on ANOTHER device is not in [sales] — its share
//     of the balance falls into the residual line, which is the right answer.
//
// Method: allocate the balance backwards from the newest credit bill
// (`paymentMethod == 'เครดิตช่าง'`), each bill counted net of its own
// `หักจากเครดิต` credit notes, until the balance is used up. What no bill
// explains is one residual line (`ยอดยกมา/ไม่มีบิลอ้างอิง`). Display only —
// nothing is written back.
//
// Skipped bills: a manual void (`voidReason != null`) and — one addition to
// §4.2 — a voided bill with NO credit note on it. Only a return auto-voids, so
// such a bill can only be a manual void; a legacy-imported void carries no
// `voidReason` (the JS app had none) and would otherwise be listed as debt.
// An auto-voided bill (voided, with credit notes) stays counted, net of its
// `หักจากเครดิต` notes — fully returned that way it nets to 0 and drops out.
//
// Money is done in integer satang, so for a balance > 0 the statement equals
// `creditBalance` to the satang: Σ lines + residual, residual = balance − Σ
// lines. A balance ≤ 0 has no lines and no residual (nothing owed); a negative
// one is shown as an overpayment (`overpaid`), never as negative debt.

import 'dart:math' as math;

import '../../data/db/database.dart';

/// The refund method that takes a credit note off the mechanic's balance.
const String deductFromCredit = 'หักจากเครดิต';

/// The payment method of a mechanic credit bill.
const String mechanicCreditMethod = 'เครดิตช่าง';

/// Aging buckets, by days since the bill date: 0–30, 31–60, 61–90, >90.
/// [label] is the printed heading (`agent ร่าง`).
enum AgingBucket {
  d0to30(30, '0–30 วัน'),
  d31to60(60, '31–60 วัน'),
  d61to90(90, '61–90 วัน'),
  over90(null, 'เกิน 90 วัน');

  const AgingBucket(this.maxDays, this.label);

  /// Last day in the bucket; null = no upper limit.
  final int? maxDays;
  final String label;
}

AgingBucket agingBucketOf(int ageDays) => AgingBucket.values.firstWhere(
  (b) => b.maxDays == null || ageDays <= b.maxDays!,
);

/// Whole calendar days from [from] to [to] (local dates, time ignored).
int calendarDaysBetween(DateTime from, DateTime to) {
  final a = DateTime.utc(from.year, from.month, from.day);
  final b = DateTime.utc(to.year, to.month, to.day);
  return b.difference(a).inDays;
}

class StatementLine {
  const StatementLine({
    required this.saleId,
    required this.receiptNo,
    required this.date,
    required this.outstanding,
    required this.ageDays,
  });

  final String saleId;
  final String receiptNo;
  final DateTime date;

  /// The part of the balance this bill explains (≤ the bill's net).
  final double outstanding;
  final int ageDays;

  AgingBucket get bucket => agingBucketOf(ageDays);
}

class CreditStatement {
  const CreditStatement({
    required this.lines,
    required this.residual,
    required this.total,
    required this.buckets,
  });

  /// Bills that explain the balance, newest first.
  final List<StatementLine> lines;

  /// The part of a positive balance no local bill explains — printed as
  /// `ยอดยกมา/ไม่มีบิลอ้างอิง` exactly when it is not 0. It has no age, so it
  /// is in no bucket. Never negative: a balance ≤ 0 has no residual.
  final double residual;

  /// Always the mechanic's `creditBalance` — negative too (a legacy import
  /// writes it directly; an outbox discard / sync reversal does not clamp).
  final double total;

  /// Outstanding per bucket over [lines] (every bucket present, 0 when empty).
  final Map<AgingBucket, double> buckets;

  bool get hasResidual => residual != 0;

  /// Nothing is owed: the statement prints `ไม่มียอดค้างชำระ`, no lines.
  bool get noDebt => total <= 0;

  /// A negative balance, as a positive amount the shop owes back (`ชำระเกิน`).
  double get overpaid => total < 0 ? -total : 0;
}

int _satang(double v) => (v * 100).round();
double _baht(int satang) => satang / 100;

/// Allocates [creditBalance] over [mechanicId]'s credit bills, newest first.
/// [sales] and [returns] may hold other mechanics' rows — they are filtered
/// here. [asOf] is the statement date the ages count to.
CreditStatement allocateCreditStatement({
  required String mechanicId,
  required double creditBalance,
  required List<SaleRow> sales,
  required List<ReturnRow> returns,
  required DateTime asOf,
}) {
  final returnsBySale = <String, List<ReturnRow>>{};
  for (final r in returns) {
    (returnsBySale[r.saleId] ??= []).add(r);
  }

  final bills =
      sales.where((s) {
        if (s.mechanicId != mechanicId) return false;
        if (s.paymentMethod != mechanicCreditMethod) return false;
        if (s.voidReason != null) return false; // manual void
        // Voided with no credit note = a manual void without a reason.
        if (s.voided && (returnsBySale[s.id] ?? const []).isEmpty) {
          return false;
        }
        return true;
      }).toList()..sort((a, b) {
        // Newest first. Drift keeps whole seconds, so a same-second tie falls
        // back to the id (creation order only for UUIDv7 ids, #616 — legacy
        // ids are arbitrary, but any fixed order will do), then receipt no.
        final byDate = b.date.compareTo(a.date);
        if (byDate != 0) return byDate;
        final byId = b.id.compareTo(a.id);
        return byId != 0 ? byId : b.receiptNo.compareTo(a.receiptNo);
      });

  final totalSatang = _satang(creditBalance);
  var remaining = totalSatang;
  final lines = <StatementLine>[];
  final bucketSatang = {for (final b in AgingBucket.values) b: 0};
  for (final s in bills) {
    if (remaining <= 0) break;
    final deducted = (returnsBySale[s.id] ?? const <ReturnRow>[])
        .where((r) => r.refundMethod == deductFromCredit)
        .fold<int>(0, (sum, r) => sum + _satang(r.refundTotal));
    final net = _satang(s.total) - deducted;
    if (net <= 0) continue;
    final take = net < remaining ? net : remaining;
    remaining -= take;
    // A bill dated after [asOf] (an offline till with a fast clock) is 0 days
    // old, never negative.
    final age = math.max(0, calendarDaysBetween(s.date, asOf));
    final line = StatementLine(
      saleId: s.id,
      receiptNo: s.receiptNo,
      date: s.date,
      outstanding: _baht(take),
      ageDays: age,
    );
    lines.add(line);
    bucketSatang[line.bucket] = bucketSatang[line.bucket]! + take;
  }

  return CreditStatement(
    lines: lines,
    residual: remaining > 0 ? _baht(remaining) : 0,
    total: _baht(totalSatang),
    buckets: {for (final e in bucketSatang.entries) e.key: _baht(e.value)},
  );
}
