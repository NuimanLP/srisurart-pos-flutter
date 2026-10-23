// รายงานภาษีขาย (owner approved 2026-10-23) — the pure rules in
// domain/reports/sales_tax_report.dart, the CSV rows the export writes, and the
// tax-id / branch validation of Settings → ทั่วไป.

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:srisurart_pos/core/utils/csv_safe.dart';
import 'package:srisurart_pos/core/utils/tax_identity.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/domain/reports/sales_tax_report.dart';
import 'package:srisurart_pos/presentation/widgets/sales_tax_report_section.dart';

SaleRow sale(
  String id,
  String receiptNo,
  double total,
  DateTime date, {
  bool voided = false,
}) => SaleRow(
  id: id,
  receiptNo: receiptNo,
  subtotal: total,
  discount: 0,
  total: total,
  paymentMethod: 'เงินสด',
  pointsGranted: 0,
  date: date,
  voided: voided,
  soldOffline: false,
);

ReturnRow ret(
  String cnNo,
  String saleId,
  String receiptNo,
  double refund,
  DateTime date,
) => ReturnRow(
  id: 'r-$cnNo',
  cnNo: cnNo,
  saleId: saleId,
  receiptNo: receiptNo,
  refundSubtotal: refund,
  refundDiscount: 0,
  refundTotal: refund,
  refundMethod: 'เงินสด',
  reason: 'ชำรุด',
  date: date,
);

SalesTaxReport build(
  List<SaleRow> sales, {
  List<ReturnRow> returns = const [],
  Set<String> returned = const {},
  double rate = 7,
  int year = 2026,
  int month = 10,
}) => buildSalesTaxReport(
  year: year,
  month: month,
  taxRate: rate,
  sales: sales,
  returns: returns,
  returnedSaleIds: returned,
);

