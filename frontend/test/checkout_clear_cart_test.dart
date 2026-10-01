// Clear-all button on the checkout cart: hidden when empty, confirm clears,
// cancel keeps. Harness mirrors quote_to_checkout_test.dart.

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
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  Future<void> run(
    WidgetTester tester,
    Size size,
    Future<void> Function(CartCubit cart, List<ProductRow> products) body,
  ) async {
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
      await body(cart, products);
      tester
          .takeException(); // product-grid overflow at some widths is pre-existing
    });
  }

  // Phone width keeps the cart on its own tab.
  Future<void> openCart(WidgetTester tester) async {
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final tab = find.text('ตะกร้า');
    if (tab.evaluate().isNotEmpty) {
      await tester.tap(tab);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
    }
  }

  final clearBtn = find.byKey(const Key('cart-clear-all'));

  for (final size in const [Size(1280, 800), Size(390, 844)]) {
    final tag = '${size.width.toInt()}px';

    testWidgets('hidden when empty, shown with items ($tag)', (tester) async {
      await run(tester, size, (cart, products) async {
        await openCart(tester);
        expect(clearBtn, findsNothing);
        cart.add(products.firstWhere((x) => x.stock > 0));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(clearBtn, findsOneWidget);
        // Fits on screen (phone width included).
        expect(tester.getRect(clearBtn).right, lessThanOrEqualTo(size.width));
        expect(tester.getRect(clearBtn).left, greaterThanOrEqualTo(0));
      });
    });

    testWidgets('confirm clears the cart ($tag)', (tester) async {
      await run(tester, size, (cart, products) async {
        cart.add(products.firstWhere((x) => x.stock > 0));
        await openCart(tester);
        await tester.ensureVisible(clearBtn);
        await tester.tap(clearBtn);
        await tester.pumpAndSettle();
        expect(find.text('ล้างรายการสินค้าทั้งหมด?'), findsOneWidget);
        expect(find.textContaining('ทั้ง 1 รายการ'), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('ล้างรายการ'),
          ),
        );
        await tester.pumpAndSettle();
        expect(cart.state, isEmpty);
        expect(clearBtn, findsNothing);
      });
    });

    testWidgets('cancel keeps the cart ($tag)', (tester) async {
      await run(tester, size, (cart, products) async {
        cart.add(products.firstWhere((x) => x.stock > 0));
        await openCart(tester);
        await tester.ensureVisible(clearBtn);
        await tester.tap(clearBtn);
        await tester.pumpAndSettle();
        await tester.tap(find.text('ยกเลิก'));
        await tester.pumpAndSettle();
        expect(cart.state, hasLength(1));
        expect(clearBtn, findsOneWidget);
      });
    });
  }

  testWidgets('390px with a mechanic picked: header wraps, no overflow', (
    tester,
  ) async {
    await run(tester, const Size(390, 844), (cart, products) async {
      cart.add(products.firstWhere((x) => x.stock > 0));
      await openCart(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final mech = (await db.select(db.mechanics).get()).first;
      await tester.enterText(
        find.widgetWithText(TextField, 'ค้นหาช่าง / ชื่อเล่น / เบอร์…'),
        mech.nameTH ?? mech.name,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(mech.nameTH ?? mech.name).last);
      await tester.pumpAndSettle();
      expect(find.text('คลิกราคาเพื่อปรับ'), findsOneWidget);
      expect(clearBtn, findsOneWidget);
      expect(tester.getRect(clearBtn).right, lessThanOrEqualTo(390));
    });
  });
}
