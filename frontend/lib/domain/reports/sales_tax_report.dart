// sales_tax_report.dart — the monthly รายงานภาษีขาย the owner files ภ.พ.30
// from (owner approved 2026-10-23). Spec: docs/research/thai-vat-abbreviated-
// invoice-2026-10-23.md §3, §4, §7.4. A helper for filing, not a tax document.
//
// Rows (N89 ข้อ 7(2), 7(10)):
//  • one line per DAY for the bills (abbreviated-invoice style): first RC no.
//    – last RC no., value excluding VAT, VAT, total — no buyer, no items;
//  • one line per CREDIT NOTE, by the credit note's own date, amounts
//    negative — it is deducted in the month it was issued (P80 ข้อ 5).
//
// Voids follow the sales reports (`net_sales.dart` `countedSales`, the
// server's COUNTED_SALE): a MANUAL void (no credit note) is left out of its
// day's amounts and listed in the remark; an AUTO-void (a full return voids the
// bill) stays in its day's line and its credit note(s) subtract on their own
// lines — dropping the bill too would take the refund off twice.
//
// Money is integer satang. VAT is extracted from the VAT-inclusive total,
// `vat = total × rate / (100 + rate)`, rounded half away from zero to a
// satang ONCE PER LINE (per day / per credit note); value excl. VAT is
// `total − vat`, so value + VAT always equals the line total and the report's
// VAT is exactly the sum of its lines' VAT. §7.4 of the doc computes the same
// split per day and leaves "per day or per bill" to the accountant (O5) — per
// line is the agent's pick, [ยังไม่ยืนยัน].
//
// Pure: no Flutter, no repositories.

import '../../core/utils/dates.dart';
import '../../data/db/database.dart';

enum SalesTaxLineKind { daily, creditNote }

class SalesTaxLine {
  final SalesTaxLineKind kind;

  /// The day (local midnight) of a daily line; the credit note's date.
  final DateTime date;

  /// Daily: `RC…` or `RC…–RC…` over the counted bills ('' when the day had
  /// only manual voids). Credit note: its `cnNo`.
  final String docNo;

  /// Credit note: the bill it refers to (`Returns.receiptNo`).
  final String? refReceiptNo;

  /// Daily: counted bills in the line (manual voids excluded).
  final int billCount;

  /// Daily: receipt numbers of the day's manual voids, for the remark — they
  /// may sit inside the RC range and carry no amount.
  final List<String> voidedReceiptNos;

  final int baseSatang;
  final int vatSatang;
  final int totalSatang;

  const SalesTaxLine({
    required this.kind,
    required this.date,
    required this.docNo,
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

/// Baht (a Drift `REAL`, at most 2 decimals) as integer satang.
int toSatang(double baht) => (baht * 100).round();

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

SalesTaxLine _line({
  required SalesTaxLineKind kind,
  required DateTime date,
  required String docNo,
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
    refReceiptNo: refReceiptNo,
    billCount: billCount,
    voidedReceiptNos: voidedReceiptNos,
    baseSatang: totalSatang - vat,
    vatSatang: vat,
    totalSatang: totalSatang,
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
  final monthPrefix = dateKey(DateTime(year, month)).substring(0, 7);
  bool inMonth(DateTime d) => dateKey(d.toLocal()).startsWith(monthPrefix);

  final byDay = <String, List<SaleRow>>{};
  for (final s in sales.where((s) => inMonth(s.date))) {
    byDay.putIfAbsent(dateKey(s.date.toLocal()), () => []).add(s);
  }

  final lines = <SalesTaxLine>[];
  for (final entry in byDay.entries) {
    final day = DateTime.parse(entry.key);
    final counted = <SaleRow>[];
    final voided = <String>[];
    for (final s in entry.value) {
      if (!s.voided || returnedSaleIds.contains(s.id)) {
        counted.add(s);
      } else {
        voided.add(s.receiptNo);
      }
    }
    final nos = counted.map((s) => s.receiptNo).toList()..sort();
    voided.sort();
    lines.add(
      _line(
        kind: SalesTaxLineKind.daily,
        date: day,
        docNo: nos.isEmpty
            ? ''
            : nos.first == nos.last
            ? nos.first
            : '${nos.first}–${nos.last}',
        billCount: counted.length,
        voidedReceiptNos: voided,
        totalSatang: counted.fold(0, (a, s) => a + toSatang(s.total)),
        taxRate: taxRate,
      ),
    );
  }

  for (final r in returns.where((r) => inMonth(r.date))) {
    lines.add(
      _line(
        kind: SalesTaxLineKind.creditNote,
        date: r.date.toLocal(),
        docNo: r.cnNo,
        refReceiptNo: r.receiptNo,
        totalSatang: -toSatang(r.refundTotal),
        taxRate: taxRate,
      ),
    );
  }

  // Day order; on one day the bills' line first, then its credit notes.
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
