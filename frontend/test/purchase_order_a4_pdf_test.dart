// Owner request 2026-10-22: print a PO for the supplier's sales rep.
// Owner decisions 2026-10-22: the paper shows NO prices (no cost, no totals)
// and NO internal status.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:pdf/pdf.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/widgets/purchase_order_a4.dart';

// Distinctive costs: 4 × 357.25 = 1,429 and 12 × 1,234.75 = 14,817; the
// grand total is 16,246. None of these digits occur anywhere else on the page.
PurchaseOrderA4View _view({String status = 'received'}) => PurchaseOrderA4View(
  data: PurchaseOrderWithItems(
    PurchaseOrderRow(
      id: 'po1',
      poNo: 'PO-2569-0007',
      supplier: 'บริษัท จินเส็งฮวด จำกัด',
      status: status,
      createdAt: DateTime(2026, 10, 22),
      receivedAt: DateTime(2026, 10, 23),
    ),
    const [
      PoItemRow(
        rowId: 1,
        poId: 'po1',
        partNo: 'BRK-001',
        name: 'ผ้าเบรกหน้า โตโยต้า วีโก้',
        qty: 4,
        cost: 357.25,
      ),
      PoItemRow(
        rowId: 2,
        poId: 'po1',
        partNo: 'NGK-BKR6E',
        name: 'หัวเทียน NGK',
        qty: 12,
        cost: 1234.75,
      ),
    ],
  ),
  settings: const SettingsRowData(
    id: 1,
    shopName: 'ร้านศรีสุราษฎร์เจริญยนต์',
    shopNameEN: 'Srisurart Autopart',
    taxRate: 0.07,
    quoteValidDays: 7,
    address: '99 ถ.ตลาดใหม่ อ.เมือง จ.สุราษฎร์ธานี',
    phone: '077000888',
    taxId: '0845555000999',
  ),
);

/// The text actually drawn on the page. The `pdf` package writes text as
/// glyph codes (Identity-H) per font, with a ToUnicode `bfchar` map on each
/// font; this decodes every `TJ` through the map of the font set by the
/// preceding `Tf`. Needs an uncompressed document. Runs are joined by a space.
String _pdfText(List<int> bytes) {
  final raw = String.fromCharCodes(bytes);
  final cmaps = <String, Map<int, int>>{}; // object number → code → rune
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
  final fonts = <String, Map<int, int>>{}; // /Fn → map
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('th'));

  test('a 2-line PO renders to a PDF', () async {
    final bytes = await _view(status: 'open').buildPdf(PdfPageFormat.a4);
    expect(bytes.length, greaterThan(1000));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    // Set PO_PDF_OUT to dump the PDF for a visual check (pdftoppm/pdftotext).
    final out = Platform.environment['PO_PDF_OUT'];
    if (out != null) File(out).writeAsBytesSync(bytes);
  });

  test('the page text has the PO, but no price and no status', () async {
    final text = _pdfText(
      await _view().buildPdf(PdfPageFormat.a4, compress: false),
    );
    // A font-fallback label is drawn one glyph per run, so a number in it
    // reads '1 4 2 9'; also check with the run gaps removed.
    final joined = text.replaceAll(' ', '');
    // The extractor reads the real page: what must be there, is.
    for (final s in ['PO-2569-0007', 'BRK-001', 'NGK-BKR6E', 'จินเส็งฮวด']) {
      expect(text, contains(s));
    }
    // Owner 2026-10-22: no cost, line total or grand total, in any format.
    for (final s in [
      '฿', '357', '.25', '1234', '1,234', '.75', //
      '1429', '1,429', '14817', '14,817', '16246', '16,246',
    ]) {
      expect(text, isNot(contains(s)), reason: 'price "$s" on the paper');
    }
    for (final s in ['฿', '357', '1234', '1429', '14817', '16246']) {
      expect(joined, isNot(contains(s)), reason: 'price "$s" on the paper');
    }
    // Owner 2026-10-22: no internal status / received date.
    for (final s in [
      'สถานะ',
      'รับแล้ว',
      'รอรับสินค้า',
      'รับสินค้าเมื่อ',
      '23 ต.ค.',
    ]) {
      expect(text, isNot(contains(s)), reason: 'status "$s" on the paper');
    }
  });

  test('source tripwire: no cost/money helper in the PO PDF', () {
    // Run from frontend/, like `flutter test`.
    final src = File(
      'lib/presentation/widgets/purchase_order_a4.dart',
    ).readAsStringSync();
    expect(src.contains('.cost'), isFalse);
    expect(src.contains('baht'), isFalse);
    expect(src.contains('฿'), isFalse);
    // #479: only the constant Latin heading is letter-spaced.
    final spaced = RegExp(r'letterSpacing:\s*[\d.]+').allMatches(src);
    expect(spaced.map((m) => m.group(0)), ['letterSpacing: 3.2']);
  });
}
