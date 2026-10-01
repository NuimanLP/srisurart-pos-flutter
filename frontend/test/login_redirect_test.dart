// #143 — the login route and the go_router redirect, driven through the real
// SrisurartApp (router, AppShell, screens) against an in-memory Drift DB.
//
//  1. USE_API_WRITES off: the Drift-only shop build routes exactly as before —
//     no login route, a signed-out AuthCubit changes nothing.
//  2. On: a signed-out boot lands on the login form (spinner, not a form flash,
//     while the stored session is still being read).
//  3. On: a session expiry sends the counter to the login form with no dialog
//     and no error, and signing in returns to the route it was on.
//  4. On: a login refusal shows the resolver's Thai and stays on the form.
//
// Harness mirrors route_smoke_test.dart (runAsync so Drift futures complete).

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/app.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/core/router/app_router.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';
import 'package:srisurart_pos/presentation/blocs/auth_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/checkout_screen.dart';
import 'package:srisurart_pos/presentation/screens/login_screen.dart';
import 'package:srisurart_pos/presentation/widgets/change_password_form.dart';
import 'package:srisurart_pos/presentation/widgets/password_changed_banner.dart';
import 'package:srisurart_pos/presentation/screens/settings_screen.dart';
import 'package:srisurart_pos/presentation/widgets/app_button.dart';
import 'package:srisurart_pos/presentation/widgets/app_shell.dart';
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

  bool isAuth = false;
  AuthUser? user;
  String? deviceToken = 'dt-1';
  Object? loginError;

  /// #443 PR3: when set, login answers with a temporary-password result.
  String? pwchangeToken;
  DateTime? passwordChangedAt;

  /// What reached the repository, exactly — the round-trip test compares these.
  final loginPasswords = <String>[];
  String? newPasswordSent;

  /// Held open by a test to observe the form while a login is in flight.
  Completer<void>? loginGate;

  @override
  Future<LoginResult> login({
    required String username,
    required String password,
  }) async {
    loginPasswords.add(password);
    if (loginGate != null) await loginGate!.future;
    if (loginError != null) throw loginError!;
    final u = AuthUser(id: 'u-1', username: username, role: 'cashier');
    if (pwchangeToken != null) return LoginPasswordChangeRequired(u, pwchangeToken!);
    isAuth = true;
    user = u;
    return LoginSucceeded(user!, passwordChangedAt: passwordChangedAt);
  }

  @override
  Future<AuthUser> changePassword({
    required String passwordChangeToken,
    required String newPassword,
  }) async {
    newPasswordSent = newPassword;
    pwchangeToken = null;
    isAuth = true;
    user = const AuthUser(id: 'u-1', username: 'owner', role: 'owner');
    return user!;
  }

  @override
  Future<void> logout() async {
    isAuth = false;
    user = null;
  }

  @override
  Future<String?> getDeviceToken() async => deviceToken;
  @override
  Future<String?> getDeviceRole() async => isAuth ? 'pos' : null;
  @override
  Future<AuthUser?> getCurrentUser() async => user;
  @override
  Future<bool> isAuthenticated() async => isAuth;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('authRedirect', () {
    const user = AuthUser(id: 'u', username: 'a', role: 'cashier');
    const signedIn = Authenticated(user: user);

    test('any non-signed-in state goes to login, remembering the route', () {
      for (final s in const <AuthState>[
        AuthInitial(),
        AuthLoading(),
        Unauthenticated(),
      ]) {
        expect(
          authRedirect(s, Uri.parse('/settings')),
          '/login?from=%2Fsettings',
        );
        expect(authRedirect(s, Uri.parse('/')), '/login');
        expect(authRedirect(s, Uri.parse('/login?from=%2Fsettings')), isNull);
      }
    });

    test('a signed-in session leaves login for the remembered route', () {
      expect(
        authRedirect(signedIn, Uri.parse('/login?from=%2Freturns')),
        '/returns',
      );
      expect(authRedirect(signedIn, Uri.parse('/login')), '/');
      expect(authRedirect(signedIn, Uri.parse('/reports')), isNull);
    });

    test('after a deliberate logout login forgets the last screen', () {
      const signedOut = Unauthenticated(signedOut: true);
      expect(authRedirect(signedOut, Uri.parse('/settings')), '/login');
      expect(authRedirect(signedOut, Uri.parse('/login')), isNull);
      // A session expiry still remembers it.
      expect(
        authRedirect(const Unauthenticated(), Uri.parse('/settings')),
        '/login?from=%2Fsettings',
      );
    });

    test('only an in-app path is followed back', () {
      expect(safeReturnPath('/cash-drawer'), '/cash-drawer');
      expect(safeReturnPath(null), '/');
      expect(safeReturnPath('https://evil.example/'), '/');
      expect(safeReturnPath('//evil.example/x'), '/');
      expect(safeReturnPath('settings'), '/');
      expect(safeReturnPath('/login?from=%2Flogin'), '/');
    });
  });

  group('AuthCubit.loginRefusalMessage', () {
    test('a 401 never prints the server\'s English sentence', () {
      final e = ApiException(
        statusCode: 401,
        code: 'UNAUTHORIZED',
        serverMessage: 'Invalid credentials',
      );
      expect(AuthCubit.loginRefusalMessage(e), 'เข้าสู่ระบบไม่สำเร็จ');
    });

    test('a coded verdict resolves to its mapped Thai', () {
      expect(
        AuthCubit.loginRefusalMessage(
          ApiException(statusCode: 403, code: 'TENANT_SUSPENDED'),
        ),
        'ร้านนี้ถูกระงับการใช้งาน',
      );
      expect(
        AuthCubit.loginRefusalMessage(
          ApiException(statusCode: 429, code: 'RATE_LIMITED'),
        ),
        'ระบบกำลังทำงานหนัก กรุณารอสักครู่',
      );
    });

    test('a 5xx or a lost connection shows the connection sentence', () {
      const connection = 'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์';
      expect(
        AuthCubit.loginRefusalMessage(
          ApiException(
            statusCode: 502,
            code: 'BAD_GATEWAY',
            serverMessage: '<html>502 Bad Gateway</html>',
          ),
        ),
        connection,
      );
      final lost = AuthCubit.loginRefusalMessage(
        http.ClientException('XMLHttpRequest error.'),
      );
      expect(lost, connection);
      expect(lost, isNot(contains('ClientException')));
      expect(AuthCubit.loginRefusalMessage(TimeoutException('t')), connection);
    });
  });

  group('app routing', () {
    late AppDatabase db;
    late _StubAuthRepo repo;
    late AuthCubit cubit;

    Future<void> pumpApp(WidgetTester tester, {required bool requireLogin}) {
      tester.view.physicalSize = const Size(1280, 800);
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
              BlocProvider<PendingQuoteCubit>(
                create: (_) => PendingQuoteCubit(),
              ),
              BlocProvider<CartCubit>(create: (_) => CartCubit()),
              BlocProvider<AuthCubit>.value(value: cubit),
            ],
            child: SrisurartApp(
              requireLogin: requireLogin,
              themeOverride: ThemeData(),
            ),
          ),
        ),
      );
    }

    /// Let router rebuilds and screens' Drift loads finish. Not pumpAndSettle:
    /// the boot spinner animates forever. ~600 ms covers a page transition.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Uri location(WidgetTester tester, Finder inRoute) =>
        GoRouterState.of(tester.element(inRoute)).uri;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = _StubAuthRepo();
      cubit = AuthCubit(authRepository: repo);
    });

    Future<void> finish(WidgetTester tester) async {
      // Unmount inside the test so screen futures see an open DB.
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await cubit.close();
      await db.close();
    }

    testWidgets('flag off: the Drift build routes exactly as before', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await cubit.init(); // signed out
        expect(cubit.state, isA<Unauthenticated>());

        await pumpApp(tester, requireLogin: false);
        await settle(tester);

        expect(find.byType(LoginScreen), findsNothing);
        expect(find.byType(CheckoutScreen), findsOneWidget);
        expect(find.byType(AppShell), findsOneWidget);

        GoRouter.of(
          tester.element(find.byType(CheckoutScreen)),
        ).go(AppRoutes.settings);
        await settle(tester);
        expect(find.byType(SettingsScreen), findsOneWidget);

        // A session expiry on the Drift build does not move the counter.
        await cubit.sessionExpired();
        await settle(tester);
        expect(find.byType(SettingsScreen), findsOneWidget);
        expect(find.byType(LoginScreen), findsNothing);

        // Leave the shared appRouter where the next user of it expects it.
        GoRouter.of(
          tester.element(find.byType(SettingsScreen)),
        ).go(AppRoutes.checkout);
        await settle(tester);
        await finish(tester);
      });
    });

    testWidgets(
      'flag on: a signed-out boot shows the login form, not a screen',
      (tester) async {
        await tester.runAsync(() async {
          await pumpApp(tester, requireLogin: true);
          await tester.pump();

          // Still reading the stored session: a spinner, no form, no shell.
          expect(cubit.state, isA<AuthInitial>());
          expect(find.byType(LoginScreen), findsOneWidget);
          expect(find.byType(TextField), findsNothing);
          expect(find.byType(AppShell), findsNothing);

          await cubit.init();
          await settle(tester);

          expect(find.byType(LoginScreen), findsOneWidget);
          expect(find.byType(TextField), findsNWidgets(2));
          expect(find.byType(CheckoutScreen), findsNothing);
          expect(location(tester, find.byType(LoginScreen)).path, '/login');
          await finish(tester);
        });
      },
    );

    testWidgets(
      'flag on: session expiry shows the form with no dialog, and signing in '
      'returns to the route the counter was on',
      (tester) async {
        await tester.runAsync(() async {
          repo.isAuth = true;
          repo.user = const AuthUser(
            id: 'u-1',
            username: 'pos',
            role: 'cashier',
          );
          await cubit.init();
          expect(cubit.state, isA<Authenticated>());

          await pumpApp(tester, requireLogin: true);
          await settle(tester);
          expect(find.byType(CheckoutScreen), findsOneWidget);

          GoRouter.of(
            tester.element(find.byType(CheckoutScreen)),
          ).go(AppRoutes.settings);
          await settle(tester);
          expect(find.byType(SettingsScreen), findsOneWidget);

          // 04:00: the refresh is refused and ApiClient calls sessionExpired.
          repo.isAuth = false;
          repo.user = null;
          await cubit.sessionExpired();
          await settle(tester);

          expect(find.byType(LoginScreen), findsOneWidget);
          expect(find.byType(SettingsScreen), findsNothing);
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.byType(Dialog), findsNothing);
          expect(find.byType(SnackBar), findsNothing);
          expect(find.text('เข้าสู่ระบบไม่สำเร็จ'), findsNothing);
          expect(
            location(tester, find.byType(LoginScreen)).queryParameters['from'],
            AppRoutes.settings,
          );
          // The machine is still enrolled (ADR-0004): no enrolment offer.
          expect(find.text('ผูกเครื่องขาย (POS Terminal)'), findsNothing);

          await tester.enterText(find.byType(TextField).at(0), 'pos');
          await tester.enterText(find.byType(TextField).at(1), 'secret');
          await tester.tap(find.widgetWithText(AppButton, 'เข้าสู่ระบบ'));
          await settle(tester);

          expect(cubit.state, isA<Authenticated>());
          expect(find.byType(LoginScreen), findsNothing);
          expect(find.byType(SettingsScreen), findsOneWidget);
          await finish(tester);
        });
      },
    );

    testWidgets(
      'flag on: a refusal shows the resolver Thai and stays on login',
      (tester) async {
        await tester.runAsync(() async {
          repo.deviceToken = null; // a fresh machine
          await cubit.init();
          await pumpApp(tester, requireLogin: true);
          await settle(tester);

          // ADR-0004: enrolment is reachable before anyone signs in.
          expect(find.text('ผูกเครื่องขาย (POS Terminal)'), findsOneWidget);

          repo.loginError = ApiException(
            statusCode: 403,
            code: 'TENANT_SUSPENDED',
          );
          await tester.enterText(find.byType(TextField).at(0), 'pos');
          await tester.enterText(find.byType(TextField).at(1), 'secret');
          await tester.tap(find.widgetWithText(AppButton, 'เข้าสู่ระบบ'));
          await settle(tester);

          expect(find.byType(LoginScreen), findsOneWidget);
          expect(find.text('ร้านนี้ถูกระงับการใช้งาน'), findsOneWidget);
          expect(find.byType(AlertDialog), findsNothing);

          repo.loginError = ApiException(
            statusCode: 401,
            code: 'UNAUTHORIZED',
            serverMessage: 'Invalid credentials',
          );
          await tester.tap(find.widgetWithText(AppButton, 'เข้าสู่ระบบ'));
          await settle(tester);

          expect(find.text('เข้าสู่ระบบไม่สำเร็จ'), findsOneWidget);
          expect(find.textContaining('Invalid credentials'), findsNothing);
          expect(find.byType(LoginScreen), findsOneWidget);
          await finish(tester);
        });
      },
    );

    testWidgets(
      'flag on: a temporary password swaps the form for the change form, then signs in (#443 PR3)',
      (tester) async {
        await tester.runAsync(() async {
          await cubit.init();
          await pumpApp(tester, requireLogin: true);
          await settle(tester);

          repo.pwchangeToken = 'pwchange-token';
          await tester.enterText(find.byType(TextField).at(0), 'owner');
          await tester.enterText(find.byType(TextField).at(1), 'TempPassw0rdXyz');
          await tester.tap(find.widgetWithText(AppButton, 'เข้าสู่ระบบ'));
          await settle(tester);

          expect(find.byType(LoginScreen), findsOneWidget);
          expect(find.byType(ChangePasswordForm), findsOneWidget);
          expect(find.text('ตั้งรหัสผ่านใหม่'), findsOneWidget);
          expect(find.text('เข้าสู่ระบบไม่สำเร็จ'), findsNothing);
          expect(find.byType(CheckoutScreen), findsNothing);

          await tester.enterText(find.byKey(const Key('change-password-new')), 'my own long passphrase');
          await tester.enterText(find.byKey(const Key('change-password-confirm')), 'something else entirely');
          await settle(tester);
          // Mismatched boxes: the checklist shows it and submit stays disabled.
          expect(
            tester.widget<FilledButton>(find.widgetWithText(FilledButton, ChangePasswordForm.submit)).onPressed,
            isNull,
          );

          await tester.enterText(find.byKey(const Key('change-password-confirm')), 'my own long passphrase');
          await tester.pump(); // the checklist enables submit on the next frame
          await tester.tap(find.text(ChangePasswordForm.submit));
          await settle(tester);

          expect(cubit.state, isA<Authenticated>());
          expect(find.byType(LoginScreen), findsNothing);
          expect(find.byType(CheckoutScreen), findsOneWidget);
          await finish(tester);
        });
      },
    );

    testWidgets(
      'flag on: a recent passwordChangedAt shows the banner in the shell until dismissed (#443 PR3)',
      (tester) async {
        await tester.runAsync(() async {
          await cubit.init();
          await pumpApp(tester, requireLogin: true);
          await settle(tester);

          repo.passwordChangedAt = DateTime.now().subtract(const Duration(hours: 2));
          await tester.enterText(find.byType(TextField).at(0), 'owner');
          await tester.enterText(find.byType(TextField).at(1), 'my own long passphrase');
          await tester.tap(find.widgetWithText(AppButton, 'เข้าสู่ระบบ'));
          await settle(tester);

          expect(find.byType(CheckoutScreen), findsOneWidget);
          expect(find.textContaining('รหัสผ่านถูกเปลี่ยนเมื่อ'), findsOneWidget);
          await tester.tap(find.text(PasswordChangedBanner.dismiss));
          await settle(tester);
          expect(find.textContaining('รหัสผ่านถูกเปลี่ยนเมื่อ'), findsNothing);
          await finish(tester);
        });
      },
    );

    testWidgets(
      'the password set on the change form is the one sent, and the one a '
      're-login after logout sends',
      (tester) async {
        await tester.runAsync(() async {
          // Thai, inner and trailing spaces, tone mark before the below-vowel
          // (not NFC): nothing on the way may trim, normalise or swap boxes.
          const chosen = 'รหัสใหม่ของร้าน ป\u0E48\u0E39 2569 ';
          await cubit.init();
          await pumpApp(tester, requireLogin: true);
          await settle(tester);

          repo.pwchangeToken = 'pwchange-token';
          await tester.enterText(find.byType(TextField).at(0), 'owner');
          await tester.enterText(find.byType(TextField).at(1), 'TempPassw0rdXyz');
          await tester.tap(find.widgetWithText(AppButton, 'เข้าสู่ระบบ'));
          await settle(tester);

          bool saved() => tester.testTextInput.log.any(
                (c) =>
                    c.method == 'TextInput.finishAutofillContext' &&
                    c.arguments == true,
              );
          // A temporary password is never offered to the password manager.
          expect(saved(), isFalse);

          final newBox = find.byKey(const Key('change-password-new'));
          await tester.enterText(newBox, chosen);
          // The eye toggle (#529) must not lose or alter what was typed.
          await tester.tap(find.descendant(of: newBox, matching: find.byType(IconButton)));
          await tester.pump();
          await tester.enterText(find.byKey(const Key('change-password-confirm')), chosen);
          await tester.pump();
          await tester.tap(find.text(ChangePasswordForm.submit));
          await settle(tester);
          expect(cubit.state, isA<Authenticated>());
          expect(repo.newPasswordSent, chosen);
          // After the change the browser is told to save — the NEW password.
          expect(saved(), isTrue);
          tester.testTextInput.log.clear();

          repo.isAuth = false;
          repo.user = null;
          await cubit.logout();
          await settle(tester);
          expect(find.byType(LoginScreen), findsOneWidget);

          await tester.enterText(find.byType(TextField).at(0), 'owner');
          await tester.enterText(find.byType(TextField).at(1), chosen);
          await tester.tap(find.widgetWithText(AppButton, 'เข้าสู่ระบบ'));
          await settle(tester);
          expect(repo.loginPasswords, ['TempPassw0rdXyz', chosen]);
          expect(cubit.state, isA<Authenticated>());
          expect(saved(), isTrue);
          await finish(tester);
        });
      },
    );

    testWidgets(
      'a login in flight keeps the device chip: an enrolled POS till is never '
      'shown as Backoffice while the request runs',
      (tester) async {
        await tester.runAsync(() async {
          repo.isAuth = true;
          repo.user = const AuthUser(id: 'u-1', username: 'pos', role: 'cashier');
          await cubit.init();
          await pumpApp(tester, requireLogin: true);
          await settle(tester);

          await cubit.logout();
          await settle(tester);
          const posChip = 'เครื่อง POS (มีสิทธิ์ขายและบันทึกเงินสด)';
          expect(find.text(posChip), findsOneWidget);

          repo.loginGate = Completer<void>();
          await tester.enterText(find.byType(TextField).at(0), 'pos');
          await tester.enterText(find.byType(TextField).at(1), 'secret');
          await tester.tap(find.widgetWithText(AppButton, 'เข้าสู่ระบบ'));
          await tester.pump();
          expect(cubit.state, isA<AuthLoading>());
          expect(find.text(posChip), findsOneWidget);
          expect(find.text('โหมด Backoffice (ยังไม่ได้ผูกเครื่อง POS)'), findsNothing);

          repo.loginGate!.complete();
          await settle(tester);
          expect(cubit.state, isA<Authenticated>());
          await finish(tester);
        });
      },
    );

    group('deliberate logout vs session expiry (owner 2026-10-01)', () {
      const line = CartLine(
        productId: 'p1',
        name: 'x',
        price: 10,
        originalPrice: 10,
        cost: 5,
        qty: 1,
      );
      final quote = QuoteWithItems(
        QuoteRow(
          id: 'q1',
          quoteNo: 'QT-1',
          status: 'open',
          date: DateTime(2026, 10, 1),
          validUntil: DateTime(2026, 10, 31),
        ),
        const [],
      );

      Future<BuildContext> signInOnSettingsWithCart(WidgetTester tester) async {
        repo.isAuth = true;
        repo.user = const AuthUser(id: 'u-1', username: 'pos', role: 'cashier');
        await cubit.init();
        await pumpApp(tester, requireLogin: true);
        await settle(tester);
        final ctx = tester.element(find.byType(AppShell));
        GoRouter.of(ctx).go(AppRoutes.settings);
        await settle(tester);
        ctx.read<CartCubit>().setLines(const [line]);
        ctx.read<PendingQuoteCubit>().set(quote);
        return ctx;
      }

      Future<void> signInAgain(WidgetTester tester) async {
        await tester.enterText(find.byType(TextField).at(0), 'next');
        await tester.enterText(find.byType(TextField).at(1), 'secret');
        await tester.tap(find.widgetWithText(AppButton, 'เข้าสู่ระบบ'));
        await settle(tester);
        await settle(tester);
      }

      testWidgets('logout: cart and quote cleared, next login lands on checkout',
          (tester) async {
        await tester.runAsync(() async {
          final ctx = await signInOnSettingsWithCart(tester);
          final cart = ctx.read<CartCubit>();
          final pending = ctx.read<PendingQuoteCubit>();

          repo.isAuth = false;
          repo.user = null;
          await cubit.logout();
          await settle(tester);
          expect(find.byType(LoginScreen), findsOneWidget);
          expect(
            location(tester, find.byType(LoginScreen)).queryParameters,
            isEmpty,
          );
          expect(cart.state, isEmpty);
          expect(pending.state, isNull);

          await signInAgain(tester);
          expect(find.byType(CheckoutScreen), findsOneWidget);
          expect(find.byType(SettingsScreen), findsNothing);
          await finish(tester);
        });
      });

      testWidgets('session expiry: cart and quote kept, login returns to the screen',
          (tester) async {
        await tester.runAsync(() async {
          final ctx = await signInOnSettingsWithCart(tester);
          final cart = ctx.read<CartCubit>();
          final pending = ctx.read<PendingQuoteCubit>();

          repo.isAuth = false;
          repo.user = null;
          await cubit.sessionExpired();
          await settle(tester);
          expect(find.byType(LoginScreen), findsOneWidget);
          expect(cart.state, [line]);
          expect(pending.state, same(quote));

          await signInAgain(tester);
          expect(find.byType(SettingsScreen), findsOneWidget);
          expect(cart.state, [line]);
          await finish(tester);
        });
      });
    });

    testWidgets('login and change forms carry the browser autofill hints', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await cubit.init();
        await pumpApp(tester, requireLogin: true);
        await settle(tester);
        List<String>? hints(int i) =>
            tester.widget<EditableText>(find.byType(EditableText).at(i)).autofillHints?.toList();
        expect(find.byType(AutofillGroup), findsOneWidget);
        expect(hints(0), [AutofillHints.username]);
        expect(hints(1), [AutofillHints.password]);

        repo.pwchangeToken = 'pwchange-token';
        await tester.enterText(find.byType(TextField).at(0), 'owner');
        await tester.enterText(find.byType(TextField).at(1), 'TempPassw0rdXyz');
        await tester.tap(find.widgetWithText(AppButton, 'เข้าสู่ระบบ'));
        await settle(tester);
        expect(find.byType(ChangePasswordForm), findsOneWidget);
        expect(find.byType(AutofillGroup), findsOneWidget);
        expect(hints(0), [AutofillHints.newPassword]);
        expect(hints(1), [AutofillHints.newPassword]);
        await finish(tester);
      });
    });
  });
}
