// #465c — LoginForm's device-mode banner used `AuthState.isPos` alone, which
// only ever becomes true from an access token's `drole` claim (a real login)
// or the role recorded at a PAST login. `POST /auth/device` (enrolment) never
// learns the device's role at all — only `POST /auth/token` does. So right
// after `DeviceEnrolmentDialog` successfully enrols this browser, `isPos` is
// still stale (false, from before enrolling), and the banner kept saying
// "ยังไม่ได้ผูกเครื่อง POS" (POS not bound yet) even though a device token was
// JUST stored — a stale lie until the counter's first login.
//
// Fixed by deriving a second signal, `hasDeviceEnrolled`, from the stored
// device token (`Unauthenticated.hasDeviceEnrolled`, already true the moment
// `AuthCubit.enrolDevice` stores the token) and using it to stop showing the
// "not enrolled" copy once a device token exists, even before the role is
// confirmed by a login.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/repositories/offline_pin_repository.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';
import 'package:srisurart_pos/presentation/blocs/auth_cubit.dart';
import 'package:srisurart_pos/presentation/widgets/login_form.dart';

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

/// Mirrors the real `AuthRepository.enrolDevice`/`getDeviceRole` contract:
/// enrolling stores a device token but never learns the role (only a real
/// `POST /auth/token` login would), so `_deviceRole` intentionally stays null
/// (or whatever a past login had recorded) across `enrolDevice`.
class _StubAuthRepo extends AuthRepository {
  _StubAuthRepo()
    : super(
        apiClient: ApiClient(tokenStorage: _NoStorage()),
        tokenStorage: _NoStorage(),
      );

  String? _deviceToken;
  String? deviceRole;
  bool authed = false;
  AuthUser? user;

  @override
  Future<String> enrolDevice(String code) async {
    _deviceToken = 'dt-fresh-from-enrol';
    return _deviceToken!;
  }

  @override
  Future<String?> getDeviceToken() async => _deviceToken;
  @override
  Future<String?> getDeviceRole() async => deviceRole;
  @override
  Future<AuthUser?> getCurrentUser() async => user;
  @override
  Future<bool> isAuthenticated() async => authed;
}

void main() {
  const notEnrolledText = 'โหมด Backoffice (ยังไม่ได้ผูกเครื่อง POS)';
  const enrolledUnconfirmedText = 'ผูกเครื่องกับร้านแล้ว รอเข้าสู่ระบบเพื่อยืนยันสิทธิ์การใช้งาน';
  const posText = 'เครื่อง POS (มีสิทธิ์ขายและบันทึกเงินสด)';

  late AppDatabase db;
  late _StubAuthRepo repo;
  late AuthCubit cubit;
  late OfflinePinRepository pinRepo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = _StubAuthRepo();
    pinRepo = OfflinePinRepository(
      db: db,
      tokenStorage: _NoStorage(),
      apiClient: ApiClient(tokenStorage: _NoStorage()),
    );
    cubit = AuthCubit(authRepository: repo, offlinePinRepository: pinRepo);
  });

  tearDown(() async {
    await cubit.close();
    await db.close();
  });

  Future<void> pumpForm(WidgetTester tester) {
    return tester.pumpWidget(
      RepositoryProvider<OfflinePinRepository>.value(
        value: pinRepo,
        child: BlocProvider<AuthCubit>.value(
          value: cubit,
          child: const MaterialApp(home: Scaffold(body: LoginForm())),
        ),
      ),
    );
  }

  testWidgets(
    'before enrolling: shows the not-yet-bound banner',
    (tester) async {
      await tester.runAsync(() async {
        await cubit.init();
        await pumpForm(tester);
        await tester.pumpAndSettle();

        expect(find.text(notEnrolledText), findsOneWidget);
        expect(find.text(enrolledUnconfirmedText), findsNothing);
        expect(find.text(posText), findsNothing);
      });
    },
  );

  testWidgets(
    'right after a successful enrol (no login yet): stops claiming "not '
    'bound" — shows the enrolled/role-unconfirmed banner instead (#465c)',
    (tester) async {
      await tester.runAsync(() async {
        await cubit.init();
        await pumpForm(tester);
        await tester.pumpAndSettle();
        expect(find.text(notEnrolledText), findsOneWidget);

        final ok = await cubit.enrolDevice('3F9A0C1B');
        expect(ok, isTrue);
        await tester.pumpAndSettle();

        // The stale "ยังไม่ได้ผูกเครื่อง POS" claim must be gone — a device
        // token now exists — but the role is still unconfirmed (no login
        // yet), so it must not claim to be a confirmed POS terminal either.
        expect(find.text(notEnrolledText), findsNothing);
        expect(find.text(posText), findsNothing);
        expect(find.text(enrolledUnconfirmedText), findsOneWidget);
      });
    },
  );

  testWidgets(
    'a real, logged-in backoffice device (confirmed via login, not just '
    'enrolled) keeps the plain "not pos" banner — never the enrolled/'
    'unconfirmed one (regression: hasUnconfirmedEnrolment must not fire for '
    'Authenticated)',
    (tester) async {
      await tester.runAsync(() async {
        repo.authed = true;
        repo.user = const AuthUser(id: 'u-1', username: 'backoffice-1', role: 'owner');
        repo.deviceRole = 'backoffice'; // resolved from a completed login's JWT
        await cubit.init();
        expect(cubit.state, isA<Authenticated>());

        await pumpForm(tester);
        await tester.pumpAndSettle();

        // Confirmed-not-pos: same wording as an unenrolled device (pre-#465c
        // behaviour, out of this issue's scope) — never the "unconfirmed"
        // sentence, which would misstate an already-confirmed login.
        expect(find.text(notEnrolledText), findsOneWidget);
        expect(find.text(enrolledUnconfirmedText), findsNothing);
        expect(find.text(posText), findsNothing);
      });
    },
  );
}
