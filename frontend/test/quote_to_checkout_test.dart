// Regression test for the critical Quote→Checkout hand-off bug.
//
// QuotesManager (convert/edit) stages a quote in `PendingQuoteCubit` then
// navigates to checkout. Before the fix, CheckoutScreen never read that
// cubit, so the user landed on an EMPTY cart (and the edit path had already
// deleted the source quote → unrecoverable). This test pumps CheckoutScreen
// with a quote staged and asserts the cart is primed and the cubit cleared.
//
// Harness mirrors route_smoke_test.dart: in-memory Drift DB (seeded demo data),
// GoogleFonts runtime fetch disabled, all async drained inside runAsync.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/repositories/quotes_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/checkout_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('a staged quote is loaded into the cart on checkout mount', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final productsRepo = ProductsRepository(db);
    final quotesRepo = QuotesRepository(db);
    final pendingQuoteCubit = PendingQuoteCubit();
    final cartCubit = CartCubit();
    addTearDown(pendingQuoteCubit.close);
    addTearDown(cartCubit.close);

    await tester.runAsync(() async {
      // A seeded product with stock to spare.
      final products = await productsRepo.getAll();
      final p = products.firstWhere((x) => x.stock >= 2);

      // Save a real quote referencing it, then read it back as the aggregate
      // QuotesManager would hand off.
      await quotesRepo.saveQuote(
        QuoteInput(
          subtotal: p.price * 2,
          discount: 10,
          total: p.price * 2 - 10,
          customerName: '',
          customerPhone: '',
          items: [
            QuoteLineInput(
              productId: p.id,
              name: p.name,
              qty: 2,
              price: p.price,
            ),
          ],
        ),
      );
      final quotes = await quotesRepo.getQuotes();
      final QuoteWithItems qi = quotes.first;

      // Stage it exactly as QuotesScreen._loadToCart does.
      pendingQuoteCubit.set(qi);

      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db),
          child: MultiBlocProvider(
            providers: [
              BlocProvider<PendingQuoteCubit>.value(value: pendingQuoteCubit),
              BlocProvider<CartCubit>.value(value: cartCubit),
            ],
            child: const MaterialApp(home: Scaffold(body: CheckoutScreen())),
          ),
        ),
      );
      // initState post-frame consumes the quote (async getAll + setState).
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      final cart = cartCubit.state;
      expect(cart, hasLength(1), reason: 'cart should contain the quote line');
      expect(cart.first.productId, p.id);
      expect(cart.first.qty, 2);
      expect(cart.first.price, p.price);
      // Hand-off cubit must be cleared so a rebuild cannot re-load.
      expect(pendingQuoteCubit.state, isNull);

      await tester.takeException(); // surface any pump exception
    });
  });

  testWidgets('over-stock quote qty is clamped to available stock on load', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final productsRepo = ProductsRepository(db);
    final quotesRepo = QuotesRepository(db);
    final pendingQuoteCubit = PendingQuoteCubit();
    final cartCubit = CartCubit();
    addTearDown(pendingQuoteCubit.close);
    addTearDown(cartCubit.close);

    await tester.runAsync(() async {
      final products = await productsRepo.getAll();
      final p = products.firstWhere((x) => x.stock > 0);
      final overQty = p.stock + 5;

      await quotesRepo.saveQuote(
        QuoteInput(
          subtotal: p.price * overQty,
          discount: 0,
          total: p.price * overQty,
          customerName: '',
          customerPhone: '',
          items: [
            QuoteLineInput(
              productId: p.id,
              name: p.name,
              qty: overQty,
              price: p.price,
            ),
          ],
        ),
      );
      final qi = (await quotesRepo.getQuotes()).first;
      pendingQuoteCubit.set(qi);

      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db),
          child: MultiBlocProvider(
            providers: [
              BlocProvider<PendingQuoteCubit>.value(value: pendingQuoteCubit),
              BlocProvider<CartCubit>.value(value: cartCubit),
            ],
            child: const MaterialApp(home: Scaffold(body: CheckoutScreen())),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      final cart = cartCubit.state;
      expect(cart, hasLength(1));
      expect(
        cart.first.qty,
        p.stock,
        reason: 'qty must be clamped to current stock (validateItems)',
      );

      await tester.takeException();
    });
  });
}
