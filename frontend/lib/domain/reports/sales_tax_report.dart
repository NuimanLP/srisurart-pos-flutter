// sales_tax_report.dart — the monthly รายงานภาษีขาย the owner files ภ.พ.30
// from (owner approved 2026-10-23). Spec: docs/research/thai-vat-abbreviated-
// invoice-2026-10-23.md §3, §4, §7.4. A helper for filing, not a tax document.
//
// Rows (N89 ข้อ 7(2), 7(10)):
//  • one line per DAY per RC series for the bills (abbreviated-invoice style):
//    value excluding VAT, VAT, total — no buyer, no items. A series is the
//    `RCnn` prefix of the sequential `RCnn-YYYY-MM-nnnn` numbers (one per POS
//    machine), so two machines never merge into one range; numbers in any
//    other form (the Drift build's `docNo('RC')` — epoch-ms digits + random
//    hex, not consecutive, wrapping every ~27.8 h) form one series of their
//    own. Only a sequential series prints "first–last" by number; any other
//    shows the first and last bill BY TIME and is flagged
//    [SalesTaxLine.sequential] = false (no range is claimed);
//  • one line per CREDIT NOTE, by the credit note's own date, amounts
//    negative — it is deducted in the month it was issued (P80 ข้อ 5).
//
// Voids follow the sales reports (`net_sales.dart`, the server's
// COUNTED_SALE) read AS OF the month's end (`toReportLites(asOf:)`): a MANUAL
// void made inside the month is left out of its day's amounts and named in the
// remark; a bill voided only after the month ended still counts there, so a
// filed month reads the same whenever it is re-run (a cross-month void does
// not show anywhere else — open question for the accountant). An AUTO-void (a
// full return) stays in its day's line and its credit note(s) subtract on
// their own lines — dropping the bill too would take the refund off twice.
//
// Money is integer satang. VAT is extracted from the VAT-inclusive total,
// `vat = total × rate / (100 + rate)`, rounded half away from zero to a
// satang ONCE PER LINE (per day / per credit note); value excl. VAT is
// `total − vat`, so value + VAT always equals the line total and the report's
// VAT is exactly the sum of its lines' VAT. §7.4 of the doc computes the same
// split per day and leaves "per day or per bill" to the accountant (O5) — per
// line is the agent's pick, [ยังไม่ยืนยัน]. The rate is the caller's (today's
// setting) for every month — no rate history is stored.
//
// Pure: no Flutter, no repositories.

import '../../core/utils/dates.dart';
import '../../core/utils/money.dart';
import '../../data/db/database.dart';

enum SalesTaxLineKind { daily, creditNote }

class SalesTaxLine {
  final SalesTaxLineKind kind;

  /// The day (local midnight) of a daily line; the credit note's date.
  final DateTime date;

  /// Daily, sequential series: `RCnn-…-0001` or `RCnn-…-0001–RCnn-…-0042`.
  /// Daily, other numbers: the first bill by time, or `first / last` by time.
  /// '' when the series had only manual voids that day. Credit note: `cnNo`.
  final String docNo;

  /// Daily: whether [docNo] is a real number range (sequential `RCnn-YYYY-MM-
  /// nnnn` numbers). False = first/last by time only, numbers not consecutive.
  final bool sequential;

  /// Credit note: the bill it refers to (`Returns.receiptNo`).
  final String? refReceiptNo;

  /// Daily: counted bills in the line (manual voids excluded).
  final int billCount;

  /// Daily: receipt numbers of the day's manual voids in this series, for the
  /// remark — they may sit inside the range and carry no amount.
  final List<String> voidedReceiptNos;

  final int baseSatang;
  final int vatSatang;
  final int totalSatang;

  const SalesTaxLine({
    required this.kind,
    required this.date,
    required this.docNo,
    this.sequential = true,
    this.refReceiptNo,
    this.billCount = 0,
    this.voidedReceiptNos = const [],
    required this.baseSatang,
    required this.vatSatang,
    required this.totalSatang,
  });
}

class SalesTaxReport {
  final int year;
  final int month;
  final double taxRate;
  final List<SalesTaxLine> lines;

  const SalesTaxReport({
    required this.year,
    required this.month,
    required this.taxRate,
    required this.lines,
  });

  /// Σ value excluding VAT — ภ.พ.30 ช่อง 1 / ช่อง 4 (see the doc §4).
  int get baseSatang => lines.fold(0, (a, l) => a + l.baseSatang);

  /// Σ VAT — ภ.พ.30 ช่อง 5 ภาษีขาย.
  int get vatSatang => lines.fold(0, (a, l) => a + l.vatSatang);

  /// Σ VAT-inclusive totals (net of credit notes).
  int get totalSatang => lines.fold(0, (a, l) => a + l.totalSatang);
}

/// The VAT inside a VAT-inclusive [totalSatang] at [taxRate] percent, in
/// satang, rounded half away from zero (so a credit note of the same amount
/// is exactly the negative). The rate is taken to 1/100 of a percent.
int vatFromInclusiveSatang(int totalSatang, double taxRate) {
  if (!taxRate.isFinite || taxRate < 0) {
    throw ArgumentError.value(taxRate, 'taxRate', 'must be ≥ 0');
  }
  final r = (taxRate * 100).round(); // 7 % → 700
  if (r == 0 || totalSatang == 0) return 0;
  final den = 10000 + r;
  final abs = totalSatang.abs();
  final vat = (2 * abs * r + den) ~/ (2 * den);
  return totalSatang < 0 ? -vat : vat;
}

