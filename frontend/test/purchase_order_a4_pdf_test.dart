// Owner request 2026-10-22: print a PO for the supplier's sales rep.
// Owner decision 2026-10-22: the paper shows NO prices (no cost, no totals).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:pdf/pdf.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/widgets/purchase_order_a4.dart';

PurchaseOrderA4View _view() => PurchaseOrderA4View(
  data: PurchaseOrderWithItems(
    PurchaseOrderRow(
      id: 'po1',
      poNo: 'PO-2569-0007',
      supplier: 'บริษัท จินเส็งฮวด จำกัด',
      status: 'open',
      createdAt: DateTime(2026, 10, 22),
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
        cost: 62,
      ),
    ],
  ),
  settings: const SettingsRowData(
    id: 1,
    shopName: 'ร้านศรีสุราษฎร์เจริญยนต์',
    shopNameEN: 'Srisurart Autopart',
    taxRate: 0.07,
    quoteValidDays: 7,
    address: '123 ถ.ตลาดใหม่ อ.เมือง จ.สุราษฎร์ธานี',
    phone: '077123456',
    taxId: '0845555000123',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('th'));

  test('a 2-line PO renders to a PDF', () async {
    final bytes = await _view().buildPdf(PdfPageFormat.a4);
    expect(bytes.length, greaterThan(1000));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    // Set PO_PDF_OUT to dump the PDF for a visual check (pdftoppm/pdftotext).
    final out = Platform.environment['PO_PDF_OUT'];
    if (out != null) File(out).writeAsBytesSync(bytes);
  });

  test('no price reaches the paper (owner 2026-10-22)', () async {
    // Uncompressed, the embedded fonts' ToUnicode maps list every character
    // drawn; the baht sign U+0E3F must not be among them, while Thai text
    // (e.g. U+0E23 ร) is — proving the check reads the right streams.
    final raw = String.fromCharCodes(
      await _view().buildPdf(PdfPageFormat.a4, compress: false),
    ).toUpperCase();
    expect(raw.contains('0E23'), isTrue);
    expect(raw.contains('0E3F'), isFalse);
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
