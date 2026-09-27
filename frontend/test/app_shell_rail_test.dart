// #465 — two AppShell/NavigationRail bugs found rehearsing the local stack:
//
// (a) The rail overflows by ~4px at 1440x900. `_Rail` sized its
//     `ConstrainedBox(minHeight: ...)` from a hardcoded `MediaQuery.height - 68`
//     guess instead of the space its parent `Row` actually gives it, so the
//     guess didn't match reality once the topbar's real height (safe-area top
//     padding + its 3px bottom border) was accounted for.
// (b) `/devices` is reachable via go_router but isn't one of the 12
//     `_destinations`, so the old `_selectedIndex` fallback (`idx < 0 ? 0 :
//     idx`) highlighted "ขายสินค้า" (index 0) on a route that isn't even in
//     the menu.
//
// Harness mirrors login_redirect_test.dart: the real `SrisurartApp` (router +
// AppShell + screens) against an in-memory Drift DB, `requireLogin: false`
// (the Drift-only shop build) so no login flow is involved.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/app.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/router/app_router.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';
import 'package:srisurart_pos/presentation/blocs/auth_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/checkout_screen.dart';
import 'package:srisurart_pos/presentation/widgets/font_scale_controller.dart';
import 'package:srisurart_pos/presentation/widgets/theme_controller.dart';

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

class _StubAuthRepo extends AuthRepository {
  _StubAuthRepo()
    : super(
        apiClient: ApiClient(tokenStorage: _NoStorage()),
        tokenStorage: _NoStorage(),
      );

  @override
  Future<String?> getDeviceToken() async => 'dt-1';
  @override
  Future<String?> getDeviceRole() async => null;
  @override
  Future<AuthUser?> getCurrentUser() async => null;
  @override
  Future<bool> isAuthenticated() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  late AppDatabase db;
  late _StubAuthRepo repo;
  late AuthCubit cubit;

  Future<void> pumpApp(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    return tester.pumpWidget(
      MultiRepositoryProvider(
        providers: repositoryProviders(
          db,
          authRepository: repo,
          useApi: false,
          useApiRepositories: false,
        ),
        child: MultiBlocProvider(
          providers: [
            BlocProvider<ThemeModeCubit>(create: (_) => ThemeModeCubit()),
            BlocProvider<FontScaleCubit>(create: (_) => FontScaleCubit()),
            BlocProvider<PendingQuoteCubit>(create: (_) => PendingQuoteCubit()),
            BlocProvider<CartCubit>(create: (_) => CartCubit()),
            BlocProvider<AuthCubit>.value(value: cubit),
          ],
          child: SrisurartApp(requireLogin: false, themeOverride: ThemeData()),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = _StubAuthRepo();
    cubit = AuthCubit(authRepository: repo);
  });

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await cubit.close();
    await db.close();
  }

  testWidgets(
    'the rail lays out cleanly at 1440x900, no overflow (#465a)',
    (tester) async {
      await tester.runAsync(() async {
        await cubit.init();
        await pumpApp(tester, const Size(1440, 900));
        await settle(tester);

        expect(find.byType(CheckoutScreen), findsOneWidget);
        expect(find.byType(NavigationRail), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: 'NavigationRail overflowed at 1440x900 (#465a)',
        );
        await finish(tester);
      });
    },
  );

  testWidgets(
    'the rail still fits with much less vertical room, e.g. a short window '
    '(#465a — the old IntrinsicHeight guess left the least slack here)',
    (tester) async {
      await tester.runAsync(() async {
        await cubit.init();
        await pumpApp(tester, const Size(1440, 640));
        await settle(tester);

        expect(find.byType(NavigationRail), findsOneWidget);
        expect(tester.takeException(), isNull);
        await finish(tester);
      });
    },
  );

  testWidgets(
    '/devices highlights nothing in the rail — it is not a menu destination (#465b)',
    (tester) async {
      await tester.runAsync(() async {
        await cubit.init();
        await pumpApp(tester, const Size(1440, 900));
        await settle(tester);

        GoRouter.of(
          tester.element(find.byType(CheckoutScreen)),
        ).go(AppRoutes.devices);
        await settle(tester);

        final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
        expect(
          rail.selectedIndex,
          isNull,
          reason: '/devices is not in _destinations — nothing should be highlighted',
        );
        expect(tester.takeException(), isNull);

        // Leave the shared appRouter back where the next test/file expects it.
        GoRouter.of(
          tester.element(find.byType(NavigationRail)),
        ).go(AppRoutes.checkout);
        await settle(tester);
        await finish(tester);
      });
    },
  );
}