/// `RCnn-YYYY-MM-nnnn` — the device-numbered form (`DocNumberService`, #190).
final _sequentialRc = RegExp(r'^(RC\d+)-\d{4}-\d{2}-(\d+)$');

SalesTaxLine _line({
  required SalesTaxLineKind kind,
  required DateTime date,
  required String docNo,
  bool sequential = true,
  String? refReceiptNo,
  int billCount = 0,
  List<String> voidedReceiptNos = const [],
  required int totalSatang,
  required double taxRate,
}) {
  final vat = vatFromInclusiveSatang(totalSatang, taxRate);
  return SalesTaxLine(
    kind: kind,
    date: date,
    docNo: docNo,
    sequential: sequential,
    refReceiptNo: refReceiptNo,
    billCount: billCount,
    voidedReceiptNos: voidedReceiptNos,
    baseSatang: totalSatang - vat,
    vatSatang: vat,
    totalSatang: totalSatang,
  );
}

int _byTime(SaleRow a, SaleRow b) {
  final t = a.date.compareTo(b.date);
  return t != 0 ? t : a.receiptNo.compareTo(b.receiptNo);
}

/// The daily line of one RC series on one day.
SalesTaxLine _dailyLine(
  DateTime day,
  String? series,
  List<SaleRow> bills,
  bool Function(SaleRow) counts,
  double taxRate,
) {
  final counted = bills.where(counts).toList()..sort(_byTime);
  final voided = bills.where((s) => !counts(s)).toList()..sort(_byTime);
  final sequential = series != null;
  String docNo;
  if (counted.isEmpty) {
    docNo = '';
  } else if (sequential) {
    int n(SaleRow s) =>
        int.parse(_sequentialRc.firstMatch(s.receiptNo)!.group(2)!);
    final byNo = [...counted]..sort((a, b) => n(a).compareTo(n(b)));
    final first = byNo.first.receiptNo;
    final last = byNo.last.receiptNo;
    docNo = first == last ? first : '$first–$last';
  } else {
    final first = counted.first.receiptNo;
    final last = counted.last.receiptNo;
    docNo = first == last ? first : '$first / $last';
  }
  return _line(
    kind: SalesTaxLineKind.daily,
    date: day,
    docNo: docNo,
    sequential: sequential || counted.length < 2,
    billCount: counted.length,
    voidedReceiptNos: [for (final s in voided) s.receiptNo],
    totalSatang: counted.fold(0, (a, s) => a + toSatang(s.total)),
    taxRate: taxRate,
  );
}

/// The report for [year]-[month] (local calendar month).
///
/// [sales] / [returns]: the bills and credit notes to consider; rows dated
/// outside the month (local time) are ignored, so the caller may pass a wider
/// range. [returnedSaleIds]: every bill that has a credit note at ANY time —
/// how a voided bill is told apart as an auto-void (its return may be dated
/// after the month).
SalesTaxReport buildSalesTaxReport({
  required int year,
  required int month,
  required double taxRate,
  required List<SaleRow> sales,
  required List<ReturnRow> returns,
  required Set<String> returnedSaleIds,
}) {
  // Validates the rate before any line is built.
  vatFromInclusiveSatang(0, taxRate);
  final key = monthKey(DateTime(year, month));
  final monthEnd = DateTime(year, month + 1);
  bool inMonth(DateTime d) => monthKey(d.toLocal()) == key;

  // As of the month's end: a void made after it had not happened yet
  // (`net_sales.dart` `toReportLites(asOf:)`). A legacy void with no
  // `voidedAt` reads as made inside the month.
  bool counts(SaleRow s) =>
      !s.voided ||
      returnedSaleIds.contains(s.id) ||
      (s.voidedAt != null && !s.voidedAt!.isBefore(monthEnd));

  // day → series (RCnn, or null for any other numbering) → bills.
  final byDay = <String, Map<String?, List<SaleRow>>>{};
  for (final s in sales.where((s) => inMonth(s.date))) {
    final series = _sequentialRc.firstMatch(s.receiptNo)?.group(1);
    byDay
        .putIfAbsent(dateKey(s.date.toLocal()), () => {})
        .putIfAbsent(series, () => [])
        .add(s);
  }

  final lines = <SalesTaxLine>[
    for (final day in byDay.entries)
      for (final series in day.value.entries)
        _dailyLine(
          DateTime.parse(day.key),
          series.key,
          series.value,
          counts,
          taxRate,
        ),
    for (final r in returns.where((r) => inMonth(r.date)))
      _line(
        kind: SalesTaxLineKind.creditNote,
        date: r.date.toLocal(),
        docNo: r.cnNo,
        refReceiptNo: r.receiptNo,
        totalSatang: -toSatang(r.refundTotal),
        taxRate: taxRate,
      ),
  ];

  // Day order; on one day the bills' lines first, then its credit notes.
  lines.sort((a, b) {
    final d = dateKey(a.date).compareTo(dateKey(b.date));
    if (d != 0) return d;
    final k = a.kind.index.compareTo(b.kind.index);
    if (k != 0) return k;
    return a.docNo.compareTo(b.docNo);
  });

  return SalesTaxReport(
    year: year,
    month: month,
    taxRate: taxRate,
    lines: lines,
  );
}