void main() {
  setUpAll(() => initializeDateFormatting('th'));

  group('vatFromInclusiveSatang', () {
    test('extracts total × rate/(100+rate), half away from zero', () {
      expect(vatFromInclusiveSatang(10700, 7), 700);
      expect(vatFromInclusiveSatang(100, 7), 7); // 6.54 → 7
      expect(vatFromInclusiveSatang(1, 7), 0); // 0.065 → 0
      expect(vatFromInclusiveSatang(-10700, 7), -700);
      expect(vatFromInclusiveSatang(-100, 7), -7); // a CN mirrors the sale
      expect(vatFromInclusiveSatang(11000, 10), 1000);
      expect(vatFromInclusiveSatang(5000, 0), 0);
    });

    test('a negative or non-finite rate is refused, not clamped', () {
      expect(() => vatFromInclusiveSatang(100, -7), throwsArgumentError);
      expect(() => vatFromInclusiveSatang(100, double.nan), throwsArgumentError);
      expect(() => build(const [], rate: -1), throwsArgumentError);
    });
  });

  test('one line per day, RC range over that day, days in order', () {
    final r = build([
      sale('a', 'RC01-2569-10-0003', 300, DateTime(2026, 10, 5, 16)),
      sale('b', 'RC01-2569-10-0001', 100, DateTime(2026, 10, 5, 9)),
      sale('c', 'RC01-2569-10-0002', 200, DateTime(2026, 10, 5, 12)),
      sale('d', 'RC01-2569-10-0004', 107, DateTime(2026, 10, 6, 10)),
    ]);
    expect(r.lines, hasLength(2));
    final d5 = r.lines[0];
    expect(d5.kind, SalesTaxLineKind.daily);
    expect(d5.date, DateTime(2026, 10, 5));
    expect(d5.docNo, 'RC01-2569-10-0001–RC01-2569-10-0003');
    expect(d5.billCount, 3);
    expect(d5.totalSatang, 60000);
    expect(r.lines[1].docNo, 'RC01-2569-10-0004'); // a single bill: no range
    expect(r.lines[1].vatSatang, 700);
    expect(r.lines[1].baseSatang, 10000);
  });

  test('VAT is rounded once per day line; the report VAT is the sum', () {
    // Three ฿1.00 bills: per bill 0.0654 → 7 satang each = 21; per day
    // 300 × 7/107 = 19.63 → 20. The per-day-line rule is the agent's pick
    // ([ยังไม่ยืนยัน], doc §7.4 / O5).
    final r = build([
      sale('a', 'RC-1', 1, DateTime(2026, 10, 1, 9)),
      sale('b', 'RC-2', 1, DateTime(2026, 10, 1, 10)),
      sale('c', 'RC-3', 1, DateTime(2026, 10, 1, 11)),
      sale('d', 'RC-4', 1234.56, DateTime(2026, 10, 2, 11)),
    ], returns: [
      ret('CN-1', 'd', 'RC-4', 99.99, DateTime(2026, 10, 3)),
    ]);
    expect(r.lines.first.vatSatang, 20);
    for (final l in r.lines) {
      expect(l.baseSatang + l.vatSatang, l.totalSatang);
    }
    expect(r.vatSatang, r.lines.fold<int>(0, (a, l) => a + l.vatSatang));
    expect(r.baseSatang + r.vatSatang, r.totalSatang);
    expect(r.totalSatang, 300 + 123456 - 9999);
  });

  test('a credit note is its own negative line, after its day\'s bills', () {
    final r = build([
      sale('a', 'RC-1', 214, DateTime(2026, 10, 7, 9)),
    ], returns: [
      ret('CN01-2569-10-0001', 'a', 'RC-1', 107, DateTime(2026, 10, 7, 15)),
    ]);
    expect(r.lines.map((l) => l.kind), [
      SalesTaxLineKind.daily,
      SalesTaxLineKind.creditNote,
    ]);
    final cn = r.lines[1];
    expect(cn.docNo, 'CN01-2569-10-0001');
    expect(cn.refReceiptNo, 'RC-1');
    expect(cn.totalSatang, -10700);
    expect(cn.vatSatang, -700);
    expect(cn.baseSatang, -10000);
    expect(r.vatSatang, 700); // 1400 − 700
  });

  test('month boundary is the local calendar month', () {
    final r = build([
      sale('sep', 'RC-0', 100, DateTime(2026, 9, 30, 23, 59, 59)),
      sale('in', 'RC-1', 100, DateTime(2026, 10, 31, 23, 59, 59)),
      sale('nov', 'RC-2', 100, DateTime(2026, 11, 1)),
    ], returns: [
      ret('CN-nov', 'in', 'RC-1', 100, DateTime(2026, 11, 1, 0, 0, 1)),
      ret('CN-oct', 'in', 'RC-1', 50, DateTime(2026, 10, 1)),
    ]);
    expect(r.lines.map((l) => l.docNo), ['CN-oct', 'RC-1']);
  });

  test('a manual void is left out of the amounts and named in the remark', () {
    final r = build([
      sale('a', 'RC-1', 100, DateTime(2026, 10, 9, 9)),
      sale('b', 'RC-2', 500, DateTime(2026, 10, 9, 10), voided: true),
      sale('c', 'RC-3', 100, DateTime(2026, 10, 9, 11)),
      // A day whose only bill was voided still gets a ฿0 line naming it.
      sale('d', 'RC-4', 900, DateTime(2026, 10, 10, 9), voided: true),
    ]);
    final d9 = r.lines[0];
    expect(d9.totalSatang, 20000);
    expect(d9.billCount, 2);
    expect(d9.docNo, 'RC-1–RC-3');
    expect(d9.voidedReceiptNos, ['RC-2']);
    final d10 = r.lines[1];
    expect(d10.docNo, '');
    expect(d10.totalSatang, 0);
    expect(d10.voidedReceiptNos, ['RC-4']);
    expect(r.totalSatang, 20000);
  });

  test('a full return\'s auto-void keeps the bill and shows its CN line', () {
    // Same month: the bill counts on its day, the CN takes it all back.
    final same = build(
      [sale('a', 'RC-1', 535, DateTime(2026, 10, 12, 9), voided: true)],
      returns: [ret('CN-1', 'a', 'RC-1', 535, DateTime(2026, 10, 14))],
      returned: {'a'},
    );
    expect(same.lines.map((l) => (l.kind, l.totalSatang)), [
      (SalesTaxLineKind.daily, 53500),
      (SalesTaxLineKind.creditNote, -53500),
    ]);
    expect(same.totalSatang, 0);
    expect(same.vatSatang, 0);
    expect(same.lines.first.voidedReceiptNos, isEmpty);

    // Bill in October, full return in November: October still owes the VAT
    // (the CN is deducted in the month it is issued — P80 ข้อ 5), so the
    // auto-void must not vanish from October.
    final sale0 = sale('b', 'RC-9', 107, DateTime(2026, 10, 31, 18), voided: true);
    final cn = ret('CN-9', 'b', 'RC-9', 107, DateTime(2026, 11, 2));
    final oct = build([sale0], returns: [cn], returned: {'b'});
    expect(oct.lines.single.totalSatang, 10700);
    expect(oct.vatSatang, 700);
    final nov = build([sale0], returns: [cn], returned: {'b'}, month: 11);
    expect(nov.lines.single.kind, SalesTaxLineKind.creditNote);
    expect(nov.vatSatang, -700);
  });

  test('the rate comes from the caller (settings)', () {
    final r = build([sale('a', 'RC-1', 110, DateTime(2026, 10, 1))], rate: 10);
    expect(r.taxRate, 10);
    expect(r.lines.single.vatSatang, 1000);
    expect(r.lines.single.baseSatang, 10000);
  });

  group('CSV rows', () {
    SettingsRowData settings({String? taxId, String? branchNo}) =>
        SettingsRowData(
          id: 0,
          shopName: 'ร้านทดสอบ',
          shopNameEN: 'Test',
          taxRate: 7,
          quoteValidDays: 30,
          taxId: taxId,
          branchNo: branchNo,
        );

    test('header, one row per line with brackets for negatives, ภ.พ.30 footer', () {
      final r = build([
        sale('a', 'RC-1', 214, DateTime(2026, 10, 7, 9)),
        sale('v', '=HYPERLINK("x")', 50, DateTime(2026, 10, 7, 10), voided: true),
      ], returns: [
        ret('CN-1', 'a', 'RC-1', 107, DateTime(2026, 10, 8)),
      ]);
      final rows = salesTaxCsvRows(
        r,
        settings(taxId: '0123456789012', branchNo: '00000'),
      );
      expect(rows[1], ['เดือนภาษี', 'ตุลาคม 2569']);
      expect(rows[2], ['ชื่อผู้ประกอบการ', 'ร้านทดสอบ']);
      expect(rows[3], ['เลขประจำตัวผู้เสียภาษี', '0-1234-56789-01-2']);
      expect(rows[4], ['สถานประกอบการ', 'สำนักงานใหญ่']);
      expect(rows[6], ['หมายเหตุ', salesTaxDisclaimer]);
      final header = rows.indexWhere((row) => row.isNotEmpty && row.first == 'ลำดับ');
      expect(rows[header + 1], [
        1, '07/10/2569', 'RC-1', '', '', '', '', '200.00', '14.00', '214.00',
        'รวม 1 บิล · ยกเลิก (ไม่นับ): =HYPERLINK("x")',
      ]);
      expect(rows[header + 2], [
        2, '08/10/2569', 'CN-1', 'RC-1', '', '', '', '(100.00)', '(7.00)',
        '(107.00)', 'ใบลดหนี้',
      ]);
      expect(rows.sublist(rows.length - 4), [
        [salesTaxBaseLabel, '100.00'],
        [salesTaxTaxableLabel, '100.00'],
        [salesTaxVatLabel, '7.00'],
        ['ยอดขายรวม VAT สุทธิ', '107.00'],
      ]);
      // Money cells survive csvSafe untouched (no leading '-' to escape).
      for (final row in rows) {
        for (final cell in row) {
          final s = '$cell';
          if (RegExp(r'^\(?\d+\.\d\d\)?$').hasMatch(s)) {
            expect(csvSafe(cell), s);
          }
        }
      }
      // A remark starting with '=' would be escaped by the export's csvSafe.
      expect(csvSafe('=HYPERLINK("x")'), "'=HYPERLINK(\"x\")");
    });

    test('missing tax id / branch print a dash', () {
      final rows = salesTaxCsvRows(build(const []), settings());
      expect(rows[3], ['เลขประจำตัวผู้เสียภาษี', '-']);
      expect(rows[4], ['สถานประกอบการ', '-']);
    });

    test('csvMoney', () {
      expect(csvMoney(0), '0.00');
      expect(csvMoney(5), '0.05');
      expect(csvMoney(123456), '1234.56');
      expect(csvMoney(-700), '(7.00)');
    });
  });

  group('tax identity', () {
    test('tax id: 13 digits, spaces/dashes as separators, empty clears', () {
      expect(parseTaxId('0123456789012'), (value: '0123456789012', error: null));
      expect(parseTaxId(' 0-1234-56789-01-2 '),
          (value: '0123456789012', error: null));
      expect(parseTaxId('0 1234 56789 01 2').value, '0123456789012');
      expect(parseTaxId(''), (value: null, error: null));
      expect(parseTaxId('   '), (value: null, error: null));
      for (final bad in ['012345678901', '01234567890123', '012345678901x', '๐๑๒๓๔๕๖๗๘๙๐๑๒']) {
        expect(parseTaxId(bad), (value: null, error: taxIdInvalidMessage), reason: bad);
      }
    });

    test('branch: exactly 5 digits, empty clears', () {
      expect(parseBranchNo('00000'), (value: '00000', error: null));
      expect(parseBranchNo(' 00001 '), (value: '00001', error: null));
      expect(parseBranchNo(''), (value: null, error: null));
      for (final bad in ['0', '0000', '000000', 'สาขา1', '0000a']) {
        expect(parseBranchNo(bad), (value: null, error: branchNoInvalidMessage), reason: bad);
      }
    });

    test('display helpers', () {
      expect(formatTaxId('0123456789012'), '0-1234-56789-01-2');
      expect(formatTaxId('legacy'), 'legacy');
      expect(branchLabel('00000'), 'สำนักงานใหญ่');
      expect(branchLabel('00002'), 'สาขาที่ 00002');
      expect(branchLabel(null), '');
    });
  });
}
