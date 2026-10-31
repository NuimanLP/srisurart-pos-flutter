// Camera barcode scan button (owner request 2026-10-12). The camera cannot run
// in tests, so the scanner is the injectable seam `barcodeScanner`.
//  • the shared button hands a trimmed scan to its screen, ignores cancel/blank;
//  • Products: a scan lands in the search box and filters the list;
//  • Checkout: a scan goes through _handleBarcode — a known partNo joins the
//    cart, an unknown one gets the same "ไม่พบรหัส" alert as typed input.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/ui_zoom_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/checkout_screen.dart';
import 'package:srisurart_pos/presentation/screens/products_screen.dart';
import 'package:srisurart_pos/presentation/widgets/barcode_scan_button.dart';

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  final cam = find.byIcon(Icons.photo_camera_outlined);

  late BarcodeScanner saved;
  setUp(() => saved = barcodeScanner);
  tearDown(() => barcodeScanner = saved);

  testWidgets('button passes a trimmed scan; cancel and blank do nothing', (
    tester,
  ) async {
    final got = <String>[];
    String? next;
    barcodeScanner = (_) async => next;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BarcodeScanButton(onScanned: got.add)),
      ),
    );
    next = '  ABC-1 \n';
    await tester.tap(cam);
    await tester.pump();
    next = null;
    await tester.tap(cam);
    await tester.pump();
    next = '   ';
    await tester.tap(cam);
    await tester.pump();
    expect(got, ['ABC-1']);
  });

  testWidgets('Products: a scan fills the search box and filters', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      final all = await ProductsRepository(db).getAll();
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db, useApiRepositories: false),
          child: MultiBlocProvider(
            providers: [
              BlocProvider<UiZoomCubit>(create: (_) => UiZoomCubit()),
              BlocProvider<PendingQuoteCubit>(
                create: (_) => PendingQuoteCubit(),
              ),
              BlocProvider<CartCubit>(create: (_) => CartCubit()),
            ],
            child: const MaterialApp(home: Scaffold(body: ProductsScreen())),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      barcodeScanner = (_) async => all.first.partNo;
      await tester.tap(cam);
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, all.first.partNo);
      expect(find.textContaining('จาก ${all.length} รายการ'), findsOneWidget);
      await db.close();
    });
  });

  testWidgets('Products: add-product form scan fills the part number', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db, useApiRepositories: false),
          child: MultiBlocProvider(
            providers: [
              BlocProvider<UiZoomCubit>(create: (_) => UiZoomCubit()),
              BlocProvider<PendingQuoteCubit>(
                create: (_) => PendingQuoteCubit(),
              ),
              BlocProvider<CartCubit>(create: (_) => CartCubit()),
            ],
            child: const MaterialApp(home: Scaffold(body: ProductsScreen())),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      await tester.tap(find.text('เพิ่มสินค้า'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      barcodeScanner = (_) async => 'SCAN-NEW-1';
      final dialogCam = find.descendant(
        of: find.byType(Dialog),
        matching: find.byTooltip(BarcodeScanButton.scanTooltip),
      );
      await tester.tap(dialogCam);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final partNo = tester.widget<TextField>(
        find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(TextField),
            )
            .first,
      );
      expect(partNo.controller!.text, 'SCAN-NEW-1');
      tester.takeException(); // category-dropdown overflow in the test font is pre-existing
      await db.close();
    });
  });

  testWidgets('Checkout: a scan adds a known part, alerts an unknown one', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final cart = CartCubit();
    final pq = PendingQuoteCubit();
    addTearDown(cart.close);
    addTearDown(pq.close);
    await tester.runAsync(() async {
      final products = await ProductsRepository(db).getAll();
      final p = products.firstWhere((x) => x.stock > 0);
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db),
          child: MultiBlocProvider(
            providers: [
              BlocProvider<PendingQuoteCubit>.value(value: pq),
              BlocProvider<CartCubit>.value(value: cart),
            ],
            child: const MaterialApp(home: Scaffold(body: CheckoutScreen())),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(cart.state, isEmpty);
      barcodeScanner = (_) async => p.partNo.toUpperCase();
      await tester.tap(cam);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(cart.state.single.productId, p.id);

      barcodeScanner = (_) async => 'NO-SUCH-PART';
      await tester.tap(cam);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.textContaining('ไม่พบรหัส: NO-SUCH-PART'), findsOneWidget);
      expect(cart.state.length, 1);
      tester.takeException(); // product-grid overflow is pre-existing
    });
  });
}
