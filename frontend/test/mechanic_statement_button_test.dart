// Mechanic credit statement (survey 2026-10-23 §4.2): the mechanic's detail
// has a `พิมพ์ใบแจ้งยอด` button that opens the A4 statement, whose total is the
// stored creditBalance. It must lay out at phone width and at 3x zoom.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/mechanics_screen.dart';
import 'package:srisurart_pos/presentation/widgets/mechanic_statement_a4.dart';
import 'package:srisurart_pos/presentation/widgets/ui_zoom.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
    await initializeDateFormatting('th', null);
  });

  /// Two credit bills for m1 (ลุงมานพ): 300 then 450 → balance 750.
  Future<List<String>> seed(AppDatabase db) async {
    await db
        .update(db.products)
        .write(const ProductsCompanion(stock: Value(100)));
    final sales = SalesRepository(db);
    final receipts = <String>[];
    for (final price in [300.0, 450.0]) {
      final s = await sales.saveSale(
        SaleInput(
          subtotal: price,
          discount: 0,
          total: price,
          paymentMethod: 'เครดิตช่าง',
          mechanicId: 'm1',
          mechanicName: 'ลุงมานพ',
          items: [
            SaleLineInput(productId: 'p1', name: 'กรอง', qty: 1, price: price),
          ],
        ),
      );
      receipts.add(s.receiptNo);
      if (price == 300) {
        // The first bill is a day older, so "newest first" is unambiguous.
        await (db.update(db.sales)..where((t) => t.id.equals(s.id))).write(
          SalesCompanion(date: Value(s.date.subtract(const Duration(days: 1)))),
        );
      }
    }
    return receipts;
  }

  Future<void> pump(
    WidgetTester tester,
    AppDatabase db,
    Size size,
    double zoom,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: repositoryProviders(db, useApiRepositories: false),
        child: MaterialApp(
          home: const Scaffold(body: MechanicsScreen()),
          builder: (context, child) => UiZoom(zoom: zoom, child: child!),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  for (final (label, size, zoom) in const [
    ('phone 390', Size(390, 844), 1.0),
    ('zoom 3x full HD', Size(1920, 1080), 3.0),
    ('desktop side panel', Size(1600, 1000), 1.0),
  ]) {
    testWidgets('พิมพ์ใบแจ้งยอด shows and opens the statement: $label', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.runAsync(() async {
        final receipts = await seed(db);
        await pump(tester, db, size, zoom);
        expect(tester.takeException(), isNull);

        await tester.tap(
          find.textContaining('ลุงมานพ', findRichText: true).first,
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 100));

        final button = find.text('พิมพ์ใบแจ้งยอด');
        await tester.scrollUntilVisible(
          button,
          100,
          scrollable: find.byType(Scrollable).last,
        );
        // Built is not on screen (cache extent): bring it fully into view.
        await tester.ensureVisible(button);
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(button.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(button);
        await settle(tester);

        final view = tester.widget<MechanicStatementA4View>(
          find.byType(MechanicStatementA4View),
        );
        expect(view.mechanic.id, 'm1');
        expect(view.statement.total, 750);
        expect(view.statement.hasResidual, isFalse);
        // Newest bill first.
        expect(view.statement.lines.map((l) => l.receiptNo), [
          receipts[1],
          receipts[0],
        ]);
        expect(tester.takeException(), isNull);
      });
    });
  }
}
