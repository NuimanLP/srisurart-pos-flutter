// Checkout UX polish (2026-10-11 audit, docs/research/ui-ux-audit-2026-10-11/
// B-checkout.md): presentation only — these check what the counter now SEES,
// and that each new control goes through the same CartCubit calls as before.

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/core/utils/money.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/checkout_screen.dart';
import 'package:srisurart_pos/presentation/widgets/low_stock_alert.dart';
import 'package:srisurart_pos/presentation/widgets/ui_zoom.dart';

/// Counts `saveSale` calls; each call waits on [gate] (when set), then refuses
/// — the screen's own catch shows an alert, a quiet place for a test to stop.
class _CountingSales extends SalesRepository {
  _CountingSales(super.db);

  int calls = 0;
  Completer<void>? gate;

  @override
  Future<SaleRow> saveSale(SaleInput input) async {
    calls++;
    if (gate != null) await gate!.future;
    throw Exception('test stops here');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
    // The once-a-session low-stock banner would push the grid off a phone.
    lowStockShownThisSession = true;
  });

  Future<void> run(
    WidgetTester tester,
    Size size,
    Future<void> Function(CartCubit cart, List<ProductRow> products) body, {
    Future<void> Function(AppDatabase db)? setup,
    double zoom = 1.0,
    SalesRepository Function(AppDatabase db)? sales,
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
      if (setup != null) await setup(db);
      final products = await ProductsRepository(db).getAll();
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            ...repositoryProviders(db),
            if (sales != null)
              RepositoryProvider<SalesRepository>.value(value: sales(db)),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<PendingQuoteCubit>.value(value: pq),
              BlocProvider<CartCubit>.value(value: cart),
            ],
            child: MaterialApp(
              home: const Scaffold(body: CheckoutScreen()),
              builder: (context, child) => UiZoom(zoom: zoom, child: child!),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await body(cart, products);
    });
  }

  Future<void> settle(WidgetTester tester) =>
      tester.pumpAndSettle(const Duration(milliseconds: 100));

  const phone = Size(390, 844);
  const desktop = Size(1366, 900);

  testWidgets('390px: a card tap shows on the card, the tab and a cart bar '
      'that opens the cart', (tester) async {
    await run(tester, phone, (cart, products) async {
      final p = products.firstWhere((x) => x.stock > 1);
      expect(find.byKey(const Key('phone-cart-bar')), findsNothing);
      expect(find.byKey(const Key('cart-tab-count')), findsNothing);

      final card = find.byKey(Key('pos-card-image-${p.id}'));
      await tester.tap(card);
      await settle(tester);
      await tester.tap(card);
      await settle(tester);
      expect(cart.state.single.qty, 2);

      expect(find.byKey(Key('pos-card-in-cart-${p.id}')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('cart-tab-count')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
      final bar = find.byKey(const Key('phone-cart-bar'));
      expect(bar, findsOneWidget);
      expect(tester.getRect(bar).bottom, lessThanOrEqualTo(phone.height));
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('phone-cart-bar-open')));
      await settle(tester);
      // The cart tab is up: its pay button is on screen.
      final pay = find.textContaining('ชำระเงิน  ฿');
      expect(pay, findsOneWidget);
      expect(tester.getRect(pay).bottom, lessThanOrEqualTo(phone.height));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('390px: a stock refusal from a card tap is shown on the '
      'products tab, not only in the hidden cart', (tester) async {
    late ProductRow first;
    await run(
      tester,
      phone,
      setup: (db) async {
        first = (await ProductsRepository(db).getAll()).first;
        await (db.update(db.products)..where((t) => t.id.equals(first.id)))
            .write(const ProductsCompanion(stock: Value(1)));
      },
      (cart, products) async {
        // The card's picture (its name is also in the low-stock banner).
        final card = find.byKey(Key('pos-card-image-${first.id}'));
        await tester.tap(card);
        await settle(tester);
        expect(find.byKey(const Key('checkout-warning')), findsNothing);
        await tester.tap(card); // over stock
        await settle(tester);
        expect(cart.state.single.qty, 1);
        expect(find.byKey(const Key('checkout-warning')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  testWidgets('tap the cart qty to type it: goes through setQty (stock '
      'checked), 0 removes the line', (tester) async {
    await run(tester, desktop, (cart, products) async {
      final p = products.firstWhere((x) => x.stock >= 3);
      cart.add(p);
      await settle(tester);

      await tester.tap(find.byKey(Key('cart-qty-${p.id}')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('cart-qty-input')), '3');
      await tester.tap(find.text('ตกลง'));
      await settle(tester);
      expect(cart.state.single.qty, 3);

      // Over stock: refused by the cubit, qty unchanged, warning shown.
      await tester.tap(find.byKey(Key('cart-qty-${p.id}')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('cart-qty-input')),
        '${p.stock + 1}',
      );
      await tester.tap(find.text('ตกลง'));
      await settle(tester);
      expect(cart.state.single.qty, 3);
      expect(find.byKey(const Key('checkout-warning')), findsOneWidget);

      // Cancel changes nothing.
      await tester.tap(find.byKey(Key('cart-qty-${p.id}')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('cart-qty-input')), '1');
      await tester.tap(find.text('ยกเลิก'));
      await settle(tester);
      expect(cart.state.single.qty, 3);

      await tester.tap(find.byKey(Key('cart-qty-${p.id}')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('cart-qty-input')), '0');
      await tester.tap(find.text('ตกลง'));
      await settle(tester);
      expect(cart.state, isEmpty);
    });
  });

  testWidgets(
    'cash: short shows "ยังขาด" and the amount, enough shows change',
    (tester) async {
      await run(tester, desktop, (cart, products) async {
        final p = products.firstWhere((x) => x.stock > 0 && x.price > 1);
        cart.add(p);
        await settle(tester);
        final cash = find.widgetWithText(TextField, 'รับเงิน ฿…');

        await tester.enterText(cash, '1');
        await settle(tester);
        expect(find.byKey(const Key('cash-short')), findsOneWidget);
        expect(find.text('ยังขาด'), findsOneWidget);

        await tester.enterText(cash, '${p.price.ceil() + 100}');
        await settle(tester);
        expect(find.byKey(const Key('cash-short')), findsNothing);
        expect(find.byKey(const Key('cash-change')), findsOneWidget);
      });
    },
  );

  testWidgets('two-pane: the scan field keeps focus after Enter, so the next '
      'scan lands; F2 brings focus back', (tester) async {
    await run(tester, desktop, (cart, products) async {
      final p = products.firstWhere((x) => x.stock > 1);
      final scan = find.widgetWithText(TextField, 'สแกนบาร์โค้ด / รหัสอะไหล่');
      await tester.tap(scan);
      await tester.enterText(scan, p.partNo);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(cart.state.single.qty, 1);

      FocusNode focusOf() => tester
          .widget<EditableText>(
            find.descendant(of: scan, matching: find.byType(EditableText)),
          )
          .focusNode;
      expect(focusOf().hasFocus, isTrue);

      // Elsewhere, then F2.
      await tester.tap(find.widgetWithText(TextField, 'รับเงิน ฿…'));
      await settle(tester);
      expect(focusOf().hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await settle(tester);
      expect(focusOf().hasFocus, isTrue);
    });
  });

  // Whole-screen zoom on a 1366x768 laptop at 3x: the phone layout on a
  // ~455x256 logical screen, with an item, its refusal and the cart bar up.
  testWidgets('3x zoom laptop: warning on the products tab, no cart bar on '
      'so short a screen, no overflow', (tester) async {
    await run(
      tester,
      const Size(1366, 768),
      zoom: 3.0,
      setup: (db) async {
        final first = (await ProductsRepository(db).getAll()).first;
        await (db.update(db.products)..where((t) => t.id.equals(first.id)))
            .write(const ProductsCompanion(stock: Value(1)));
      },
      (cart, products) async {
        final p = products.first;
        // Only the top of the card shows above the fold here.
        final card = find.byKey(Key('pos-card-image-${p.id}'));
        Future<void> tapCard() async {
          await tester.tapAt(tester.getTopLeft(card) + const Offset(20, 6));
          await settle(tester);
        }

        await tapCard();
        await tapCard(); // over stock
        expect(cart.state.single.qty, 1);
        expect(find.byKey(const Key('checkout-warning')), findsOneWidget);
        expect(find.byKey(const Key('cart-tab-count')), findsOneWidget);
        expect(find.byKey(const Key('phone-cart-bar')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('F9 pays only when a click on the pay button would', () {
    late _CountingSales sales;
    SalesRepository makeSales(AppDatabase db) => sales = _CountingSales(db);

    Future<void> enterCash(WidgetTester tester) async {
      await tester.enterText(
        find.widgetWithText(TextField, 'รับเงิน ฿…'),
        '1000000',
      );
      await settle(tester);
    }

    Future<void> dismissAlert(WidgetTester tester) async {
      if (find.text('ตกลง').evaluate().isNotEmpty) {
        await tester.tap(find.text('ตกลง'));
        await settle(tester);
      }
    }

    testWidgets('empty cart: nothing', (tester) async {
      await run(tester, desktop, sales: makeSales, (cart, products) async {
        await tester.sendKeyEvent(LogicalKeyboardKey.f9);
        await settle(tester);
        expect(sales.calls, 0);
        expect(find.byType(AlertDialog), findsNothing);
      });
    });

    testWidgets('with items: one sale, through the same handler', (
      tester,
    ) async {
      await run(tester, desktop, sales: makeSales, (cart, products) async {
        cart.add(products.firstWhere((x) => x.stock > 0));
        await settle(tester);
        await enterCash(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.f9);
        await settle(tester);
        expect(sales.calls, 1);
        await dismissAlert(tester);
      });
    });

    testWidgets('while a sale is in flight: no second sale', (tester) async {
      await run(tester, desktop, sales: makeSales, (cart, products) async {
        cart.add(products.firstWhere((x) => x.stock > 0));
        await settle(tester);
        await enterCash(tester);
        sales.gate = Completer<void>();
        await tester.sendKeyEvent(LogicalKeyboardKey.f9);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.f9);
        await tester.pump();
        expect(sales.calls, 1);
        sales.gate!.complete();
        await settle(tester);
        expect(sales.calls, 1);
        await dismissAlert(tester);
      });
    });

    testWidgets('with a line price being edited: no sale (a click would '
        'commit the edit first, a key would not)', (tester) async {
      await run(tester, desktop, sales: makeSales, (cart, products) async {
        final p = products.firstWhere((x) => x.stock > 0);
        cart.add(p);
        await settle(tester);
        await enterCash(tester);
        // The price button is live only with a mechanic attached.
        final mech = (await sales.db.select(sales.db.mechanics).get()).first;
        await tester.enterText(
          find.widgetWithText(TextField, 'ค้นหาช่าง / ชื่อเล่น / เบอร์…'),
          mech.nameTH ?? mech.name,
        );
        await settle(tester);
        await tester.tap(find.text(mech.nameTH ?? mech.name).last);
        await settle(tester);
        final priceButton = find.widgetWithText(OutlinedButton, baht(p.price));
        await tester.tap(priceButton);
        await settle(tester);
        expect(priceButton, findsNothing); // the edit field is open

        await tester.sendKeyEvent(LogicalKeyboardKey.f9);
        await settle(tester);
        expect(sales.calls, 0);
      });
    });
  });

  testWidgets('a scan while a sale is in flight stays in the field, not added '
      'to a cart about to be cleared', (tester) async {
    late _CountingSales sales;
    await run(tester, desktop, sales: (db) => sales = _CountingSales(db), (
      cart,
      products,
    ) async {
      final p = products.firstWhere((x) => x.stock > 1);
      final other = products.firstWhere((x) => x.stock > 0 && x.id != p.id);
      cart.add(p);
      await settle(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'รับเงิน ฿…'),
        '1000000',
      );
      await settle(tester);
      sales.gate = Completer<void>();
      await tester.sendKeyEvent(LogicalKeyboardKey.f9);
      await tester.pump();
      expect(sales.calls, 1);

      final scan = find.widgetWithText(TextField, 'สแกนบาร์โค้ด / รหัสอะไหล่');
      await tester.enterText(scan, other.partNo);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(cart.state.map((l) => l.productId), [p.id]);
      expect(tester.widget<TextField>(scan).controller!.text, other.partNo);

      sales.gate!.complete();
      await settle(tester);
      if (find.text('ตกลง').evaluate().isNotEmpty) {
        await tester.tap(find.text('ตกลง'));
        await settle(tester);
      }
    });
  });

  testWidgets('qty dialog selects the whole number, so typing replaces it '
      '(mobile does not select on focus by default)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await run(tester, phone, (cart, products) async {
        final p = products.firstWhere((x) => x.stock > 0);
        cart.add(p);
        await settle(tester);
        await tester.tap(find.text('ตะกร้า'));
        await settle(tester);
        await tester.tap(find.byKey(Key('cart-qty-${p.id}')));
        await settle(tester);
        final edit = tester.widget<EditableText>(
          find.descendant(
            of: find.byKey(const Key('cart-qty-input')),
            matching: find.byType(EditableText),
          ),
        );
        expect(edit.focusNode.hasFocus, isTrue);
        expect(
          edit.controller.selection,
          const TextSelection(baseOffset: 0, extentOffset: 1),
        );
        await tester.tap(find.text('ยกเลิก'));
        await settle(tester);
      });
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
