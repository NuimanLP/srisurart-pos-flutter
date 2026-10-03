// #476 — a session that is not a `pos` device (no device token, e.g. after
// the browser's site data was cleared, or a backoffice device) used to learn
// that only from failed presses: "กรุณาเปิดกะก่อนขาย" on a sale, then
// "เครื่องนี้ขายของไม่ได้" on opening the shift, with no next step.
//
// Covers: AuthCubit takes the session's role from the refresh token's `drole`
// (no fallback to a remembered role); the banner shows for a non-pos session
// only and links to /devices; the checkout says the device reason before the
// shift one; the server's DEVICE_ROLE_FORBIDDEN maps to the same sentence; the
// pay button stays pinned and on screen at 1568×703 after cash is entered.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/data/repositories/shifts_repository.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';
import 'package:srisurart_pos/presentation/blocs/auth_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/cash_drawer_screen.dart';
import 'package:srisurart_pos/presentation/screens/checkout_screen.dart';
import 'package:srisurart_pos/presentation/widgets/device_role_banner.dart';

class _NoStorage implements TokenStorage {
  @override
  Future<void> clearAll() async {}
  @override
  Future<void> clearAuthTokens() async {}
  @override
  Future<String?> getAccessToken() async => null;
  @override
  Future<String?> getDeviceToken() async => null;
  @override
  Future<String?> getRefreshToken() async => null;
  @override
  Future<AuthUser?> getUser() async => null;
  @override
  Future<void> setAccessToken(String? token) async {}
  @override
  Future<void> setDeviceToken(String? token) async {}
  @override
  Future<void> setRefreshToken(String? token) async {}
  @override
  Future<void> setUser(AuthUser? user) async {}
}

/// A signed-in session whose refresh token carries [sessionRole] as `drole`,
/// while [rememberedRole] is what an earlier login left behind.
class _SignedInRepo extends AuthRepository {
  _SignedInRepo({
    this.sessionRole,
    this.rememberedRole,
    this.storeFails = false,
  }) : super(
         apiClient: ApiClient(tokenStorage: _NoStorage()),
         tokenStorage: _NoStorage(),
       );

  final String? sessionRole;
  final String? rememberedRole;
  final bool storeFails;

  @override
  Future<String?> sessionDeviceRole() async {
    if (storeFails) throw const TokenStoreUnavailableException();
    return sessionRole;
  }

  @override
  Future<String?> getDeviceRole() async => rememberedRole;
  @override
  Future<String?> getDeviceToken() async => null;
  @override
  Future<String?> sessionDeviceId() async => null;
  @override
  Future<bool> isAuthenticated() async => true;
  @override
  Future<AuthUser?> getCurrentUser() async =>
      const AuthUser(id: 'u-1', username: 'owner', role: 'owner');
}

/// The server's answer to `POST /shifts/open` from a non-pos session.
class _RefusingShifts extends ShiftsRepository {
  _RefusingShifts(super.db);

  int calls = 0;

  @override
  Future<ShiftRow> openShift(double startingCash, {String? id}) async {
    calls++;
    throw const PosException('DEVICE_ROLE_FORBIDDEN', 'เครื่องนี้ขายของไม่ได้');
  }
}

/// The server's answer to `POST /sales` from a non-pos session.
class _RefusingSales extends SalesRepository {
  _RefusingSales(super.db);

  @override
  Future<SaleRow> saveSale(SaleInput input) async => throw const PosException(
    'DEVICE_ROLE_FORBIDDEN',
    'เครื่องนี้ขายของไม่ได้',
  );
}

