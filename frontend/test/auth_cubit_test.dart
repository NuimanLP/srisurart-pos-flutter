// Unit tests for AuthCubit state transitions.

import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';
import 'package:srisurart_pos/presentation/blocs/auth_cubit.dart';

class StubAuthRepo extends AuthRepository {
  StubAuthRepo({
    required super.apiClient,
    required super.tokenStorage,
  });

  bool shouldFailLogin = false;
  Object? errorToThrow;
  String? mockDeviceToken;
  String? mockDeviceRole;
  AuthUser? mockUser;
  bool isAuth = false;

  /// #443 PR3: when set, login answers with a temporary-password result.
  String? pwchangeToken;
  Object? changePasswordError;
  String? lastNewPassword;

  @override
  Future<LoginResult> login({required String username, required String password}) async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if (shouldFailLogin) {
      if (errorToThrow is DeviceEnrolmentGoneException) {
        mockDeviceToken = null; // the real repository clears it first
        mockDeviceRole = null;
      }
      throw errorToThrow ?? ApiException(statusCode: 401, code: 'UNAUTHENTICATED');
    }
    final user = AuthUser(id: 'u-1', username: username, role: 'owner');
    if (pwchangeToken != null) return LoginPasswordChangeRequired(user, pwchangeToken!);
    mockUser = user;
    isAuth = true;
    return LoginSucceeded(mockUser!);
  }

  @override
  Future<AuthUser> changePassword({
    required String passwordChangeToken,
    required String newPassword,
  }) async {
    lastNewPassword = newPassword;
    if (changePasswordError != null) throw changePasswordError!;
    expect(passwordChangeToken, pwchangeToken);
    mockUser = const AuthUser(id: 'u-1', username: 'owner', role: 'owner');
    isAuth = true;
    return mockUser!;
  }

  /// Thrown by [enrolDevice] when set (e.g. `ENROL_UNSENT_WORK`).
  Object? enrolError;

  @override
  Future<String> enrolDevice(String code) async {
    if (enrolError != null) throw enrolError!;
    mockDeviceToken = 'token-for-$code';
    mockDeviceRole = 'pos';
    return mockDeviceToken!;
  }

  int logoutCalls = 0;

  @override
  Future<void> logout() async {
    logoutCalls++;
    isAuth = false;
    mockUser = null;
  }

  /// `did` of the stored refresh token (#558).
  String? mockSessionDeviceId;

  @override
  Future<String?> sessionDeviceId() async => mockSessionDeviceId;

  @override
  Future<void> clearDeviceEnrolment() async {
    mockDeviceToken = null;
    mockDeviceRole = null;
  }

  bool throwStoreUnavailable = false;

  @override
  Future<String?> getDeviceToken() async {
    if (throwStoreUnavailable) throw const TokenStoreUnavailableException();
    return mockDeviceToken;
  }

  @override
  Future<String?> getDeviceRole() async => mockDeviceRole;

  @override
  Future<AuthUser?> getCurrentUser() async => mockUser;

  @override
  Future<bool> isAuthenticated() async => isAuth;
}

