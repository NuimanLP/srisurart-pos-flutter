// Unit tests for AuthRepository: login, enrolment, logout, and device binding rules.

import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/repositories/offline_pin_repository.dart';
import 'package:srisurart_pos/data/services/tenant_cache_guard.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';

class FakeTokenStorage implements TokenStorage {
  String? accessToken;
  String? refreshToken;
  String? deviceToken;
  AuthUser? user;

  @override
  Future<String?> getAccessToken() async => accessToken;
  @override
  Future<void> setAccessToken(String? token) async => accessToken = token;

  @override
  Future<String?> getRefreshToken() async => refreshToken;
  @override
  Future<void> setRefreshToken(String? token) async => refreshToken = token;

  @override
  Future<String?> getDeviceToken() async => deviceToken;
  @override
  Future<void> setDeviceToken(String? token) async => deviceToken = token;

  @override
  Future<AuthUser?> getUser() async => user;
  @override
  Future<void> setUser(AuthUser? u) async => user = u;

  @override
  Future<void> clearAuthTokens() async {
    accessToken = null;
    refreshToken = null;
    user = null;
  }

  @override
  Future<void> clearAll() async {
    accessToken = null;
    refreshToken = null;
    deviceToken = null;
    user = null;
  }
}

class _UnavailableDeviceTokenStorage extends FakeTokenStorage {
  @override
  Future<String?> getDeviceToken() async =>
      throw const TokenStoreUnavailableException();
}

