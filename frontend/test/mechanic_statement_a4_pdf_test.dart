// Mechanic credit statement / ใบวางบิล A4 PDF (survey 2026-10-23 §4.2): the
// page text is read back from the real PDF (not a mocked widget tree) — the
// total is creditBalance, the residual line is printed exactly when ≠ 0.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:pdf/pdf.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/domain/reports/credit_statement.dart';
import 'package:srisurart_pos/presentation/widgets/mechanic_statement_a4.dart';

const _settings = SettingsRowData(
  id: 1,
  shopName: 'ร้านศรีสุราษฎร์เจริญยนต์',
  shopNameEN: 'Srisurart Autopart',
  taxRate: 0.07,
  quoteValidDays: 7,
  address: '99 ถ.ตลาดใหม่ อ.เมือง จ.สุราษฎร์ธานี',
  phone: '077000888',
);

MechanicRow _mechanic({
  String name = 'Lung Manop',
  String? nameTH = 'ลุงมานพ',
}) => MechanicRow(
  id: 'm1',
  code: 'M001',
  name: name,
  nameTH: nameTH,
  shopName: 'อู่ลุงมานพ',
  creditLimit: 5000,
  creditBalance: 0,
  totalSales: 0,
  totalCredit: 0,
  totalDiscount: 0,
  totalMarkup: 0,
  createdAt: '2024-02-10',
);

final _asOf = DateTime(2026, 10, 23, 10);

SaleRow _bill(String no, double total, DateTime date) => SaleRow(
  id: 'id-$no',
  receiptNo: no,
  subtotal: total,
  discount: 0,
  total: total,
  paymentMethod: 'เครดิตช่าง',
  mechanicId: 'm1',
  pointsGranted: 0,
  date: date,
  voided: false,
  soldOffline: false,
);

MechanicStatementA4View _view(double balance) => MechanicStatementA4View(
  mechanic: _mechanic(),
  settings: _settings,
  asOf: _asOf,
  statement: allocateCreditStatement(
    mechanicId: 'm1',
    creditBalance: balance,
    sales: [
      _bill('RC01-2569-10-0042', 1234.5, DateTime(2026, 10, 20)), // 3 days
      _bill('RC01-2569-07-0007', 800, DateTime(2026, 7, 1)), // 114 days
    ],
    returns: const [],
    asOf: _asOf,
  ),
);

/// The text actually drawn on the page — same decoder as
/// `purchase_order_a4_pdf_test.dart`: glyph codes (Identity-H) decoded
/// through each font's ToUnicode `bfchar` map. Needs an uncompressed document.
/// Runs are joined by a space.
String _pdfText(List<int> bytes) {
  final raw = String.fromCharCodes(bytes);
  final cmaps = <String, Map<int, int>>{};
  for (final m in RegExp(
    r'(\d+) 0 obj(?:(?!endobj)[^])*?beginbfchar([^]*?)endbfchar',
  ).allMatches(raw)) {
    cmaps[m.group(1)!] = {
      for (final p in RegExp(
        r'<([0-9A-F]{4})> <([0-9A-F]{4})>',
      ).allMatches(m.group(2)!))
        int.parse(p.group(1)!, radix: 16): int.parse(p.group(2)!, radix: 16),
    };
  }
  final fonts = <String, Map<int, int>>{};
  for (final m in RegExp(
    r'/Type/Font/Subtype/Type0/Name/(F\d+)(?:(?!endobj)[^])*?/ToUnicode (\d+) 0 R',
  ).allMatches(raw)) {
    fonts[m.group(1)!] = cmaps[m.group(2)!]!;
  }
  final out = StringBuffer();
  Map<int, int>? font;
  for (final m in RegExp(r'/(F\d+) [\d.]+ Tf|\[([^\]]*)\]TJ').allMatches(raw)) {
    if (m.group(1) != null) {
      font = fonts[m.group(1)!];
      continue;
    }
    for (final h in RegExp(r'<([0-9A-Fa-f]+)>').allMatches(m.group(2)!)) {
      final hex = h.group(1)!;
      for (var i = 0; i + 4 <= hex.length; i += 4) {
        out.writeCharCode(
          font![int.parse(hex.substring(i, i + 4), radix: 16)]!,
        );
      }
    }
    out.write(' ');
  }
  return out.toString();
}

/// Page text with every run gap removed: a font-fallback label is drawn one
/// glyph per run, so `'ยอดค้างชำระรวม'` reads `'ย อ ด …'` in the raw text.
Future<String> _joined(MechanicStatementA4View v) async => _pdfText(
  await v.buildPdf(PdfPageFormat.a4, compress: false),
).replaceAll(' ', '');

String _j(String s) => s.replaceAll(' ', '');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('th'));

  test('renders to a PDF', () async {
    final bytes = await _view(2034.5).buildPdf(PdfPageFormat.a4);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    // Set STATEMENT_PDF_OUT to dump the PDF for a visual check.
    final out = Platform.environment['STATEMENT_PDF_OUT'];
    if (out != null) File(out).writeAsBytesSync(bytes);
  });

  test(
    'bills explain the whole balance: lines, aging, total, no residual',
    () async {
      final text = await _joined(_view(2034.5));
      for (final s in [
        'ศรีสุราษฎร์เจริญยนต์',
        'ใบแจ้งยอด/ใบวางบิล',
        'ลุงมานพ',
        'M001',
        'RC01-2569-10-0042',
        'RC01-2569-07-0007',
        '฿1,234.50',
        '฿800.00',
        'ยอดค้างชำระรวม฿2,034.50',
        '0–30วัน',
        'เกิน90วัน',
        'ผู้รับวางบิล',
        '114',
      ]) {
        expect(text, contains(_j(s)), reason: s);
      }
      expect(text, isNot(contains(_j(statementResidualLabel))));
    },
  );

  test('a balance the bills cannot explain prints the residual line', () async {
    final text = await _joined(_view(2500));
    expect(text, contains(_j(statementResidualLabel)));
    expect(text, contains('฿465.50')); // 2500 − 2034.50
    expect(text, contains(_j('ยอดค้างชำระรวม ฿2,500.00')));
  });

  test('balance 0 prints an empty statement', () async {
    final text = await _joined(_view(0));
    expect(text, contains(_j('ไม่มียอดค้างชำระ')));
    expect(text, contains(_j('ยอดค้างชำระรวม ฿0.00')));
    expect(text, isNot(contains('RC01-2569')));
    expect(text, isNot(contains(_j(statementResidualLabel))));
  });

  test('file name: statement-<code>-<name>-YYYY-MM-DD.pdf, sanitized', () {
    expect(
      statementFileName(_mechanic(), _asOf),
      'statement-M001-ลุงมานพ-2026-10-23.pdf',
    );
    expect(
      statementFileName(_mechanic(nameTH: ' อู่ / ช่าง:"ดำ" ? '), _asOf),
      'statement-M001-อู่-ช่าง-ดำ-2026-10-23.pdf',
    );
    expect(
      statementFileName(_mechanic(name: 'Dang <A|B>', nameTH: null), _asOf),
      'statement-M001-Dang-A-B-2026-10-23.pdf',
    );
  });

  test('source tripwire: only the Latin heading is letter-spaced (#479)', () {
    final src = File(
      'lib/presentation/widgets/mechanic_statement_a4.dart',
    ).readAsStringSync();
    final spaced = RegExp(r'letterSpacing:\s*[\d.]+').allMatches(src);
    expect(spaced.map((m) => m.group(0)), ['letterSpacing: 3.2']);
  });
}
