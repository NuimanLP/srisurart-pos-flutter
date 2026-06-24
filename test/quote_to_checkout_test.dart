// Regression test for the critical Quote→Checkout hand-off bug.
//
// QuotesManager (convert/edit) stages a quote in `pendingQuoteForCartProvider`
// then navigates to checkout. Before the fix, CheckoutScreen never read that
// provider, so the user landed on an EMPTY cart (and the edit path had already
// deleted the source quote → unrecoverable). This test pumps CheckoutScreen
// with a quote staged and asserts the cart is primed and the provider cleared.
//
// Harness mirrors route_smoke_test.dart: in-memory Drift DB (seeded demo data),
// GoogleFonts runtime fetch disabled, all async drained inside runAsync.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/providers/pending_quote_provider.dart';
import 'package:srisurart_pos/presentation/providers/providers.dart';
import 'package:srisurart_pos/presentation/screens/checkout_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('a staged quote is loaded into the cart on checkout mount',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final db = AppDatabase(NativeDatabase.memory());
    final container =
        ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      // A seeded product with stock to spare.
      final products = await container.read(productsRepoProvider).getAll();
      final p = products.firstWhere((x) => x.stock >= 2);

      // Save a real quote referencing it, then read it back as the aggregate
      // QuotesManager would hand off.
      await container.read(quotesRepoProvider).saveQuote(QuoteInput(
            subtotal: p.price * 2,
            discount: 10,
            total: p.price * 2 - 10,
            customerName: '',
            customerPhone: '',
            items: [
              QuoteLineInput(
                  productId: p.id, name: p.name, qty: 2, price: p.price),
            ],
          ));
      final quotes = await container.read(quotesRepoProvider).getQuotes();
      final QuoteWithItems qi = quotes.first;

      // Stage it exactly as QuotesScreen._loadToCart does.
      container.read(pendingQuoteForCartProvider.notifier).set(qi);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: CheckoutScreen())),
        ),
      );
      // initState post-frame consumes the quote (async getAll + setState).
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      final cart = container.read(cartProvider);
      expect(cart, hasLength(1), reason: 'cart should contain the quote line');
      expect(cart.first.productId, p.id);
      expect(cart.first.qty, 2);
      expect(cart.first.price, p.price);
      // Hand-off provider must be cleared so a rebuild cannot re-load.
      expect(container.read(pendingQuoteForCartProvider), isNull);

      await tester.takeException(); // surface any pump exception
      await db.close();
    });
  });

  testWidgets('over-stock quote qty is clamped to available stock on load',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final db = AppDatabase(NativeDatabase.memory());
    final container =
        ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      final products = await container.read(productsRepoProvider).getAll();
      final p = products.firstWhere((x) => x.stock > 0);
      final overQty = p.stock + 5;

      await container.read(quotesRepoProvider).saveQuote(QuoteInput(
            subtotal: p.price * overQty,
            discount: 0,
            total: p.price * overQty,
            customerName: '',
            customerPhone: '',
            items: [
              QuoteLineInput(
                  productId: p.id, name: p.name, qty: overQty, price: p.price),
            ],
          ));
      final qi = (await container.read(quotesRepoProvider).getQuotes()).first;
      container.read(pendingQuoteForCartProvider.notifier).set(qi);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: CheckoutScreen())),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      final cart = container.read(cartProvider);
      expect(cart, hasLength(1));
      expect(cart.first.qty, p.stock,
          reason: 'qty must be clamped to current stock (validateItems)');

      await tester.takeException();
      await db.close();
    });
  });
}
