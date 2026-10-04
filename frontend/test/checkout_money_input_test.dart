// The checkout money fields (cash received, discount) keep only a
// non-negative baht amount with at most 2 decimals: "a40" -> "40" (the discount clamps to the subtotal), and an
// edit to "1.2.3" / "1.234" is refused (previous text kept). Harness mirrors
// checkout_clear_cart_test.dart.

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
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/checkout_screen.dart';

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('cash-received and discount fields refuse malformed amounts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1568, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
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
      cart.add(products.firstWhere((x) => x.stock > 0));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      for (final field in [
        find.widgetWithText(TextField, 'รับเงิน ฿…'),
        find.widgetWithText(TextField, '0'),
      ]) {
        expect(field, findsOneWidget);
        String text() => tester.widget<TextField>(field).controller!.text;
        Future<void> type(String v) async {
          await tester.enterText(field, v);
          await tester.pump();
        }

        await type('a40');
        expect(text(), '40');
        await type('1.2');
        expect(text(), '1.2');
        await type('1.2.3');
        expect(text(), '1.2');
        await type('1.23');
        expect(text(), '1.23');
        await type('1.234');
        expect(text(), '1.23');
      }
      tester.takeException(); // pre-existing product-grid overflow
    });
  });

  testWidgets('discount clamped to a float-noisy subtotal stays editable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1568, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final cart = CartCubit();
    final pq = PendingQuoteCubit();
    addTearDown(cart.close);
    addTearDown(pq.close);
    await tester.runAsync(() async {
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
      // 0.1 + 0.2 = 0.30000000000000004
      cart.setLines(const [
        CartLine(
          productId: 'n1',
          name: 'n1',
          price: 0.1,
          originalPrice: 0.1,
          cost: 0,
          qty: 1,
        ),
        CartLine(
          productId: 'n2',
          name: 'n2',
          price: 0.2,
          originalPrice: 0.2,
          cost: 0,
          qty: 1,
        ),
      ]);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      final field = find.widgetWithText(TextField, '0');
      String text() => tester.widget<TextField>(field).controller!.text;
      await tester.enterText(field, '5'); // above subtotal -> clamped
      await tester.pump();
      expect(text(), '0.3');
      // Still editable: a keystroke after the clamp is not refused.
      await tester.enterText(field, '0.2');
      await tester.pump();
      expect(text(), '0.2');
      tester.takeException();
    });
  });
}
