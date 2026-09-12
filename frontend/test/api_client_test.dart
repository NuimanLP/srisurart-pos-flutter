// Unit tests for ApiClient, Bearer token injection, 401 auto-refresh, and error parsing.

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';

class InMemoryTokenStorage implements TokenStorage {
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

void main() {
  late InMemoryTokenStorage tokenStorage;

  setUp(() {
    tokenStorage = InMemoryTokenStorage();
  });

  test('injects Authorization: Bearer <token> when authenticated', () async {
    tokenStorage.accessToken = 'valid-jwt-token';

    final mockClient = MockClient((req) async {
      expect(req.headers['authorization'], 'Bearer valid-jwt-token');
      expect(req.headers['content-type'], 'application/json');
      return http.Response(jsonEncode({'status': 'success', 'data': {'foo': 'bar'}}), 200);
    });

    final client = ApiClient(
      baseUrl: 'http://example.com',
      httpClient: mockClient,
      tokenStorage: tokenStorage,
    );

    final res = await client.get('/test');
    expect(res, {'foo': 'bar'});
  });

  test('does not inject Authorization header when skipAuth is true', () async {
    tokenStorage.accessToken = 'valid-jwt-token';

    final mockClient = MockClient((req) async {
      expect(req.headers.containsKey('authorization'), isFalse);
      return http.Response(jsonEncode({'status': 'success', 'data': 'ok'}), 200);
    });

    final client = ApiClient(
      baseUrl: 'http://example.com',
      httpClient: mockClient,
      tokenStorage: tokenStorage,
    );

    final res = await client.get('/public', skipAuth: true);
    expect(res, 'ok');
  });

  test('handles 401 by refreshing token and retrying request successfully', () async {
    tokenStorage.accessToken = 'expired-token';
    tokenStorage.refreshToken = 'good-refresh-token';

    int callCount = 0;

    final mockClient = MockClient((req) async {
      // 1. Initial request with expired token -> 401
      if (req.url.path == '/protected' && req.headers['authorization'] == 'Bearer expired-token') {
        callCount++;
        return http.Response(jsonEncode({'statusCode': 401, 'message': 'Token expired'}), 401);
      }

      // 2. Refresh endpoint call
      if (req.url.path == '/api/v1/auth/refresh') {
        final body = jsonDecode(req.body);
        expect(body['refreshToken'], 'good-refresh-token');
        return http.Response(
          jsonEncode({
            'accessToken': 'new-fresh-token',
            'refreshToken': 'new-refresh-token',
          }),
          200,
        );
      }

      // 3. Retried request with new fresh token -> 200
      if (req.url.path == '/protected' && req.headers['authorization'] == 'Bearer new-fresh-token') {
        callCount++;
        return http.Response(jsonEncode({'status': 'success', 'data': {'secret': 42}}), 200);
      }

      return http.Response('Not Found', 404);
    });

    final client = ApiClient(
      baseUrl: 'http://example.com',
      httpClient: mockClient,
      tokenStorage: tokenStorage,
    );

    final res = await client.get('/protected');
    expect(res, {'secret': 42});
    expect(callCount, 2);
    expect(tokenStorage.accessToken, 'new-fresh-token');
    expect(tokenStorage.refreshToken, 'new-refresh-token');
  });

  test('handles 429 RATE_LIMITED with Retry-After header', () async {
    final mockClient = MockClient((req) async {
      final body = jsonEncode({
        'status': 'error',
        'error': {
          'code': 'RATE_LIMITED',
          'message': 'ระบบกำลังทำงานหนัก กรุณารอสักครู่',
        },
      });
      return http.Response.bytes(
        utf8.encode(body),
        429,
        headers: {
          'retry-after': '45',
          'content-type': 'application/json; charset=utf-8',
        },
      );
    });

    final client = ApiClient(
      baseUrl: 'http://example.com',
      httpClient: mockClient,
      tokenStorage: tokenStorage,
    );

    try {
      await client.get('/heavy-load');
      fail('Expected ApiException');
    } on ApiException catch (e) {
      expect(e.statusCode, 429);
      expect(e.code, 'RATE_LIMITED');
      expect(e.retryAfterSeconds, 45);
      expect(e.thaiMessage, 'ระบบกำลังทำงานหนัก กรุณารอสักครู่');
    }
  });

  test('parses structured backend error envelope', () async {
    final mockClient = MockClient((req) async {
      final body = jsonEncode({
        'status': 'error',
        'error': {
          'code': 'INSUFFICIENT_STOCK',
          'message': 'สต็อกไม่พอ:\nผ้าเบรกหน้า: สต็อก 0 แต่ต้องการ 1',
          'details': {'productId': 'p1', 'requested': 1, 'stock': 0},
        },
      });
      return http.Response.bytes(
        utf8.encode(body),
        409,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    final client = ApiClient(
      baseUrl: 'http://example.com',
      httpClient: mockClient,
      tokenStorage: tokenStorage,
    );

    try {
      await client.post('/sales', body: {'items': []});
      fail('Expected ApiException');
    } on ApiException catch (e) {
      expect(e.statusCode, 409);
      expect(e.code, 'INSUFFICIENT_STOCK');
      expect(e.serverMessage, contains('สต็อกไม่พอ'));
      expect(e.details['productId'], 'p1');
      expect(e.thaiMessage, 'สต็อกไม่พอ:\nผ้าเบรกหน้า: สต็อก 0 แต่ต้องการ 1');
    }
  });

  test('five concurrent reads on an expired token cause ONE refresh', () async {
    // #54 AC1. Every screen is a FutureBuilder fed from initState, so a tab
    // opened after the access token expired fires several reads at once. Without
    // the single-flight lock each one refreshes, and the server's refresh-token
    // rotation means the last winner invalidates the tokens the other four are
    // still holding: five reads, one usable session, four spurious logouts.
    tokenStorage.accessToken = 'expired';
    tokenStorage.refreshToken = 'refresh-1';

    var refreshCalls = 0;
    var refreshInFlight = 0;
    final client = ApiClient(
      baseUrl: 'http://server.test',
      tokenStorage: tokenStorage,
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('/auth/refresh')) {
          refreshCalls++;
          refreshInFlight++;
          // Yield, so a second refresh started concurrently would overlap this
          // one and be visible rather than racing past.
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(refreshInFlight, 1, reason: 'refreshes must not overlap');
          refreshInFlight--;
          return http.Response(
            jsonEncode({'accessToken': 'fresh', 'refreshToken': 'refresh-2'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        final auth = req.headers['Authorization'];
        if (auth != 'Bearer fresh') {
          return http.Response(
            jsonEncode({
              'status': 'error',
              'error': {'code': 'UNAUTHENTICATED', 'message': 'token expired'},
            }),
            401,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({'status': 'success', 'data': []}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final results = await Future.wait([
      for (var i = 0; i < 5; i++) client.get('/api/v1/products'),
    ]);

    expect(results, hasLength(5));
    expect(refreshCalls, 1, reason: 'the single-flight lock is the whole point');
    expect(tokenStorage.accessToken, 'fresh');
  });

  test('a refused refresh ends the session and says nothing to the counter', () async {
    // #54 AC3. The 04:00 case: the refresh token has aged out, so there is no
    // way back but a fresh login. What must NOT happen is an error dialog about
    // token lifetimes on a counter screen.
    tokenStorage.accessToken = 'expired';
    tokenStorage.refreshToken = 'refresh-too-old';

    var expired = 0;
    final client = ApiClient(
      baseUrl: 'http://server.test',
      tokenStorage: tokenStorage,
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('/auth/refresh')) {
          return http.Response(
            jsonEncode({
              'status': 'error',
              'error': {'code': 'UNAUTHENTICATED', 'message': 'refresh expired'},
            }),
            401,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'status': 'error',
            'error': {'code': 'UNAUTHENTICATED', 'message': 'token expired'},
          }),
          401,
          headers: {'content-type': 'application/json'},
        );
      }),
    )..onSessionExpired = () => expired++;

    await expectLater(
      () => client.get('/api/v1/products'),
      throwsA(isA<ApiException>()),
    );

    expect(expired, 1, reason: 'the hook is what puts the app back on login');
    expect(tokenStorage.accessToken, isNull);
    expect(tokenStorage.refreshToken, isNull);
  });
}