Future<AuthCubit> _signedIn({
  String? sessionRole,
  String? rememberedRole,
}) async {
  final cubit = AuthCubit(
    authRepository: _SignedInRepo(
      sessionRole: sessionRole,
      rememberedRole: rememberedRole,
    ),
  );
  await cubit.init();
  return cubit;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('AuthCubit session role', () {
    test('a session without drole is not a pos session, even when a past '
        'login remembered pos', () async {
      final cubit = await _signedIn(rememberedRole: 'pos');
      addTearDown(cubit.close);
      final s = cubit.state as Authenticated;
      expect(s.deviceRole, 'pos'); // the login chip's role, unchanged
      expect(s.isPosSession, isFalse);
    });

    test('a session signed for a pos device is a pos session', () async {
      final cubit = await _signedIn(sessionRole: 'pos');
      addTearDown(cubit.close);
      expect((cubit.state as Authenticated).isPosSession, isTrue);
    });

    test('an unreadable token store falls back to the remembered role, and '
        'does not fail the sign-in', () async {
      final cubit = AuthCubit(
        authRepository: _SignedInRepo(rememberedRole: 'pos', storeFails: true),
      );
      addTearDown(cubit.close);
      await cubit.init();
      expect((cubit.state as Authenticated).isPosSession, isTrue);
    });

    test('a backoffice device session is not a pos session', () async {
      final cubit = await _signedIn(sessionRole: 'backoffice');
      addTearDown(cubit.close);
      expect((cubit.state as Authenticated).isPosSession, isFalse);
    });
  });

  test('isDeviceRoleRefusal recognises the server 403 only', () {
    expect(
      isDeviceRoleRefusal(
        const PosException('DEVICE_ROLE_FORBIDDEN', 'เครื่องนี้ขายของไม่ได้'),
      ),
      isTrue,
    );
    expect(
      isDeviceRoleRefusal(
        const PosException('NO_OPEN_SHIFT', 'กรุณาเปิดกะก่อนขาย'),
      ),
      isFalse,
    );
    expect(isDeviceRoleRefusal(Exception('x')), isFalse);
  });

  group('NotPosDeviceBanner', () {
    Future<void> pumpBanner(WidgetTester tester, AuthCubit? cubit) {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: NotPosDeviceBanner()),
          ),
          GoRoute(
            path: '/devices',
            builder: (_, _) => const Scaffold(body: Text('DEVICES PAGE')),
          ),
        ],
      );
      addTearDown(router.dispose);
      final app = MaterialApp.router(routerConfig: router);
      return tester.pumpWidget(
        cubit == null
            ? app
            : BlocProvider<AuthCubit>.value(value: cubit, child: app),
      );
    }

    testWidgets('shows for a non-pos session and its button opens /devices', (
      tester,
    ) async {
      final cubit = await _signedIn();
      addTearDown(cubit.close);
      await pumpBanner(tester, cubit);
      await tester.pumpAndSettle();
      expect(find.text(notPosDeviceMessage), findsOneWidget);
      await tester.tap(find.text(goToDevicesLabel));
      await tester.pumpAndSettle();
      expect(find.text('DEVICES PAGE'), findsOneWidget);
    });

    testWidgets('absent for a pos session', (tester) async {
      final cubit = await _signedIn(sessionRole: 'pos');
      addTearDown(cubit.close);
      await pumpBanner(tester, cubit);
      await tester.pumpAndSettle();
      expect(find.text(notPosDeviceMessage), findsNothing);
    });

    testWidgets('absent when nobody is signed in (Drift-only build)', (
      tester,
    ) async {
      await pumpBanner(tester, null);
      await tester.pumpAndSettle();
      expect(find.text(notPosDeviceMessage), findsNothing);
    });
  });

  group('CheckoutScreen', () {
    Future<void> run(
      WidgetTester tester,
      Size size,
      AuthCubit? auth,
      Future<void> Function(AppDatabase db, CartCubit cart, List<ProductRow> p)
      body, {
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
                if (auth != null) BlocProvider<AuthCubit>.value(value: auth),
              ],
              child: const MaterialApp(home: Scaffold(body: CheckoutScreen())),
            ),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        await body(db, cart, products);
        tester
            .takeException(); // pre-existing product-grid overflow at some widths
      });
    }

    final payButton = find.textContaining('ชำระเงิน  ฿');

    testWidgets('non-pos session: banner up front, and paying names the '
        'device, not the shift', (tester) async {
      final auth = await _signedIn();
      addTearDown(auth.close);
      await run(tester, const Size(1568, 900), auth, (
        db,
        cart,
        products,
      ) async {
        expect(find.text(notPosDeviceMessage), findsOneWidget);
        cart.add(products.firstWhere((x) => x.stock > 0));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        await tester.enterText(
          find.widgetWithText(TextField, 'รับเงิน ฿…'),
          '100000',
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        await tester.tap(payButton);
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        final dialog = find.byType(AlertDialog);
        expect(dialog, findsOneWidget);
        expect(
          find.descendant(of: dialog, matching: find.text(notPosDeviceMessage)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: dialog, matching: find.text(goToDevicesLabel)),
          findsOneWidget,
        );
        expect(find.textContaining('กรุณาเปิดกะก่อนขาย'), findsNothing);
        // Nothing was rung.
        expect(await SalesRepository(db).getSales(), isEmpty);
      });
    });

    testWidgets('the server refusal on a sale opens the device dialog, not '
        '"ขายไม่สำเร็จ: เครื่องนี้ขายของไม่ได้"', (tester) async {
      await run(tester, const Size(1568, 900), null, (
        db,
        cart,
        products,
      ) async {
        cart.add(products.firstWhere((x) => x.stock > 0));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        await tester.enterText(
          find.widgetWithText(TextField, 'รับเงิน ฿…'),
          '100000',
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        await tester.tap(payButton);
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        final dialog = find.byType(AlertDialog);
        expect(
          find.descendant(of: dialog, matching: find.text(notPosDeviceMessage)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: dialog, matching: find.text(goToDevicesLabel)),
          findsOneWidget,
        );
        expect(find.textContaining('ขายไม่สำเร็จ'), findsNothing);
      }, sales: _RefusingSales.new);
    });

    testWidgets('390px: the pinned pay button is on screen in the cart tab', (
      tester,
    ) async {
      const size = Size(390, 844);
      await run(tester, size, null, (db, cart, products) async {
        cart.add(products.firstWhere((x) => x.stock > 0));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        await tester.tap(find.text('ตะกร้า'));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        final r = tester.getRect(payButton);
        expect(r.bottom, lessThanOrEqualTo(size.height));
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(size.width));
      });
    });

    testWidgets('pos session: no banner', (tester) async {
      final auth = await _signedIn(sessionRole: 'pos');
      addTearDown(auth.close);
      await run(tester, const Size(1568, 900), auth, (
        db,
        cart,
        products,
      ) async {
        expect(find.text(notPosDeviceMessage), findsNothing);
      });
    });

    testWidgets('1568×703: the pay button stays pinned and on screen after '
        'cash is entered', (tester) async {
      const size = Size(1568, 703);
      await run(tester, size, null, (db, cart, products) async {
        cart.add(products.firstWhere((x) => x.stock > 0));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        final before = tester.getRect(payButton);
        expect(before.bottom, lessThanOrEqualTo(size.height));
        // At this height the cash field sits below the fold of the panel's
        // list: scroll the LIST (the pay button must not move with it).
        final cashField = find.widgetWithText(TextField, 'รับเงิน ฿…');
        // The right-hand panel's (400 px wide) own list: the tallest
        // vertical Scrollable in that panel (the cart has a small inner one).
        Rect rectOf(Element e) =>
            tester.getRect(find.byElementPredicate((x) => x == e));
        final panelLists =
            find.byType(Scrollable).evaluate().where((e) {
                final w = e.widget as Scrollable;
                return w.axisDirection == AxisDirection.down &&
                    rectOf(e).left >= size.width - 402;
              }).toList()
              ..sort((a, b) => rectOf(b).height.compareTo(rectOf(a).height));
        // Jump rather than drag: a drag at the list's centre lands on the
        // cart's inner list.
        final position =
            ((panelLists.first as StatefulElement).state as ScrollableState)
                .position;
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(cashField, findsOneWidget);
        await tester.enterText(cashField, '100000');
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(find.text('เงินทอน'), findsOneWidget);
        final after = tester.getRect(payButton);
        expect(after, before);
        expect(after.bottom, lessThanOrEqualTo(size.height));
        // Not inside the panel's scrolling list.
        expect(
          find.ancestor(of: payButton, matching: find.byType(Scrollable)),
          findsNothing,
        );
      });
    });

    testWidgets('empty cart: no ฿0 quick-cash chip', (tester) async {
      await run(tester, const Size(1568, 900), null, (
        db,
        cart,
        products,
      ) async {
        // Totals rows also read ฿0; only a tappable chip is wrong.
        Finder chip(String label) =>
            find.ancestor(of: find.text(label), matching: find.byType(InkWell));
        expect(chip('฿0'), findsNothing);
        expect(chip('฿1,000'), findsWidgets);
      });
    });
  });

  group('CashDrawerScreen', () {
    Future<_RefusingShifts> pumpDrawer(
      WidgetTester tester,
      AuthCubit? auth,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final shifts = _RefusingShifts(db);
      final app = MultiRepositoryProvider(
        providers: [
          ...repositoryProviders(db),
          RepositoryProvider<ShiftsRepository>.value(value: shifts),
        ],
        child: const MaterialApp(home: Scaffold(body: CashDrawerScreen())),
      );
      await tester.pumpWidget(
        auth == null
            ? app
            : BlocProvider<AuthCubit>.value(value: auth, child: app),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      return shifts;
    }

    Future<void> openWith(WidgetTester tester, String amount) async {
      await tester.enterText(find.widgetWithText(TextField, '0'), amount);
      await tester.tap(find.text('เปิดร้าน'));
      await tester.pumpAndSettle();
    }

    final snack = find.byType(SnackBar);

    testWidgets('the server refusal on open-shift says what to do, with a '
        'button to /devices', (tester) async {
      await tester.runAsync(() async {
        final shifts = await pumpDrawer(tester, null);
        await openWith(tester, '1000');
        expect(shifts.calls, 1);
        expect(
          find.descendant(of: snack, matching: find.text(notPosDeviceMessage)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: snack, matching: find.text(goToDevicesLabel)),
          findsOneWidget,
        );
        expect(find.text('เครื่องนี้ขายของไม่ได้'), findsNothing);
      });
    });

    testWidgets('non-pos session: banner up front, open-shift refused before '
        'asking the server', (tester) async {
      final auth = await _signedIn();
      addTearDown(auth.close);
      await tester.runAsync(() async {
        final shifts = await pumpDrawer(tester, auth);
        expect(find.text(notPosDeviceMessage), findsOneWidget);
        await openWith(tester, '1000');
        expect(shifts.calls, 0);
        expect(
          find.descendant(of: snack, matching: find.text(notPosDeviceMessage)),
          findsOneWidget,
        );
      });
    });
  });
}
