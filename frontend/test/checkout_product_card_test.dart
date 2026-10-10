// Sell-screen picture card (owner sample 2026-10-10, contract §5): picture on
// top (placeholder without one), ⭐ and category badge on the picture, a
// preview button that opens `_p.webp` and never adds to the cart, the
// out-of-stock veil, and no overflow at 390 / 1280 px in light and dark.
// Harness mirrors checkout_favorites_test.dart (API read repositories; the
// image requests hit flutter_test's mock HttpClient, fail, and fall back to
// the placeholder — which is what a card does on a lost picture).

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/theme/app_theme.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/favorites_repository.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/services/tenant_cache_guard.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/checkout_screen.dart';
import 'package:srisurart_pos/presentation/widgets/low_stock_alert.dart';

const _tenant = '0199c3a0-1111-7abc-8def-0123456789ab';
const _key = 'aaaaaaaabbbbbbbbccccccccdddddddd';
const _base = 'https://shop.test';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
    // The once-per-session low-stock banner lists the sold-out product by
    // name; it is not what these tests measure.
    lowStockShownThisSession = true;
  });

  final placeholder = find.byKey(const Key('product-image-placeholder'));

  /// Pumps the sell screen. [withImage]: the first product gets [_key] and
  /// the shop's tenant is known (as after an API-build login).
  Future<void> run(
    WidgetTester tester,
    Size size,
    Future<void> Function(AppDatabase db, CartCubit cart, ProductRow first) body, {
    bool withImage = true,
    bool soldOut = false,
    bool dark = false,
    String? longName,
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
      final first = (await ProductsRepository(db).getAll()).first;
      await (db.update(db.products)..where((t) => t.id.equals(first.id))).write(
        ProductsCompanion(
          imageKey: Value(withImage ? _key : null),
          stock: soldOut ? const Value(0) : const Value.absent(),
          name: longName == null ? const Value.absent() : Value(longName),
          nameTH: longName == null ? const Value.absent() : Value(longName),
        ),
      );
      if (withImage) {
        await db.into(db.appMeta).insert(AppMetaCompanion.insert(
              key: TenantCacheGuard.tenantKey,
              value: _tenant,
            ));
      }
      final row = await (db.select(db.products)
            ..where((t) => t.id.equals(first.id)))
          .getSingle();
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db, apiClient: ApiClient(baseUrl: _base)),
          child: MultiBlocProvider(
            providers: [
              BlocProvider<PendingQuoteCubit>.value(value: pq),
              BlocProvider<CartCubit>.value(value: cart),
            ],
            child: MaterialApp(
              theme: dark ? AppTheme.dark : AppTheme.light,
              home: const Scaffold(body: CheckoutScreen()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await body(db, cart, row);
      expect(tester.takeException(), isNull);
    });
  }

  String? networkUrl(WidgetTester tester, Finder within) {
    final images = find.descendant(of: within, matching: find.byType(Image));
    if (images.evaluate().isEmpty) return null;
    var provider = tester.widget<Image>(images.first).image;
    if (provider is ResizeImage) provider = provider.imageProvider;
    return (provider as NetworkImage).url;
  }

  for (final size in const [Size(390, 844), Size(1280, 800)]) {
    for (final dark in const [false, true]) {
      final tag = '${size.width.toInt()}px ${dark ? 'dark' : 'light'}';
      testWidgets('no overflow: picture + long names + sold-out veil ($tag)', (
        tester,
      ) async {
        await run(
          tester,
          size,
          dark: dark,
          soldOut: true,
          longName: 'ผ้าเบรกหน้า เกรดพรีเมียม สำหรับรถกระบะ ทุกรุ่น ทุกปี ' * 3,
          (db, cart, first) async {
            final card = tester.getRect(
              find.byKey(Key('pos-card-image-${first.id}')),
            );
            expect(card.height, posCardImageHeight);
            expect(find.text('สินค้าหมด'), findsWidgets);
            // Overflow would have been reported as an exception (checked by run).
          },
        );
      });
    }
  }

  testWidgets('the thumbnail URL is /img/<tenant>/<key>_t.webp; preview shows _p.webp and adds nothing',
      (tester) async {
    await run(tester, const Size(1280, 800), (db, cart, first) async {
      final cardImage = find.byKey(Key('pos-card-image-${first.id}'));
      expect(networkUrl(tester, cardImage), '$_base/img/$_tenant/${_key}_t.webp');

      final preview = find.byKey(Key('pos-image-preview-${first.id}'));
      final pr = tester.getRect(preview);
      expect(pr.width, greaterThanOrEqualTo(40));
      expect(pr.height, greaterThanOrEqualTo(40));
      expect(tester.getRect(cardImage).contains(pr.center), isTrue);

      await tester.tap(preview);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(cart.state, isEmpty);
      final dialog = find.byType(Dialog);
      expect(dialog, findsOneWidget);
      expect(networkUrl(tester, find.byKey(const Key('pos-image-preview'))),
          '$_base/img/$_tenant/${_key}_p.webp');
      expect(find.descendant(of: dialog, matching: find.text(first.name)),
          findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text(first.partNo)),
          findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.byType(InteractiveViewer)),
          findsOneWidget);
      await tester.tap(find.text('ปิด'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(dialog, findsNothing);
      expect(cart.state, isEmpty);

      // The card body still adds to the cart.
      await tester.tap(find.text(first.name).first);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(cart.state.map((l) => l.productId), [first.id]);
    });
  });

  testWidgets('a lost picture shows the placeholder, never an error', (tester) async {
    await run(tester, const Size(1280, 800), (db, cart, first) async {
      // flutter_test's HttpClient answers every request with an error.
      final cardImage = find.byKey(Key('pos-card-image-${first.id}'));
      expect(find.descendant(of: cardImage, matching: placeholder), findsOneWidget);
    });
  });

  testWidgets('no image (or the Drift build): placeholder, no request, no preview button',
      (tester) async {
    await run(tester, const Size(390, 844), withImage: false, (db, cart, first) async {
      final cardImage = find.byKey(Key('pos-card-image-${first.id}'));
      expect(find.descendant(of: cardImage, matching: placeholder), findsOneWidget);
      expect(find.descendant(of: cardImage, matching: find.byType(Image)), findsNothing);
      expect(find.byKey(Key('pos-image-preview-${first.id}')), findsNothing);
    });
  });

  testWidgets('sold-out picture card: star still toggles over the veil, card adds nothing',
      (tester) async {
    await run(tester, const Size(390, 844), soldOut: true, (db, cart, first) async {
      final star = find.byKey(Key('fav-star-${first.id}'));
      final sr = tester.getRect(star);
      expect(sr.width, greaterThanOrEqualTo(40));
      expect(tester.getRect(find.byKey(Key('pos-card-image-${first.id}'))).contains(sr.center),
          isTrue);
      await tester.tap(star);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(await FavoritesRepository(db).getFavorites(), {first.id});
      expect(cart.state, isEmpty);
      await tester.tap(find.text(first.name).first, warnIfMissed: false);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(cart.state, isEmpty);
    });
  });
}
