// Pain point 1a (docs/research/pain-points-ai-leverage-2026-10-23.md §4.1):
// the day's โอน/QR bills on A4 with a box to tick against the bank app.
// The per-account totals must equal the closing report's โอน/QR split to the
// satang — checked here against the closing report widget itself.

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/utils/money.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/payment_accounts_repository.dart';
import 'package:srisurart_pos/data/repositories/returns_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/domain/reports/net_sales.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/widgets/closing_report.dart';
import 'package:srisurart_pos/presentation/widgets/qr_bill_ticklist.dart';
import 'package:srisurart_pos/presentation/widgets/ui_zoom.dart';

const _price = 123.45;

/// A product with stock to spare, at a price with satang.
Future<void> _seedProduct(AppDatabase db) => db
    .into(db.products)
    .insert(
      ProductsCompanion.insert(
        id: 'qp1',
        partNo: 'QR-1',
        name: 'ผ้าเบรก',
        nameTH: 'ผ้าเบรก',
        category: 'general',
        brand: 'X',
        price: _price,
        cost: 50,
        stock: 100,
        minStock: 0,
      ),
    );

Future<SaleRow> _sell(
  AppDatabase db,
  String method, {
  String? account,
  int qty = 1,
}) => SalesRepository(db).saveSale(
  SaleInput(
    subtotal: _price * qty,
    discount: 0,
    total: _price * qty,
    paymentMethod: method,
    paymentAccountId: account,
    items: [
      SaleLineInput(
        productId: 'qp1',
        partNo: 'QR-1',
        name: 'ผ้าเบรก',
        qty: qty,
        price: _price,
      ),
    ],
  ),
);

Future<ReturnRow> _return(AppDatabase db, String saleId, int qty, String m) =>
    ReturnsRepository(db).createReturn(
      ReturnInput(
        saleId: saleId,
        refundMethod: m,
        items: [
          ReturnLineInput(
            productId: 'qp1',
            name: 'ผ้าเบรก',
            qty: qty,
            price: _price,
          ),
        ],
      ),
    );

Future<String> _account(AppDatabase db, String nickname) async =>
    (await PaymentAccountsRepository(db).addAccount(
      PaymentAccountInput(
        nickname: nickname,
        bankCode: 'SCB',
        kind: 'promptpay',
        promptpayId: '0812345678',
      ),
    )).id;

/// Pumps [child] under the Drift-build providers; returns a context that can
/// read them.
Future<BuildContext> _pump(
  WidgetTester tester,
  AppDatabase db,
  Widget child, {
  Size size = const Size(1280, 900),
  double zoom = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  late BuildContext ctx;
  await tester.pumpWidget(
    MultiRepositoryProvider(
      providers: repositoryProviders(db, useApiRepositories: false),
      child: MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return Scaffold(body: child);
          },
        ),
        builder: (context, w) => UiZoom(zoom: zoom, child: w!),
      ),
    ),
  );
  return ctx;
}

double _linesSum(QrTickGroup g) => g.lines.fold(0, (a, l) => a + l.amount);