void main() {
  late FakeTokenStorage storage;

  setUp(() {
    storage = FakeTokenStorage();
  });

  test('enrolDevice sends normalized code and saves deviceToken in storage', () async {
    final mockClient = MockClient((req) async {
      expect(req.url.path, '/api/v1/auth/device');
      final body = jsonDecode(req.body);
      expect(body['code'], 'ENROL-1234'); // normalized to uppercase

      return http.Response(
        jsonEncode({'deviceToken': 'dev-token-uuid-123'}),
        200,
      );
    });

    final apiClient = ApiClient(baseUrl: 'http://test', httpClient: mockClient, tokenStorage: storage);
    final repo = AuthRepository(apiClient: apiClient, tokenStorage: storage);

    final token = await repo.enrolDevice('  enrol-1234  ');
    expect(token, 'dev-token-uuid-123');
    expect(storage.deviceToken, 'dev-token-uuid-123');
  });

  // #400 / ADR-0004 F8: with the device token in an unreachable web token
  // store, enrolling must not spend the code (a new device_no) on the server.
  test('enrolDevice does not call the server when the token store is unavailable', () async {
    var calls = 0;
    final mockClient = MockClient((req) async {
      calls++;
      return http.Response(jsonEncode({'deviceToken': 'new'}), 200);
    });
    final unavailable = _UnavailableDeviceTokenStorage();
    final apiClient = ApiClient(baseUrl: 'http://test', httpClient: mockClient, tokenStorage: unavailable);
    final repo = AuthRepository(apiClient: apiClient, tokenStorage: unavailable);

    await expectLater(repo.enrolDevice('ENROL-1'), throwsA(isA<TokenStoreUnavailableException>()));
    expect(calls, 0);
  });

  test('login automatically passes deviceToken if device is already enrolled', () async {
    storage.deviceToken = 'enrolled-hardware-token';

    final mockClient = MockClient((req) async {
      expect(req.url.path, '/api/v1/auth/token');
      final body = jsonDecode(req.body);
      expect(body['username'], 'cashier1');
      expect(body['password'], 'secret123');
      expect(body['deviceToken'], 'enrolled-hardware-token');

      final bodyStr = jsonEncode({
        'accessToken': 'header.payload.signature',
        'refreshToken': 'refresh-token-xyz',
        'user': {
          'id': 'u100',
          'username': 'cashier1',
          'role': 'cashier',
          'displayName': 'คุณสมชาย',
        },
      });

      return http.Response.bytes(
        utf8.encode(bodyStr),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    final apiClient = ApiClient(baseUrl: 'http://test', httpClient: mockClient, tokenStorage: storage);
    final repo = AuthRepository(apiClient: apiClient, tokenStorage: storage);

    final result = await repo.login(username: 'cashier1', password: 'secret123');
    expect(result, isA<LoginSucceeded>());
    final user = result.user;
    expect(user.id, 'u100');
    expect(user.displayName, 'คุณสมชาย');
    expect(storage.accessToken, 'header.payload.signature');
    expect(storage.refreshToken, 'refresh-token-xyz');
    expect(storage.user, equals(user));
  });

  test('logout preserves device token while wiping user credentials', () async {
    storage.deviceToken = 'hardware-device-token';
    storage.accessToken = 'jwt';
    storage.refreshToken = 'refresh';
    storage.user = const AuthUser(id: 'u1', username: 'pos', role: 'cashier');

    final apiClient = ApiClient(baseUrl: 'http://test', tokenStorage: storage);
    final repo = AuthRepository(apiClient: apiClient, tokenStorage: storage);

    await repo.logout();

    expect(storage.accessToken, isNull);
    expect(storage.refreshToken, isNull);
    expect(storage.user, isNull);
    expect(storage.deviceToken, 'hardware-device-token');
  });

  // #400: on web the access token is memory-only, so right after a reload there
  // is no JWT to read `did`/`drole` from until the first API call refreshes it.
  // The device id/role recorded at the last online login stand in for it.
  test('getDeviceId/getDeviceRole fall back to the values recorded at login when no access token', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final apiClient = ApiClient(baseUrl: 'http://test', tokenStorage: storage);
    final pinRepo = OfflinePinRepository(db: db, tokenStorage: storage);
    final repo = AuthRepository(
      apiClient: apiClient,
      tokenStorage: storage,
      offlinePinRepository: pinRepo,
    );
    await pinRepo.recordOnlineLogin(iat: 1, deviceId: 'dev-42', deviceRole: 'pos');

    storage.accessToken = null; // reload: memory-only token is gone
    storage.refreshToken = 'refresh';

    expect(await repo.getDeviceId(), 'dev-42');
    expect(await repo.getDeviceRole(), 'pos');
  });

  // #609: the server says this browser's enrolment is dead (device retired, or
  // a token it does not know). Keeping the token kept the "เครื่อง POS" chip
  // and hid the enrol link forever, and every login failed the same way.
  group('a dead device token (#609)', () {
    http.Response refusal(String code) => http.Response.bytes(
          utf8.encode(jsonEncode({
            'status': 'error',
            'error': {'code': code, 'message': 'x'},
          })),
          401,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );

    Future<(AuthRepository, OfflinePinRepository)> build(
      http.Response response, {
      void Function()? duringRequest,
      void Function(AppDatabase db)? withDb,
    }) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      withDb?.call(db);
      final apiClient = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((_) async {
          duringRequest?.call();
          return response;
        }),
        tokenStorage: storage,
      );
      final pinRepo = OfflinePinRepository(db: db, tokenStorage: storage);
      await pinRepo.recordOnlineLogin(iat: 1, deviceId: 'dev-old', deviceRole: 'pos');
      final repo = AuthRepository(
        apiClient: apiClient,
        tokenStorage: storage,
        offlinePinRepository: pinRepo,
        tenantGuard: TenantCacheGuard(db),
      );
      return (repo, pinRepo);
    }

    for (final code in ['DEVICE_RETIRED', 'DEVICE_TOKEN_INVALID']) {
      test('$code forgets the device token and its remembered POS role', () async {
        storage.deviceToken = 'retired-token';
        final (repo, _) = await build(refusal(code));

        await expectLater(
          repo.login(username: 'owner', password: 'pw'),
          throwsA(isA<DeviceEnrolmentGoneException>()),
        );
        expect(storage.deviceToken, isNull);
        expect(await repo.getDeviceRole(), isNull);
      });
    }

    test('unsent work stays and still blocks a new enrolment (ENROL_UNSENT_WORK)', () async {
      storage.deviceToken = 'retired-token';
      late AppDatabase appDb;
      final (repo, _) = await build(
        refusal('DEVICE_RETIRED'),
        withDb: (db) => appDb = db,
      );
      await appDb.into(appDb.outboxOps).insert(OutboxOpsCompanion.insert(
            opId: 'op-1',
            idempotencyKey: 'k-1',
            type: 'sale.create',
            payload: '{}',
            aggregates: '{}',
            createdAt: DateTime(2026, 10, 5),
            status: 'pending',
          ));

      await expectLater(
        repo.login(username: 'owner', password: 'pw'),
        throwsA(isA<DeviceEnrolmentGoneException>()),
      );

      expect(storage.deviceToken, isNull);
      expect(await appDb.select(appDb.outboxOps).get(), hasLength(1));
      await expectLater(
        repo.tenantGuard!.checkEnrolment(),
        throwsA(isA<PosException>()
            .having((e) => e.code, 'code', 'ENROL_UNSENT_WORK')),
      );
    });

    // An enrolment that lands while the login request is in flight is a
    // different token than the one the server just refused: leave it alone.
    test('a token replaced mid-request is not wiped', () async {
      storage.deviceToken = 'retired-token';
      final (repo, _) = await build(
        refusal('DEVICE_RETIRED'),
        duringRequest: () => storage.deviceToken = 'fresh-token',
      );

      await expectLater(
        repo.login(username: 'owner', password: 'pw'),
        throwsA(isA<DeviceEnrolmentGoneException>()),
      );
      expect(storage.deviceToken, 'fresh-token');
    });

    test('a wrong password keeps the device token (ADR-0004)', () async {
      storage.deviceToken = 'live-token';
      final (repo, _) = await build(refusal('UNAUTHORIZED'));

      await expectLater(
        repo.login(username: 'owner', password: 'wrong'),
        // Converted here, never handed to the login form as an ApiException.
        throwsA(isA<PosException>()
            .having((e) => e.code, 'code', 'UNAUTHORIZED')
            .having((e) => e.message, 'message', 'เข้าสู่ระบบไม่สำเร็จ')),
      );
      expect(storage.deviceToken, 'live-token');
      expect(await repo.getDeviceRole(), 'pos');
    });
  });

  // #443 PR3: a temporary owner password answers with a restricted token and
  // no accessToken/refreshToken — the old `as String` casts crashed on it.
  group('temporary owner password (#443 PR3)', () {
    String jwt(Map<String, dynamic> claims) =>
        'h.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.s';

    http.Response json(Object body) => http.Response.bytes(
          utf8.encode(jsonEncode(body)),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );

    test('login → LoginPasswordChangeRequired; nothing stored, no online-login iat recorded', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final pinRepo = OfflinePinRepository(db: db, tokenStorage: storage);
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStorage: storage,
        httpClient: MockClient((_) async => json({
              'passwordChangeRequired': true,
              'passwordChangeToken': 'pwchange-jwt',
              'user': {'id': 'u1', 'username': 'owner', 'role': 'owner'},
            })),
      );
      final repo = AuthRepository(
        apiClient: client,
        tokenStorage: storage,
        offlinePinRepository: pinRepo,
      );

      final result = await repo.login(username: 'owner', password: 'TempPassw0rdXyz');
      expect(result, isA<LoginPasswordChangeRequired>());
      expect((result as LoginPasswordChangeRequired).passwordChangeToken, 'pwchange-jwt');
      expect(storage.accessToken, isNull);
      expect(storage.refreshToken, isNull);
      expect(storage.user, isNull);
      expect(await pinRepo.getLastLoginIat(), isNull);
    });

    test('changePassword sends the pwchange token as the bearer and stores the full session', () async {
      final access = jwt({'iat': 1790000000, 'did': 'pos1', 'drole': 'pos', 'typ': 'access'});
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final pinRepo = OfflinePinRepository(db: db, tokenStorage: storage);
      storage.accessToken = 'stale-access-that-must-not-be-sent';
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStorage: storage,
        httpClient: MockClient((req) async {
          expect(req.url.path, '/api/v1/auth/change-password');
          expect(req.headers['Authorization'], 'Bearer pwchange-jwt');
          expect(jsonDecode(req.body), {'newPassword': 'my own long passphrase'});
          return json({
            'accessToken': access,
            'refreshToken': 'refresh-1',
            'user': {'id': 'u1', 'username': 'owner', 'role': 'owner'},
          });
        }),
      );
      final repo = AuthRepository(apiClient: client, tokenStorage: storage, offlinePinRepository: pinRepo);

      final user = await repo.changePassword(
        passwordChangeToken: 'pwchange-jwt',
        newPassword: 'my own long passphrase',
      );
      expect(user.username, 'owner');
      expect(storage.accessToken, access);
      expect(storage.refreshToken, 'refresh-1');
      // Only the full session counts as the online login for the offline-PIN window.
      expect(await pinRepo.getLastLoginIat(), 1790000000);
    });

    // The refusal leaves the repository already converted — the cubit never
    // sees an ApiException (CLAUDE.md binding rule).
    Future<Object?> changePasswordRefused(int status, String code,
        [Object? details]) async {
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStorage: storage,
        httpClient: MockClient((_) async => http.Response.bytes(
              utf8.encode(jsonEncode({
                'status': 'error',
                'error': {
                  'code': code,
                  'message': 'x',
                  'details': ?details,
                },
              })),
              status,
              headers: {'content-type': 'application/json; charset=utf-8'},
            )),
      );
      final repo = AuthRepository(apiClient: client, tokenStorage: storage);
      try {
        await repo.changePassword(passwordChangeToken: 't', newPassword: 'n');
      } catch (e) {
        return e;
      }
      return null;
    }

    test('changePassword: a 401 is PasswordChangeSessionExpiredException', () async {
      expect(await changePasswordRefused(401, 'UNAUTHORIZED'),
          isA<PasswordChangeSessionExpiredException>());
      expect(storage.accessToken, isNull);
    });

    test('changePassword: another refusal is a PosException in Thai', () async {
      final e = await changePasswordRefused(
          400, 'WEAK_PASSWORD', {'reason': 'same_as_temp'});
      expect(e, isA<PosException>().having((e) => e.code, 'code', 'WEAK_PASSWORD'));
      expect((e! as PosException).message,
          'รหัสผ่านใหม่ต้องไม่ซ้ำกับรหัสผ่านชั่วคราว');
      final down = await changePasswordRefused(502, 'BAD_GATEWAY');
      expect((down! as PosException).message,
          'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์');
    });

    test('a normal login carries passwordChangedAt for the banner', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStorage: storage,
        httpClient: MockClient((_) async => json({
              'accessToken': 'a.b.c',
              'refreshToken': 'r',
              'user': {'id': 'u1', 'username': 'owner', 'role': 'owner'},
              'passwordChangedAt': '2026-09-26T03:00:00.000Z',
            })),
      );
      final repo = AuthRepository(apiClient: client, tokenStorage: storage);
      final result = await repo.login(username: 'owner', password: 'pw') as LoginSucceeded;
      expect(result.passwordChangedAt!.toUtc(), DateTime.utc(2026, 9, 26, 3));
    });

    test('offline PIN cannot be set with a temporary password', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStorage: storage,
        httpClient: MockClient((_) async => json({
              'passwordChangeRequired': true,
              'passwordChangeToken': 'pwchange-jwt',
              'user': {'id': 'u1', 'username': 'owner', 'role': 'owner'},
            })),
      );
      final pinRepo = OfflinePinRepository(db: db, tokenStorage: storage, apiClient: client);
      await expectLater(
        pinRepo.setPin(
          password: 'TempPassw0rdXyz',
          newPin: '1234',
          username: 'owner',
          deviceId: 'pos1',
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          OfflinePinRepository.passwordChangeRequiredMessage,
        )),
      );
      expect(await pinRepo.isPinConfigured(), isFalse);
      expect(await pinRepo.getLastLoginIat(), isNull);
    });
  });
}
