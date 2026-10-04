// Checkout bill discount in percent mode (owner request 2026-10-04): the
// ฿/% toggle is UI only — the bill still carries a baht discount, derived as
// round2(subtotal × % / 100) and recomputed when the cart changes. Harness
// mirrors checkout_money_input_test.dart.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/checkout_screen.dart';

CartLine _line(String id, double price, {int qty = 1}) => CartLine(
  productId: id,
  name: id,
  price: price,
  originalPrice: price,
  cost: 0,
  qty: qty,
);

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // Pumps CheckoutScreen with [lines] in the cart, runs [body], then drops the
  // pre-existing product-grid overflow exception.
  Future<void> withCheckout(
    WidgetTester tester,
    List<CartLine> lines,
    Future<void> Function(CartCubit cart) body,
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
      cart.setLines(lines);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await body(cart);
      tester.takeException();
    });
  }

  final field = find.widgetWithText(TextField, '0');
  String fieldText(WidgetTester t) =>
      t.widget<TextField>(field).controller!.text;
  String? pctBaht(WidgetTester t) {
    final f = find.byKey(const Key('discountPctBaht'));
    return f.evaluate().isEmpty ? null : t.widget<Text>(f).data;
  }

  Future<void> tapMode(WidgetTester t, String label) async {
    await t.tap(
      find.descendant(
        of: find.byKey(const Key('discountModeToggle')),
        matching: find.text(label),
      ),
    );
    await t.pumpAndSettle(const Duration(milliseconds: 100));
  }

  Future<void> type(WidgetTester t, String v) async {
    await t.enterText(field, v);
    await t.pump();
  }

  testWidgets('10% of ฿100 → ฿10 discount, total ฿90', (tester) async {
    await withCheckout(tester, [_line('a', 100)], (_) async {
      expect(pctBaht(tester), isNull); // ฿ mode by default
      await tapMode(tester, '%');
      await type(tester, '10');
      expect(pctBaht(tester), '= ฿10');
      expect(find.text('฿90'), findsWidgets);
    });
  });

  testWidgets('switching modes: ฿→% starts empty, %→฿ keeps the amount', (
    tester,
  ) async {
    await withCheckout(tester, [_line('a', 100)], (_) async {
      await type(tester, '25');
      expect(find.text('฿75'), findsWidgets);
      await tapMode(tester, '%');
      expect(fieldText(tester), '');
      expect(pctBaht(tester), '= ฿0');
      expect(find.text('฿100'), findsWidgets);
      await type(tester, '12.5');
      expect(pctBaht(tester), '= ฿12.5');
      await tapMode(tester, '฿');
      expect(pctBaht(tester), isNull);
      expect(fieldText(tester), '12.5');
      expect(find.text('฿87.5'), findsWidgets);
    });
  });

  testWidgets('a percent above 100 is refused', (tester) async {
    await withCheckout(tester, [_line('a', 100)], (_) async {
      await tapMode(tester, '%');
      await type(tester, '50');
      await type(tester, '150');
      expect(fieldText(tester), '50');
      await type(tester, '100.5');
      expect(fieldText(tester), '50');
      await type(tester, '100');
      expect(fieldText(tester), '100');
      expect(pctBaht(tester), '= ฿100');
      await type(tester, '1.234'); // still max 2 decimals
      expect(fieldText(tester), '100');
    });
  });

  testWidgets('percent discount rounds to satang', (tester) async {
    await withCheckout(tester, [_line('a', 99.99)], (_) async {
      await tapMode(tester, '%');
      await type(tester, '10'); // 9.999 → 10.00
      expect(pctBaht(tester), '= ฿10');
      expect(find.text('฿89.99'), findsWidgets);
      await type(tester, '3.33'); // 3.329667 → 3.33
      expect(pctBaht(tester), '= ฿3.33');
      expect(find.text('฿96.66'), findsWidgets);
    });
  });

  testWidgets('a subtotal change in % mode recomputes the discount', (
    tester,
  ) async {
    await withCheckout(tester, [_line('a', 100)], (cart) async {
      await tapMode(tester, '%');
      await type(tester, '10');
      expect(pctBaht(tester), '= ฿10');
      cart.setLines([_line('a', 100, qty: 2), _line('b', 50)]);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(pctBaht(tester), '= ฿25');
      expect(find.text('฿225'), findsWidgets);
      expect(fieldText(tester), '10'); // the percent itself is unchanged
    });
  });
}
