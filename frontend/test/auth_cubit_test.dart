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
  ApiException? errorToThrow;
  String? mockDeviceToken;
  String? mockDeviceRole;
  AuthUser? mockUser;
  bool isAuth = false;

  @override
  Future<AuthUser> login({required String username, required String password}) async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if (shouldFailLogin) {
      throw errorToThrow ?? ApiException(statusCode: 401, code: 'UNAUTHENTICATED');
    }
    mockUser = AuthUser(id: 'u-1', username: username, role: 'cashier');
    isAuth = true;
    return mockUser!;
  }

  @override
  Future<String> enrolDevice(String code) async {
    mockDeviceToken = 'token-for-$code';
    mockDeviceRole = 'pos';
    return mockDeviceToken!;
  }

  @override
  Future<void> logout() async {
    isAuth = false;
    mockUser = null;
  }

  @override
  Future<void> clearDeviceEnrolment() async {
    mockDeviceToken = null;
    mockDeviceRole = null;
  }

  @override
  Future<String?> getDeviceToken() async => mockDeviceToken;

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

  test('enrolDevice updates state with deviceToken and role', () async {
    await cubit.init();
    final ok = await cubit.enrolDevice('POS123');
    expect(ok, isTrue);

    final state = cubit.state as Unauthenticated;
    expect(state.deviceToken, 'token-for-POS123');
    expect(state.isPos, isTrue);
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
}
