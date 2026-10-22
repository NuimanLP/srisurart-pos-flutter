// Owner request 2026-10-22: an open or received PO card has a พิมพ์ button
// that opens the A4 PO preview (print/share bar of PdfPreview). A cancelled PO
// has none (owner default 2026-10-22).
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/repositories/purchase_orders_repository.dart';
import 'package:srisurart_pos/data/repositories/settings_repository.dart';
import 'package:srisurart_pos/data/repositories/suppliers_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/screens/purchase_orders_screen.dart';
import 'package:srisurart_pos/presentation/widgets/app_button.dart';
import 'package:srisurart_pos/presentation/widgets/purchase_order_a4.dart';
import 'package:srisurart_pos/presentation/widgets/ui_zoom.dart';

/// Settings that arrive only when the test says so.
class _SlowSettings extends SettingsRepository {
  _SlowSettings(super.db);
  final gate = Completer<void>();
  @override
  Future<SettingsRowData> getSettings() async {
    await gate.future;
    return super.getSettings();
  }
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('th', null);
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  const input = PoInput(
    supplier: 'บริษัท จินเส็งฮวด อะไหล่ยนต์ จำกัด (สำนักงานใหญ่)',
    items: [
      PoLineInput(partNo: 'A-1', name: 'ผ้าเบรก', qty: 2, cost: 100),
      PoLineInput(partNo: 'B-2', name: 'หัวเทียน', qty: 3, cost: 50),
    ],
  );

  /// One received, one cancelled and one open PO, on the PO screen.
  Future<({String received, String cancelled, String open})> pump(
    WidgetTester tester,
    AppDatabase db, {
    Size size = const Size(1280, 900),
    double zoom = 1.0,
    SettingsRepository? settings,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = PurchaseOrdersRepository(db);
    final received = await repo.savePO(input);
    await repo.receivePO(received.id);
    final cancelled = await repo.savePO(input);
    await repo.cancelPO(cancelled.id);
    final open = await repo.savePO(input);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PurchaseOrdersRepository>.value(value: repo),
          RepositoryProvider<ProductsRepository>.value(
            value: ProductsRepository(db),
          ),
          RepositoryProvider<SuppliersRepository>.value(
            value: SuppliersRepository(db),
          ),
          RepositoryProvider<SettingsRepository>.value(
            value: settings ?? SettingsRepository(db),
          ),
        ],
        child: MaterialApp(
          home: const Scaffold(body: PurchaseOrdersScreen()),
          builder: (context, child) => UiZoom(zoom: zoom, child: child!),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    return (received: received.id, cancelled: cancelled.id, open: open.id);
  }

  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('open + received have พิมพ์, cancelled has none; tapping opens '
      'the A4 PO preview', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      final ids = await pump(tester, db);
      expect(find.text('พิมพ์'), findsNWidgets(2));

      await tester.tap(find.text('พิมพ์').first);
      await settle(tester);

      final view = tester.widget<PurchaseOrderA4View>(
        find.byType(PurchaseOrderA4View),
      );
      expect([ids.received, ids.open], contains(view.data.po.id));
      // Lines in entry order (rowId), whatever order getPOs returned.
      expect(view.data.items.map((i) => i.partNo), ['A-1', 'B-2']);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text(view.data.po.poNo),
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('a double tap on พิมพ์ opens one preview', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      final slow = _SlowSettings(db);
      await pump(tester, db, settings: slow);
      final printButton = find.widgetWithText(AppButton, 'พิมพ์').first;
      await tester.tap(printButton);
      await tester.pump();
      // While the preview is being prepared every พิมพ์ is disabled.
      expect(tester.widget<AppButton>(printButton).onPressed, isNull);
      await tester.tap(printButton, warnIfMissed: false);
      slow.gate.complete();
      await settle(tester);
      expect(find.byType(PurchaseOrderA4View), findsOneWidget);
    });
  });

  for (final (label, size, zoom) in const [
    ('phone 390', Size(390, 844), 1.0),
    ('zoom 3x full HD', Size(1920, 1080), 3.0),
  ]) {
    testWidgets('PO cards with พิมพ์ lay out without overflow: $label', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.runAsync(() async {
        await pump(tester, db, size: size, zoom: zoom);
        expect(tester.takeException(), isNull);
        expect(find.text('พิมพ์'), findsWidgets);
      });
    });
  }
}
