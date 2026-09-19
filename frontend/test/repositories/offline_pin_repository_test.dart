import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/offline_pin_repository.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';

class _FakeTokenStorage implements TokenStorage {
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
    user = null;
    deviceToken = null;
  }
}

class _MockHttpClient extends http.BaseClient {
  _MockHttpClient({this.handler});

  Future<http.Response> Function(http.Request request)? handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bodyBytes = await request.finalize().toBytes();
    final req = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = bodyBytes;

    final response = handler != null
        ? await handler!(req)
        : http.Response('{"accessToken":"fake.jwt.token"}', 200);

    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

void main() {
  late AppDatabase db;
  late _FakeTokenStorage tokenStorage;
  late OfflinePinRepository repo;

  // Helper to construct a test JWT token containing custom claims
  String makeJwt({required int iat, required String did}) {
    final header = base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
    final payload = base64Url.encode(utf8.encode(jsonEncode({
      'sub': 'u-owner-1',
      'tid': 't-shop-1',
      'did': did,
      'drole': 'pos',
      'role': 'owner',
      'iat': iat,
      'exp': iat + 900,
    })));
    return '$header.$payload.fake_signature';
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    tokenStorage = _FakeTokenStorage();
    repo = OfflinePinRepository(
      db: db,
      tokenStorage: tokenStorage,
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('OfflinePinRepository - Invariant C4: Setup & in-memory check', () {
    test('rejects setup immediately in memory when PIN == password', () async {
      expect(
        () => repo.setPin(
          password: 'secretPassword123',
          newPin: 'secretPassword123',
          username: 'owner',
          deviceId: 'pos-dev-1',
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('รหัส PIN ต้องไม่ตรงกับรหัสผ่าน'),
        )),
      );

      // Verify nothing is persisted
      expect(await repo.isPinConfigured(), isFalse);
    });

    test('rejects PIN if length is less than 4 or greater than 6', () async {
      expect(
        () => repo.setPin(
          password: 'secretPassword123',
          newPin: '123',
          username: 'owner',
          deviceId: 'pos-dev-1',
        ),
        throwsA(isA<ArgumentError>()),
      );

      expect(
        () => repo.setPin(
          password: 'secretPassword123',
          newPin: '1234567',
          username: 'owner',
          deviceId: 'pos-dev-1',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('verifies password via POST /auth/token without sending PIN to server',
        () async {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final jwt = makeJwt(iat: nowSec, did: 'pos-dev-1');

      var passwordReceivedByServer = '';
      var requestSentPin = false;

      final mockClient = _MockHttpClient(handler: (req) async {
        expect(req.url.path, equals('/api/v1/auth/token'));
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        passwordReceivedByServer = body['password'] as String;
        // Invariant: PIN or PIN hash must NEVER appear in HTTP request
        if (body.containsKey('pin') ||
            body.containsKey('pinHash') ||
            body.containsKey('offlinePin')) {
          requestSentPin = true;
        }

        return http.Response(
          jsonEncode({
            'accessToken': jwt,
            'refreshToken': 'refresh-token',
            'user': {
              'id': 'u-owner-1',
              'username': 'owner',
              'role': 'owner',
              'displayName': 'เจ้าของร้าน',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiClient = ApiClient(
        tokenStorage: tokenStorage,
        httpClient: mockClient,
      );

      final customRepo = OfflinePinRepository(
        db: db,
        tokenStorage: tokenStorage,
        apiClient: apiClient,
      );

      await customRepo.setPin(
        password: 'myRealPassword99',
        newPin: '5678',
        username: 'owner',
        deviceId: 'pos-dev-1',
      );

      // Invariants verified
      expect(passwordReceivedByServer, equals('myRealPassword99'));
      expect(requestSentPin, isFalse);

      // Verify Drift storage
      expect(await customRepo.isPinConfigured(), isTrue);
      expect(await customRepo.isLocked(), isFalse);
      expect(await customRepo.getFailedAttempts(), equals(0));
      expect(await customRepo.getLastLoginIat(), equals(nowSec));
    });
  });

  group('OfflinePinRepository - Verification, Expiry (C5/F5), Lockout', () {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    setUp(() async {
      final jwt = makeJwt(iat: nowSec, did: 'pos-dev-1');
      final mockClient = _MockHttpClient(handler: (req) async {
        return http.Response(
          jsonEncode({
            'accessToken': jwt,
            'refreshToken': 'refresh',
            'user': {
              'id': 'u-owner-1',
              'username': 'owner',
              'role': 'owner',
              'displayName': 'เจ้าของร้าน',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final customRepo = OfflinePinRepository(
        db: db,
        tokenStorage: tokenStorage,
        apiClient: ApiClient(tokenStorage: tokenStorage, httpClient: mockClient),
      );

      await customRepo.setPin(
        password: 'password123',
        newPin: '1234',
        username: 'owner',
        deviceId: 'pos-dev-1',
      );
    });

    test('verifies correct PIN successfully on bound device', () async {
      final result = await repo.verifyPin(
        pin: '1234',
        deviceId: 'pos-dev-1',
      );
      expect(result, isA<PinVerifySuccess>());
      expect(await repo.getFailedAttempts(), equals(0));
    });

    test('rejects wrong PIN and increments failed attempts counter', () async {
      final result1 = await repo.verifyPin(
        pin: '0000',
        deviceId: 'pos-dev-1',
      );
      expect(result1, isA<PinVerifyInvalid>());
      expect((result1 as PinVerifyInvalid).remainingAttempts, equals(4));
      expect(await repo.getFailedAttempts(), equals(1));

      final result2 = await repo.verifyPin(
        pin: '0000',
        deviceId: 'pos-dev-1',
      );
      expect((result2 as PinVerifyInvalid).remainingAttempts, equals(3));
      expect(await repo.getFailedAttempts(), equals(2));
    });

    test('locks PIN after 5 consecutive failed attempts', () async {
      for (int i = 1; i <= 4; i++) {
        final res = await repo.verifyPin(pin: '9999', deviceId: 'pos-dev-1');
        expect(res, isA<PinVerifyInvalid>());
      }
      expect(await repo.getFailedAttempts(), equals(4));
      expect(await repo.isLocked(), isFalse);

      // 5th attempt locks PIN
      final res5 = await repo.verifyPin(pin: '9999', deviceId: 'pos-dev-1');
      expect(res5, isA<PinVerifyLocked>());
      expect(await repo.getFailedAttempts(), equals(5));
      expect(await repo.isLocked(), isTrue);

      // Subsequent attempt with even the CORRECT PIN is locked
      final resAfter = await repo.verifyPin(pin: '1234', deviceId: 'pos-dev-1');
      expect(resAfter, isA<PinVerifyLocked>());
    });

    test('online login resets failed attempts and unlocks PIN', () async {
      // Lock it first
      for (int i = 0; i < 5; i++) {
        await repo.verifyPin(pin: '0000', deviceId: 'pos-dev-1');
      }
      expect(await repo.isLocked(), isTrue);

      // Simulate online login via recordOnlineLogin
      await repo.recordOnlineLogin(iat: nowSec + 100, deviceId: 'pos-dev-1');

      expect(await repo.isLocked(), isFalse);
      expect(await repo.getFailedAttempts(), equals(0));

      // Correct PIN now succeeds
      final res = await repo.verifyPin(pin: '1234', deviceId: 'pos-dev-1');
      expect(res, isA<PinVerifySuccess>());
    });

    test('3-day window: valid when <= 3 days (e.g. 2 days ago)', () async {
      final twoDaysAgo = nowSec - (2 * 24 * 3600);
      await repo.recordOnlineLogin(iat: twoDaysAgo, deviceId: 'pos-dev-1');

      expect(await repo.isExpired(), isFalse);
      expect(await repo.isPinAvailable(deviceRole: 'pos'), isTrue);

      final res = await repo.verifyPin(pin: '1234', deviceId: 'pos-dev-1');
      expect(res, isA<PinVerifySuccess>());
    });

    test('3-day window: expired when > 3 days (e.g. 4 days ago)', () async {
      final fourDaysAgo = nowSec - (4 * 24 * 3600);
      await repo.recordOnlineLogin(iat: fourDaysAgo, deviceId: 'pos-dev-1');

      expect(await repo.isExpired(), isTrue);
      expect(await repo.isPinAvailable(deviceRole: 'pos'), isFalse);

      final res = await repo.verifyPin(pin: '1234', deviceId: 'pos-dev-1');
      expect(res, isA<PinVerifyExpired>());
    });

    test('device role check: isPinAvailable is false for backoffice device',
        () async {
      expect(await repo.isPinAvailable(deviceRole: 'backoffice'), isFalse);
      expect(await repo.isPinAvailable(deviceRole: null), isFalse);
      expect(await repo.isPinAvailable(deviceRole: 'pos'), isTrue);
    });

    test('device binding: rejects verification on mismatched deviceId', () async {
      final res = await repo.verifyPin(
        pin: '1234',
        deviceId: 'different-device-99',
      );
      expect(res, isA<PinVerifyNotPos>());
    });
  });
}