void main() {
  setUpAll(() async {
    await initializeDateFormatting('th', null);
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('per-account totals equal the closing report\'s โอน/QR split; '
      'manual void out, labels for deleted / no account', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      await _seedProduct(db);
      final shop = await _account(db, 'บัญชีร้านหลัก');
      final gone = await _account(db, 'สาขาเก่า');
      final s1 = await _sell(db, 'โอน/QR', account: shop);
      final s2 = await _sell(db, 'โอน/QR', account: shop, qty: 2);
      final s3 = await _sell(db, 'โอน/QR', account: gone);
      final s4 = await _sell(db, 'โอน/QR');
      final voided = await _sell(db, 'โอน/QR', account: shop, qty: 3);
      final s6 = await _sell(db, 'โอน/QR', account: shop, qty: 2);
      final cash = await _sell(db, 'เงินสด', account: shop, qty: 5);
      // A manual void: the bill is gone, so it is not on the list.
      await (db.update(db.sales)..where((t) => t.id.equals(voided.id))).write(
        const SalesCompanion(voided: Value(true)),
      );
      // A transfer refund: its own negative line under the bill's account.
      final cn = await _return(db, s6.id, 1, 'โอน');
      // A cash refund of a QR bill: no bank money moved, bill stays full.
      await _return(db, s2.id, 1, 'เงินสด');
      await PaymentAccountsRepository(db).deleteAccount(gone);

      final ctx = await _pump(tester, db, const SizedBox());
      final list = await loadQrTickList(ctx, DateTime.now());

      expect(list.groups.map((g) => (g.label, g.bills)), [
        ('บัญชีร้านหลัก', 3),
        (qrDeletedAccountLabel, 1),
        (qrNoAccountLabel, 1),
      ]);
      final main = list.groups.first;
      expect(main.net, closeTo(_price * 5 - _price, 0.001));
      expect(
        main.lines.map((l) => (l.docNo, l.isRefund)),
        unorderedEquals([
          (s1.receiptNo, false),
          (s2.receiptNo, false),
          (s6.receiptNo, false),
          (cn.cnNo, true),
        ]),
      );
      expect(main.lines.firstWhere((l) => l.isRefund).amount, -_price);
      expect(list.groups[1].lines.single.docNo, s3.receiptNo);
      expect(list.groups[2].lines.single.docNo, s4.receiptNo);
      final docs = list.groups.expand((g) => g.lines).map((l) => l.docNo);
      expect(docs, isNot(contains(voided.receiptNo)));
      expect(docs, isNot(contains(cash.receiptNo)));
      // The lines add up to each account's total, and the accounts to the
      // โอน/QR row.
      for (final g in list.groups) {
        expect(_linesSum(g), closeTo(g.net, 0.001), reason: g.label);
      }
      expect(
        list.groups.fold<double>(0, (a, g) => a + g.net),
        closeTo(list.total.net, 0.001),
      );

      // The closing report, on the same day, shows the same rows.
      await _pump(tester, db, const ClosingReport());
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.textContaining('(${list.total.bills} บิล)'), findsWidgets);
      for (final g in list.groups) {
        final label = find.textContaining('· ${g.label} (${g.bills} บิล)');
        expect(label, findsOneWidget, reason: g.label);
        final row = find.ancestor(of: label, matching: find.byType(Row)).first;
        expect(
          find.descendant(of: row, matching: find.text(baht(g.net))),
          findsOneWidget,
          reason: g.label,
        );
      }
    });
  });

  testWidgets('a past day keeps a bill fully returned later (auto-void); the '
      'refund is on the day it was paid back', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      await _seedProduct(db);
      final shop = await _account(db, 'บัญชีร้านหลัก');
      final sale = await _sell(db, 'โอน/QR', account: shop);
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      await (db.update(db.sales)..where((t) => t.id.equals(sale.id))).write(
        SalesCompanion(date: Value(yesterday)),
      );
      final cn = await _return(db, sale.id, 1, 'โอน'); // full → auto-void

      final ctx = await _pump(tester, db, const SizedBox());
      final before = await loadQrTickList(ctx, yesterday);
      expect(before.groups.single.label, 'บัญชีร้านหลัก');
      expect(before.groups.single.bills, 1);
      expect(before.groups.single.net, closeTo(_price, 0.001));
      expect(before.groups.single.lines.single.docNo, sale.receiptNo);

      final today = await loadQrTickList(ctx, DateTime.now());
      final g = today.groups.single;
      expect((g.label, g.bills), ('บัญชีร้านหลัก', 0));
      expect(g.net, closeTo(-_price, 0.001));
      expect(g.lines.single.docNo, cn.cnNo);
      expect(g.lines.single.isRefund, isTrue);
    });
  });

  group('PDF', () {
    final view = QrTickListA4View(
      data: QrTickList(
        day: DateTime(2026, 10, 23),
        shopName: 'ร้านศรีสุราษฎร์เจริญยนต์',
        total: const PaymentGroup(3, 1234.5 + 99 - 40 + 15.25),
        groups: [
          QrTickGroup('บัญชีร้านหลัก', 2, 1234.5 + 99 - 40, [
            QrTickLine(
              DateTime(2026, 10, 23, 9, 5),
              'RC01-2569-10-0001',
              1234.5,
            ),
            QrTickLine(DateTime(2026, 10, 23, 11, 40), 'RC01-2569-10-0002', 99),
            QrTickLine(
              DateTime(2026, 10, 23, 15, 0),
              'CN01-2569-10-0001',
              -40,
              isRefund: true,
            ),
          ]),
          QrTickGroup(qrDeletedAccountLabel, 0, 0, const []),
          QrTickGroup(qrNoAccountLabel, 1, 15.25, [
            QrTickLine(
              DateTime(2026, 10, 23, 16, 30),
              'RC01-2569-10-0003',
              15.25,
            ),
          ]),
        ],
      ),
    );

    test('renders to an A4 PDF named qr-YYYY-MM-DD.pdf', () async {
      final bytes = await view.buildPdf(PdfPageFormat.a4);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      // Set QR_PDF_OUT to dump the PDF for a visual check.
      final out = Platform.environment['QR_PDF_OUT'];
      if (out != null) File(out).writeAsBytesSync(bytes);
    });

    testWidgets('the preview offers the file name', (tester) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: view)));
      final preview = tester.widget<PdfPreview>(find.byType(PdfPreview));
      expect(preview.pdfFileName, 'qr-2026-10-23.pdf');
    });

    test(
      'the page text has every line, label, amount and the totals',
      () async {
        final text = _pdfText(
          await view.buildPdf(PdfPageFormat.a4, compress: false),
        );
        for (final s in [
          'รายการบิล โอน/QR',
          'ร้านศรีสุราษฎร์เจริญยนต์',
          '23 ต.ค. 2569',
          'บัญชีร้านหลัก (2 บิล)',
          '$qrDeletedAccountLabel (0 บิล)',
          '$qrNoAccountLabel (1 บิล)',
          'RC01-2569-10-0001',
          'RC01-2569-10-0002',
          'คืนเงิน CN01-2569-10-0001',
          'RC01-2569-10-0003',
          '09:05',
          '฿1,234.50',
          '−฿40.00',
          '฿1,293.50', // บัญชีร้านหลัก
          '฿15.25',
          'รวม โอน/QR (3 บิล) ฿1,308.75',
          'ตรวจ',
        ]) {
          expect(text, contains(s));
        }
      },
    );

    test('every line has its own tick box', () async {
      // One account, 4 lines: cell clips are relative to their own table, so
      // spots are only comparable within one table.
      final one = QrTickListA4View(
        data: QrTickList(
          day: DateTime(2026, 10, 23),
          shopName: 'ร้าน',
          total: const PaymentGroup(4, 4),
          groups: [
            QrTickGroup('บัญชีร้านหลัก', 4, 4, [
              for (var i = 1; i <= 4; i++)
                QrTickLine(DateTime(2026, 10, 23, 9, i), 'RC-$i', 1),
            ]),
          ],
        ),
      );
      final raw = String.fromCharCodes(
        await one.buildPdf(PdfPageFormat.a4, compress: false),
      );
      // Each table cell is drawn inside its own clip `x y w h re W n`; the box
      // itself is `0 0 12 12 re` inside it. Count the distinct cells that draw
      // a box (one shared pw widget lands N times in one cell).
      final boxes = {
        for (final m in RegExp(
          r'(-?[\d.]+) (-?[\d.]+) -?[\d.]+ -?[\d.]+ re W n(?:(?! re W n)[^])*? 0 0 12 12 re',
        ).allMatches(raw))
          '${m.group(1)} ${m.group(2)}',
      }.length;
      expect(boxes, 4);
    });

    test('source tripwire: no letterSpacing (#479)', () {
      final src = File(
        'lib/presentation/widgets/qr_bill_ticklist.dart',
      ).readAsStringSync();
      expect(RegExp(r'letterSpacing\s*:').hasMatch(src), isFalse);
    });
  });

  group('layout', () {
    for (final (label, size, zoom) in const [
      ('phone 390', Size(390, 844), 1.0),
      ('zoom 3x full HD', Size(1920, 1080), 3.0),
    ]) {
      testWidgets('closing report button opens the tick list: $label', (
        tester,
      ) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        await tester.runAsync(() async {
          await _seedProduct(db);
          await _sell(db, 'โอน/QR', account: await _account(db, 'บัญชีร้าน'));
          await _pump(
            tester,
            db,
            const ClosingReport(),
            size: size,
            zoom: zoom,
          );
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);

          final button = find.text('พิมพ์รายการ โอน/QR');
          await tester.ensureVisible(button);
          await tester.tap(button);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.byType(QrTickListPage), findsOneWidget);
          expect(find.byType(QrTickListA4View), findsOneWidget);
          expect(find.text('เลือกวันที่'), findsOneWidget);
        });
      });
    }
  });
}

/// The text drawn on the page — the decoder of
/// `purchase_order_a4_pdf_test.dart` (glyph codes through each font's
/// ToUnicode map). Needs an uncompressed document; runs joined by a space.
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
