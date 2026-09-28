// #477 — `_RecentRow` (reports_screen.dart, "บิลล่าสุด" card) overflowed at
// 390px width: the chip Row (`${n} รายการ` + payment method) had no
// Flexible/Wrap, so a long payment method string (`เครดิตช่าง`) at the
// largest font scale pushed past the Expanded's width, and the unbounded
// total Text could squeeze the same Expanded below its needed width.
// Fixed by wrapping the chips in a `Wrap` and the total in `Flexible` +
// `TextOverflow.ellipsis` (reports_screen.dart `_RecentRow.build`).
//
// Harness mirrors reports_kpi_phone_width_test.dart (#463), whose own
// comment flagged this exact overflow as then-out-of-scope.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/repositories/returns_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/presentation/screens/reports_screen.dart';

void main() {
  late AppDatabase db;

  setUpAll(() async {
    await initializeDateFormatting('th', null);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final now = DateTime.now();
    // A six-figure sale paid with the longest payment-method string in the
    // app ("เครดิตช่าง") — the two suspects the issue names as most likely
    // to overflow a narrow Expanded.
    await db.into(db.sales).insert(
          SalesCompanion.insert(
            id: 's1',
            receiptNo: 'RC-000123',
            subtotal: 123456.78,
            total: 123456.78,
            paymentMethod: 'เครดิตช่าง',
            date: now,
          ),
        );
    await db.into(db.saleItems).insert(
          SaleItemsCompanion.insert(
            saleId: 's1',
            productId: 'p1',
            partNo: const Value('X1'),
            name: 'สินค้า 1',
            qty: 3,
            price: 41152.26,
          ),
        );
  });

  tearDown(() async => db.close());

  Future<void> pumpReports(WidgetTester tester, {double textScale = 1.0}) async {
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<SalesRepository>(create: (_) => SalesRepository(db)),
          RepositoryProvider<ReturnsRepository>(create: (_) => ReturnsRepository(db)),
          RepositoryProvider<ProductsRepository>(create: (_) => ProductsRepository(db)),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const ReportsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    '_RecentRow renders the credit-mechanic payment method and a six-figure '
    'total at 390px width without a RenderFlex overflow (#477)',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // Largest preset the settings screen offers (fontScalePresets, "ใหญ่พิเศษ").
      await pumpReports(tester, textScale: 1.25);

      expect(find.text('เครดิตช่าง'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '_RecentRow renders the same sale without overflow at normal text scale (#477)',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await pumpReports(tester);

      expect(find.text('เครดิตช่าง'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '_RecentRow still renders the same sale without overflow at desktop width (#477)',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await pumpReports(tester);

      expect(find.text('เครดิตช่าง'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
