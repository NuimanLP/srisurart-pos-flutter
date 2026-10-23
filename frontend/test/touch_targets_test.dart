// UX review R10 (owner-approved 2026-10-23): counter controls keep a >=48x48
// hit area on every platform — Android (standard density, padded) AND the
// shop PC's desktop/web defaults (compact density, shrinkWrap), which used to
// shrink them to ~28-32 px. Also: the degraded banner reads at >=14 px and
// still fits a 390 px phone.
//
// No test here swallows exceptions: any overflow the taller 48 px rows cause
// fails the test.

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
    expect(f, findsOneWidget);
    final size = tester.getSize(f);
    expect(size.width, greaterThanOrEqualTo(48), reason: 'width of $f');
    expect(size.height, greaterThanOrEqualTo(48), reason: 'height of $f');
  }

  testWidgets('camera scan button: 48x48 hit area, one accessible name', (
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
    final node = tester.getSemantics(find.byType(IconButton));
    expect(node.label, BarcodeScanButton.scanTooltip);
    // Named once: the hover tooltip is not also announced.
    expect(node.tooltip, isEmpty);
    // Mouse users still get the hover tooltip.
    expect(find.byTooltip(BarcodeScanButton.scanTooltip), findsOneWidget);
    handle.dispose();
  }, variant: platforms);

  // The four call sites host the button as a dense TextField's suffixIcon
  // (products / stocktake search: next to a clear button). It must not
  // overflow the narrowest search box (160 px, products on a phone).
  testWidgets('scan button fits a dense search field suffix at 160 px', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 160,
              child: TextField(
                controller: TextEditingController(text: 'abc'),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  border: const OutlineInputBorder(),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {},
                      ),
                      BarcodeScanButton(onScanned: (_) {}),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expectHit48(tester, find.byType(BarcodeScanButton));
    // The field is exactly as tall as one 48 px target — no extra growth.
    expect(tester.getSize(find.byType(TextField)).height, 48);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  Future<void> pumpCheckout(
    WidgetTester tester,
    Size size,
    Future<void> Function(
      CartCubit cart,
      List<ProductRow> products,
      AppDatabase db,
    )
    body,
  ) async {
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
            child: const MaterialApp(home: Scaffold(body: CheckoutScreen())),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await body(cart, products, db);
    });
  }

  for (final size in const [Size(1280, 800), Size(390, 844), Size(320, 800)]) {
    testWidgets('checkout cart: every changed control is >=48, no overflow '
        '(${size.width.toInt()}px)', (tester) async {
      await pumpCheckout(tester, size, (cart, products, _) async {
        // The scan field is on the products side (phone: first tab).
        expectHit48(tester, find.byType(BarcodeScanButton));

        final p = products.firstWhere((x) => x.stock > 1);
        cart.add(p);
        // An overridden price shows the reset button under the price.
        expect(cart.setPrice(p.id, p.price + 10), isNull);
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        final tab = find.text('ตะกร้า');
        if (tab.evaluate().isNotEmpty) {
          await tester.tap(tab);
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
        }

        expectHit48(tester, find.byKey(Key('cart-price-${p.id}')));
        expectHit48(tester, find.byKey(Key('cart-price-reset-${p.id}')));
        expectHit48(tester, find.byKey(const Key('cart-clear-all')));

        // The +/- of THIS cart line's qty pill.
        final pill = find
            .ancestor(
              of: find.byKey(Key('cart-qty-${p.id}')),
              matching: find.byType(Row),
            )
            .first;
        Finder qtyFinder(IconData icon) => find
            .ancestor(
              of: find.descendant(of: pill, matching: find.byIcon(icon)),
              matching: find.byType(InkWell),
            )
            .first;
        expectHit48(tester, qtyFinder(Icons.add));
        expectHit48(tester, qtyFinder(Icons.delete_outline)); // qty 1

        final toggle = find.byKey(const Key('discountModeToggle'));
        expect(toggle, findsOneWidget);
        expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));

        // Over stock -> the price-warning strip with its close button.
        cart.setQty(p.id, p.stock, p);
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        await tester.ensureVisible(qtyFinder(Icons.add));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        await tester.tap(qtyFinder(Icons.add));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expectHit48(tester, find.byKey(const Key('price-warning-close')));
      });
    }, variant: platforms);
  }

  testWidgets(
    'checkout: the selected-mechanic chip clear button is >=48',
    (tester) async {
      await pumpCheckout(tester, const Size(1800, 2600), (_, _, db) async {
        final mech = (await db.select(db.mechanics).get()).first;
        final label = mech.nameTH ?? mech.name;
        await tester.enterText(
          find.widgetWithText(TextField, 'ค้นหาช่าง / ชื่อเล่น / เบอร์…'),
          label,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        expectHit48(tester, find.byKey(const Key('mechanic-chip-clear')));
      });
    },
    variant: platforms,
  );

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
