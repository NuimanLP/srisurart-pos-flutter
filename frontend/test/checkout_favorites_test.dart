// Sell-screen favorites: the card's star toggles a favorite without adding to
// the cart, starred products sort first, and the ⭐ chip shows only starred
// ones (combined with the selected category). Run on the Drift build and the
// API build (USE_API_WRITES) at desktop and phone width. Harness mirrors
// checkout_clear_cart_test.dart.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/utils/money.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/favorites_repository.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
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

  final stars = find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('fav-star-'),
  );
  List<String> starIds(WidgetTester tester) => tester
      .widgetList(stars)
      .map((w) => (w.key! as ValueKey<String>).value.substring(9))
      .toList();

  const hint = 'แตะ ☆ บนการ์ดสินค้าเพื่อเพิ่มเป็นสินค้าโปรด';
  final favChip = find.byKey(const Key('pos-favorites-chip'));

  /// Pumps the sell screen on a fresh DB (after [setup]) and runs [body].
  Future<void> run(
    WidgetTester tester,
    Size size,
    Future<void> Function(
      AppDatabase db,
      CartCubit cart,
      List<ProductRow> products,
    )
    body, {
    bool useApi = false,
    Future<void> Function(AppDatabase db)? setup,
  }) async {
    tester.view.physicalSize = size;
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
      await setup?.call(db);
      final products = await ProductsRepository(db).getAll();
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db, useApi: useApi),
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
      await body(db, cart, products);
      // No overflow or other framework error anywhere in the flow.
      expect(tester.takeException(), isNull);
    });
  }

  for (final useApi in const [false, true]) {
    for (final size in const [Size(1280, 800), Size(390, 844)]) {
      final tag = '${useApi ? 'API' : 'Drift'} ${size.width.toInt()}px';

      testWidgets('star toggles favorite, sorts first, ⭐ chip filters ($tag)', (
        tester,
      ) async {
        await run(tester, size, useApi: useApi, (db, cart, products) async {
          // ⭐ with nothing starred yet → the how-to hint.
          await tester.tap(favChip);
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          expect(stars, findsNothing);
          expect(find.text(hint), findsOneWidget);
          await tester.tap(favChip);
          await tester.pumpAndSettle(const Duration(milliseconds: 100));

          // Grid starts in product order; pick one that is not first.
          final ids = starIds(tester);
          expect(ids.length, greaterThanOrEqualTo(2));
          final target = products.firstWhere((p) => p.id == ids[1]);

          // Tap its star: favorite saved, nothing added to the cart.
          await tester.tap(find.byKey(Key('fav-star-${target.id}')));
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          expect(cart.state, isEmpty);
          expect(await FavoritesRepository(db).getFavorites(), {target.id});
          expect(starIds(tester).first, target.id);
          final icon = find.descendant(
            of: find.byKey(Key('fav-star-${target.id}')),
            matching: find.byIcon(Icons.star),
          );
          expect(icon, findsOneWidget);

          // ⭐ chip: only the starred product shows.
          await tester.tap(favChip);
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          expect(starIds(tester), [target.id]);

          // ⭐ + another category with no starred product → the plain
          // "not found" text (favorites exist, so no how-to hint).
          final other = products
              .map((p) => p.category)
              .firstWhere((c) => c != target.category);
          final otherChip = find.text(other).first;
          await tester.ensureVisible(otherChip);
          await tester.tap(otherChip);
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          expect(stars, findsNothing);
          expect(find.text('ไม่พบสินค้า'), findsOneWidget);
          expect(find.text(hint), findsNothing);

          // ⭐ off, ทั้งหมด: tapping the card body still adds to the cart.
          // (At phone width the chip row has scrolled; scroll it back.)
          final chipRow = find
              .ancestor(
                of: find.text(other).first,
                matching: find.byType(Scrollable),
              )
              .first;
          await tester.drag(chipRow, const Offset(2000, 0));
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          await tester.tap(favChip);
          await tester.tap(find.text('ทั้งหมด'));
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          if (target.stock > 0) {
            await tester.tap(find.text(target.name).first);
            await tester.pumpAndSettle(const Duration(milliseconds: 100));
            expect(cart.state.map((l) => l.productId), [target.id]);
          }

          // Unstar: back to the original order.
          await tester.tap(find.byKey(Key('fav-star-${target.id}')));
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          expect(await FavoritesRepository(db).getFavorites(), isEmpty);
          expect(starIds(tester).take(2), ids.take(2));
        });
      });
    }
  }

  // Edits the first product before the screen loads; returns it.
  Future<ProductRow> editFirst(AppDatabase db, ProductsCompanion patch) async {
    final first = (await ProductsRepository(db).getAll()).first;
    await (db.update(
      db.products,
    )..where((t) => t.id.equals(first.id))).write(patch);
    return first;
  }

  testWidgets('390px: the star sits on the picture and takes no width from a 99,999 price', (
    tester,
  ) async {
    late ProductRow first;
    await run(
      tester,
      const Size(390, 844),
      setup: (db) async => first = await editFirst(
        db,
        const ProductsCompanion(price: Value(99999)),
      ),
      (db, cart, products) async {
        final price = find.text(baht(99999));
        expect(price, findsOneWidget);
        // Since the picture card (owner 2026-10-10) the price has a line of
        // its own: it may use the card's whole text width (card − 2 × 10 px
        // padding), and no star or count shares that line.
        final card = tester.getRect(
          find.byKey(Key('pos-card-image-${first.id}')),
        );
        expect(
          tester.renderObject<RenderParagraph>(price).constraints.maxWidth,
          closeTo(card.width - 20, 0.5),
        );
        // The 40 px star is on the picture, never over the card's text.
        final star = tester.getRect(find.byKey(Key('fav-star-${first.id}')));
        expect(card.contains(star.topLeft) && card.contains(star.bottomRight - const Offset(1, 1)),
            isTrue);
        final partNo = tester.getRect(find.text(first.partNo).first);
        expect(star.bottom, lessThanOrEqualTo(partNo.top));
        expect(star.width, greaterThanOrEqualTo(40));
        expect(star.height, greaterThanOrEqualTo(40));
      },
    );
  });

  testWidgets('sold-out card: star works, card body adds nothing', (
    tester,
  ) async {
    late ProductRow first;
    await run(
      tester,
      const Size(390, 844),
      setup: (db) async =>
          first = await editFirst(db, const ProductsCompanion(stock: Value(0))),
      (db, cart, products) async {
        await tester.tap(find.byKey(Key('fav-star-${first.id}')));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(await FavoritesRepository(db).getFavorites(), {first.id});
        // The out-of-stock overlay takes this tap; the cart stays empty.
        await tester.tap(find.text(first.name).first, warnIfMissed: false);
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(cart.state, isEmpty);
      },
    );
  });
}