class FakeStorage implements TokenStorage {
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

void main() {
  late StubAuthRepo repo;
  late AuthCubit cubit;

  setUp(() {
    final storage = FakeStorage();
    final client = ApiClient(tokenStorage: storage);
    repo = StubAuthRepo(apiClient: client, tokenStorage: storage);
    cubit = AuthCubit(authRepository: repo);
  });

  tearDown(() {
    cubit.close();
  });

  test('initial state is AuthInitial', () {
    expect(cubit.state, isA<AuthInitial>());
  });

  test('init emits Unauthenticated when no stored session', () async {
    await cubit.init();
    expect(cubit.state, isA<Unauthenticated>());
  });

  // #400: device token in an unreachable web token store — say so, don't
  // throw on a blank start screen.
  test('init emits Unauthenticated with the Thai message when the token store is unavailable', () async {
    repo.throwStoreUnavailable = true;

    await cubit.init();

    final state = cubit.state as Unauthenticated;
    expect(state.errorMessage, TokenStoreUnavailableException.message);
    expect(state.deviceToken, isNull);
  });

  test('init emits Authenticated when active session exists', () async {
    repo.isAuth = true;
    repo.mockUser = const AuthUser(id: 'u1', username: 'pos_user', role: 'cashier');
    repo.mockDeviceToken = 'dt-1';
    repo.mockDeviceRole = 'pos';

    await cubit.init();

    final state = cubit.state;
    expect(state, isA<Authenticated>());
    final authed = state as Authenticated;
    expect(authed.user.username, 'pos_user');
    expect(authed.deviceToken, 'dt-1');
    expect(authed.isPos, isTrue);
  });

  test('successful login emits AuthLoading then Authenticated', () async {
    final states = <AuthState>[];
    final sub = cubit.stream.listen(states.add);

    final success = await cubit.login(username: 'admin', password: 'password');
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(success, isTrue);
    expect(states.length, 2);
    expect(states[0], isA<AuthLoading>());
    expect(states[1], isA<Authenticated>());
    final authed = states[1] as Authenticated;
    expect(authed.user.username, 'admin');
  });

  test('failed login emits AuthLoading then Unauthenticated with Thai error message', () async {
    repo.shouldFailLogin = true;
    repo.errorToThrow = ApiException(
      statusCode: 403,
      code: 'TENANT_SUSPENDED',
    );

    final states = <AuthState>[];
    final sub = cubit.stream.listen(states.add);

    final success = await cubit.login(username: 'shop1', password: 'wrong');
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(success, isFalse);
    expect(states.length, 2);
    expect(states[0], isA<AuthLoading>());
    expect(states[1], isA<Unauthenticated>());
    final unauthed = states[1] as Unauthenticated;
    expect(unauthed.errorMessage, 'ร้านนี้ถูกระงับการใช้งาน');
  });

  // #609: a retired (or unknown) device token. The repository has forgotten
  // it; the form must stop showing "เครื่อง POS" and offer enrolment again.
  for (final code in ['retired', 'unknown']) {
    test('a $code device token drops back to backoffice with the enrolment-gone sentence', () async {
      repo.mockDeviceToken = 'retired-token';
      repo.mockDeviceRole = 'pos';
      await cubit.init();
      expect((cubit.state as Unauthenticated).isPos, isTrue);

      repo.shouldFailLogin = true;
      repo.errorToThrow = const DeviceEnrolmentGoneException();

      final success = await cubit.login(username: 'owner', password: 'pw');

      expect(success, isFalse);
      final state = cubit.state as Unauthenticated;
      expect(state.hasDeviceEnrolled, isFalse);
      expect(state.isPos, isFalse);
      expect(state.errorMessage, AuthCubit.deviceEnrolmentGone);
    });
  }

  // After the retire cleared the token, a reload must not resurrect the 'pos'
  // role remembered by the offline-PIN record (same rule as sessionExpired).
  test('init with no device token ignores a remembered pos role', () async {
    repo.mockDeviceToken = null;
    repo.mockDeviceRole = 'pos';
    await cubit.init();
    final state = cubit.state as Unauthenticated;
    expect(state.isPos, isFalse);
  });

  test('logout with no device token shows backoffice, not a remembered pos', () async {
    repo.mockDeviceToken = null;
    repo.mockDeviceRole = 'pos';
    await cubit.logout();
    expect((cubit.state as Unauthenticated).isPos, isFalse);
  });

  // The device-token read runs before the login request; a token store that
  // cannot be opened (#400) used to escape the login button's handler with
  // nothing on screen.
  test('login with an unreadable token store ends in Unauthenticated with the #400 sentence', () async {
    repo.throwStoreUnavailable = true;

    final success = await cubit.login(username: 'shop1', password: 'pw');

    expect(success, isFalse);
    final state = cubit.state as Unauthenticated;
    expect(state.errorMessage, TokenStoreUnavailableException.message);
  });

  test('enrolDevice updates state with deviceToken and role', () async {
    await cubit.init();
    final ok = await cubit.enrolDevice('POS123');
    expect(ok, isTrue);

    final state = cubit.state as Unauthenticated;
    expect(state.deviceToken, 'token-for-POS123');
    expect(state.isPos, isTrue);
  });

  // #558: the session's tokens were signed without this device, so it would
  // stay device-less (GET /devices 403, no sales) — enrolling signs out, and
  // the next login sends the device token.
  test('enrolDevice while signed in ends the session; the role waits for the next login', () async {
    repo.mockDeviceRole = 'backoffice';
    await cubit.login(username: 'owner', password: 'pass');
    expect(cubit.state, isA<Authenticated>());

    final ok = await cubit.enrolDevice('POS123');

    expect(ok, isTrue);
    expect(repo.logoutCalls, 1);
    final state = cubit.state as Unauthenticated;
    expect(state.deviceToken, 'token-for-POS123');
    expect(state.deviceRole, isNull);
    expect(state.hasDeviceEnrolled, isTrue);
    // Not a deliberate logout: the router keeps ?from= and the cart.
    expect(state.signedOut, isFalse);
    expect(state.errorMessage, isNull);
  });

  test('an enrolment refused locally (ENROL_UNSENT_WORK) keeps the session', () async {
    await cubit.login(username: 'owner', password: 'pass');
    repo.enrolError = const PosException('ENROL_UNSENT_WORK', 'งานค้าง');

    await expectLater(cubit.enrolDevice('X'), throwsA(isA<PosException>()));

    expect(cubit.state, isA<Authenticated>());
    expect(repo.logoutCalls, 0);
  });

  // #558: a session signed for a device whose token is no longer stored.
  test('init ends a device-bound session whose device token is gone', () async {
    repo.isAuth = true;
    repo.mockUser = const AuthUser(id: 'u1', username: 'owner', role: 'owner');
    repo.mockDeviceToken = null;
    repo.mockDeviceRole = 'pos';
    repo.mockSessionDeviceId = 'dv1';

    await cubit.init();

    expect(repo.logoutCalls, 1);
    final state = cubit.state as Unauthenticated;
    expect(state.deviceToken, isNull);
    expect(state.deviceRole, isNull);
  });

  test('init keeps a session made without a device token (a backoffice browser)', () async {
    repo.isAuth = true;
    repo.mockUser = const AuthUser(id: 'u1', username: 'owner', role: 'owner');
    repo.mockDeviceToken = null;
    repo.mockSessionDeviceId = null;

    await cubit.init();

    expect(repo.logoutCalls, 0);
    expect(cubit.state, isA<Authenticated>());
  });

  test('sessionExpired with no device token left shows no device role', () async {
    repo.mockDeviceRole = 'pos';
    await cubit.login(username: 'cashier', password: 'pass');
    repo.mockDeviceToken = null;

    await cubit.sessionExpired();

    final state = cubit.state as Unauthenticated;
    expect(state.deviceRole, isNull);
  });

  test('logout preserves device token in Unauthenticated state', () async {
    repo.mockDeviceToken = 'preserved-token';
    await cubit.login(username: 'cashier', password: 'pass');

    await cubit.logout();

    final state = cubit.state as Unauthenticated;
    expect(state.deviceToken, 'preserved-token');
  });

  test('a refused refresh signs the person out with no message', () async {
    // #54 AC3, cubit half: `ApiClient.onSessionExpired` drives this. The device
    // stays enrolled (ADR-0004 — the machine is still this shop's till), and
    // `errorMessage` stays null, because what the counter needs at 04:00 is the
    // login form, not a dialog about token lifetimes.
    repo.mockDeviceToken = 'preserved-token';
    await cubit.login(username: 'cashier', password: 'pass');
    expect(cubit.state, isA<Authenticated>());

    await cubit.sessionExpired();

    final state = cubit.state as Unauthenticated;
    expect(state.deviceToken, 'preserved-token');
    expect(state.errorMessage, isNull);
  });

  // #443 PR3 — temporary owner password → forced change → normal session.
  group('owner password change (#443 PR3)', () {
    test('a temporary-password login lands in AuthPasswordChangeRequired, not Authenticated', () async {
      repo.pwchangeToken = 'pwchange-token';
      final ok = await cubit.login(username: 'owner', password: 'TempPassw0rdXyz');
      expect(ok, isFalse);
      expect(cubit.state, isA<AuthPasswordChangeRequired>());
      expect((cubit.state as AuthPasswordChangeRequired).errorMessage, isNull);
      expect(repo.isAuth, isFalse);
    });

    test('changePassword success continues as a normal signed-in session', () async {
      repo.pwchangeToken = 'pwchange-token';
      await cubit.login(username: 'owner', password: 'TempPassw0rdXyz');
      final ok = await cubit.changePassword('my own long passphrase');
      expect(ok, isTrue);
      expect(repo.lastNewPassword, 'my own long passphrase');
      expect(cubit.state, isA<Authenticated>());
    });

    test('a WEAK_PASSWORD refusal stays on the form with the reason in Thai', () async {
      repo.pwchangeToken = 'pwchange-token';
      await cubit.login(username: 'owner', password: 'TempPassw0rdXyz');
      repo.changePasswordError = ApiException(
        statusCode: 400,
        code: 'WEAK_PASSWORD',
        serverMessage: 'newPassword must differ from the temporary password',
        details: {'reason': 'same_as_temp'},
      );
      expect(await cubit.changePassword('TempPassw0rdXyz'), isFalse);
      final state = cubit.state as AuthPasswordChangeRequired;
      expect(state.errorMessage, 'รหัสผ่านใหม่ต้องไม่ซ้ำกับรหัสผ่านชั่วคราว');
    });

    test('a 401 (token expired or used) ends the attempt: back to login with a Thai sentence', () async {
      repo.pwchangeToken = 'pwchange-token';
      await cubit.login(username: 'owner', password: 'TempPassw0rdXyz');
      repo.changePasswordError = ApiException(statusCode: 401, code: 'UNAUTHORIZED');
      expect(await cubit.changePassword('my own long passphrase'), isFalse);
      final state = cubit.state as Unauthenticated;
      expect(state.errorMessage, AuthCubit.passwordChangeSessionExpired);
      // The token is gone: a second attempt does nothing.
      expect(await cubit.changePassword('my own long passphrase'), isFalse);
    });

    test('cancel returns to the login form', () async {
      repo.pwchangeToken = 'pwchange-token';
      await cubit.login(username: 'owner', password: 'TempPassw0rdXyz');
      cubit.cancelPasswordChange();
      expect(cubit.state, isA<Unauthenticated>());
      expect(await cubit.changePassword('my own long passphrase'), isFalse);
    });

    test('TEMP_PASSWORD_EXPIRED is the one 401 that is not "เข้าสู่ระบบไม่สำเร็จ"', () {
      expect(
        AuthCubit.loginRefusalMessage(
          ApiException(statusCode: 401, code: 'TEMP_PASSWORD_EXPIRED'),
        ),
        'รหัสผ่านชั่วคราวหมดอายุแล้ว กรุณาติดต่อทีมงานเพื่อขอรหัสใหม่',
      );
      expect(
        AuthCubit.loginRefusalMessage(ApiException(statusCode: 401, code: 'UNAUTHORIZED')),
        'เข้าสู่ระบบไม่สำเร็จ',
      );
    });
  });
}
