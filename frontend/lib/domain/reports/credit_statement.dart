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
// Money is done in integer satang, so the total equals `creditBalance` to the
// satang: total = Σ lines + residual, with residual = balance − Σ lines.

import '../../data/db/database.dart';

/// The refund method that takes a credit note off the mechanic's balance.
const String deductFromCredit = 'หักจากเครดิต';

/// The payment method of a mechanic credit bill.
const String mechanicCreditMethod = 'เครดิตช่าง';

/// Aging buckets, by days since the bill date: 0–30, 31–60, 61–90, >90.
enum AgingBucket { d0to30, d31to60, d61to90, over90 }

AgingBucket agingBucketOf(int ageDays) {
  if (ageDays <= 30) return AgingBucket.d0to30;
  if (ageDays <= 60) return AgingBucket.d31to60;
  if (ageDays <= 90) return AgingBucket.d61to90;
  return AgingBucket.over90;
}

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

  /// The part of the balance no local bill explains — printed as
  /// `ยอดยกมา/ไม่มีบิลอ้างอิง` exactly when it is not 0. It has no age, so it
  /// is in no bucket.
  final double residual;

  /// Always the mechanic's `creditBalance`.
  final double total;

  /// Outstanding per bucket over [lines] (every bucket present, 0 when empty).
  final Map<AgingBucket, double> buckets;

  bool get hasResidual => residual != 0;
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
        // back to the id (UUIDv7 = creation order, #616), then the receipt no.
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
    final age = calendarDaysBetween(s.date, asOf);
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
    residual: _baht(remaining),
    total: _baht(totalSatang),
    buckets: {for (final e in bucketSatang.entries) e.key: _baht(e.value)},
  );
}
