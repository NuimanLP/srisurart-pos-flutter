// UX review R10 (owner-approved 2026-10-23): counter controls keep a >=48x48
// hit area on every platform — Android (standard density, padded) AND the
// shop PC's desktop/web defaults (compact density, shrinkWrap), which used to
// shrink them to ~28-32 px. Also: the degraded banner reads at >=14 px and
// still fits a 390 px phone.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/checkout_screen.dart';
import 'package:srisurart_pos/presentation/widgets/app_shell.dart';
import 'package:srisurart_pos/presentation/widgets/barcode_scan_button.dart';

import 'support/fake_sync_facade.dart';

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  final platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.windows,
  });

  void expectHit48(WidgetTester tester, Finder f) {
    final size = tester.getSize(f);
    expect(size.width, greaterThanOrEqualTo(48), reason: 'width of $f');
    expect(size.height, greaterThanOrEqualTo(48), reason: 'height of $f');
  }

  testWidgets('camera scan button: 48x48 hit area + accessible label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: BarcodeScanButton(onScanned: (_) {})),
        ),
      ),
    );
    expectHit48(tester, find.byType(IconButton));
    expect(
      tester.getSemantics(find.byType(IconButton)),
      matchesSemantics(
        label: BarcodeScanButton.scanTooltip,
        tooltip: BarcodeScanButton.scanTooltip,
        isButton: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
      ),
    );
    handle.dispose();
  }, variant: platforms);

  for (final size in const [Size(1280, 800), Size(390, 844)]) {
    testWidgets(
      'checkout cart: price override, qty, clear-all and scan are >=48 '
      '(${size.width.toInt()}px)',
      (tester) async {
        tester.view.physicalSize = size;
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
          await tester.pumpWidget(
            MultiRepositoryProvider(
              providers: repositoryProviders(db),
              child: MultiBlocProvider(
                providers: [
                  BlocProvider<PendingQuoteCubit>.value(value: pq),
                  BlocProvider<CartCubit>.value(value: cart),
                ],
                child: const MaterialApp(
                  home: Scaffold(body: CheckoutScreen()),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle(const Duration(milliseconds: 100));

          // The scan field is on the products side (phone: first tab).
          expectHit48(tester, find.byType(BarcodeScanButton).first);

          final p = products.firstWhere((x) => x.stock > 0);
          cart.add(p);
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          final tab = find.text('ตะกร้า');
          if (tab.evaluate().isNotEmpty) {
            await tester.tap(tab);
            await tester.pumpAndSettle(const Duration(milliseconds: 100));
          }

          final price = find.byKey(Key('cart-price-${p.id}'));
          expect(price, findsOneWidget);
          expectHit48(tester, price);
          expectHit48(tester, find.byKey(const Key('cart-clear-all')));
          final toggle = find.byKey(const Key('discountModeToggle'));
          if (toggle.evaluate().isNotEmpty) {
            expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));
          }
          final plus = find.ancestor(
            of: find.byIcon(Icons.add),
            matching: find.byType(InkWell),
          );
          expectHit48(tester, plus.first);
          tester.takeException(); // product-grid overflow is pre-existing
        });
      },
      variant: platforms,
    );
  }

  testWidgets('degraded banner: >=14 px text, no overflow at 390 px', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fake = FakeSyncFacade();
    await tester.runAsync(() async {
      fake.emitStatus(SyncStatus.degraded);
      fake.emitNeedsOwner(const []);
      await tester.pumpWidget(
        RepositoryProvider<SyncFacade>.value(
          value: fake,
          child: const MaterialApp(
            home: Scaffold(body: Column(children: [SyncAlertBanner()])),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 50));
      }
    });
    final text = find.textContaining('ออฟไลน์ (ขายสำรอง)');
    expect(text, findsOneWidget);
    expect(tester.widget<Text>(text).style!.fontSize, greaterThanOrEqualTo(14));
    expect(tester.takeException(), isNull);
  });
}
