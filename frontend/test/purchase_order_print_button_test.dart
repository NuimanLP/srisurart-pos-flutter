// Owner request 2026-10-22: every PO card (open / received / cancelled) has a
// พิมพ์ button that opens the A4 PO preview (print/share bar of PdfPreview).
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
import 'package:srisurart_pos/presentation/widgets/purchase_order_a4.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('th', null);
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  const input = PoInput(
    supplier: 'ซัพทดสอบ',
    items: [
      PoLineInput(partNo: 'A-1', name: 'ผ้าเบรก', qty: 2, cost: 100),
      PoLineInput(partNo: 'B-2', name: 'หัวเทียน', qty: 3, cost: 50),
    ],
  );

  testWidgets('every PO status has พิมพ์; tapping opens the A4 PO preview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
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
              value: SettingsRepository(db),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: PurchaseOrdersScreen()),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(find.text('พิมพ์'), findsNWidgets(3));

      await tester.tap(find.text('พิมพ์').first);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final view = tester.widget<PurchaseOrderA4View>(
        find.byType(PurchaseOrderA4View),
      );
      expect([received.id, cancelled.id, open.id], contains(view.data.po.id));
      expect(view.data.items, hasLength(2));
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text(view.data.po.poNo),
        ),
        findsOneWidget,
      );
    });
  });
}
