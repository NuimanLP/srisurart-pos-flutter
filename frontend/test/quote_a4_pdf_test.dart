// #479 — Thai labels in the A4 quote PDF must not carry letterSpacing: the
// `pdf` package emits it as the PDF `Tc` operator, which the viewer adds after
// EVERY glyph — including Thai zero-advance tone marks / upper vowels — so each
// mark is pushed off its consonant.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:pdf/pdf.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/presentation/widgets/quote_a4_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('th'));

  test('latinOnlySpacing drops spacing on any Thai text', () {
    expect(latinOnlySpacing('QUOTED BY', 1.6), 1.6);
    expect(latinOnlySpacing('#', 1.4), 1.4);
    expect(latinOnlySpacing('เลขที่', 1.6), isNull);
    expect(latinOnlySpacing('ผู้เสนอราคา · QUOTED BY', 1.6), isNull);
  });

  test('only the two EN-only headings use a raw letterSpacing', () {
    final src = File(
      'lib/presentation/widgets/quote_a4_view.dart',
    ).readAsStringSync();
    // shopNameEN (2.2) and 'QUOTATION' (3.2); every other label must go
    // through latinOnlySpacing so a Thai label never gets `Tc`.
    final raw = RegExp(r'letterSpacing:\s*[\d.]+').allMatches(src).toList();
    expect(raw.map((m) => m.group(0)), [
      'letterSpacing: 2.2',
      'letterSpacing: 3.2',
    ]);
  });

  test('A4 quote renders to a PDF', () async {
    final d = DateTime(2026, 9, 28);
    final view = QuoteA4View(
      quote: QuoteRow(
        id: 'q1',
        quoteNo: 'QT-0001',
        status: 'open',
        date: d,
        validUntil: d.add(const Duration(days: 7)),
        subtotal: 1200,
        discount: 0,
        total: 1200,
        customerName: 'คุณสมชาย',
        customerPhone: '0812345678',
      ),
      items: const [
        QuoteItemRow(
          rowId: 1,
          quoteId: 'q1',
          name: 'ผ้าเบรกหน้า',
          qty: 2,
          price: 600,
        ),
      ],
      settings: const SettingsRowData(
        id: 1,
        shopName: 'ร้านศรีสุรัตน์',
        shopNameEN: 'Srisurart Autopart',
        taxRate: 0.07,
        quoteValidDays: 7,
        phone: '021234567',
        cashierName: 'สมศรี',
      ),
    );
    final bytes = await view.buildPdf(PdfPageFormat.a4);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    // Set QUOTE_PDF_OUT to dump the PDF for a visual check (pdftoppm).
    final out = Platform.environment['QUOTE_PDF_OUT'];
    if (out != null) File(out).writeAsBytesSync(bytes);
  });
}
