// Unit tests for ApiClient, Bearer token injection, 401 auto-refresh, and error parsing.

import 'dart:async';
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

  group('#161 a refresh whose fate is unknown keeps the session', () {
    const connectionSentence = 'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์';

    http.Response json(Object body, int status, {Map<String, String>? headers}) =>
        http.Response.bytes(utf8.encode(jsonEncode(body)), status,
            headers: {'content-type': 'application/json; charset=utf-8', ...?headers});

    http.Response unauthenticated() => json({
          'status': 'error',
          'error': {'code': 'UNAUTHENTICATED', 'message': 'token expired'},
        }, 401);

    /// A client whose API answers 401 to anything but `Bearer fresh`, and whose
    /// `/auth/refresh` is [refresh]. Counts refreshes and session expiries.
    ({ApiClient client, int Function() refreshes, int Function() expiries}) build(
      Future<http.Response> Function(http.Request req) refresh,
    ) {
      tokenStorage.accessToken = 'expired';
      tokenStorage.refreshToken = 'refresh-1';
      var refreshes = 0;
      var expiries = 0;
      final client = ApiClient(
        baseUrl: 'http://server.test',
        tokenStorage: tokenStorage,
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/auth/refresh')) {
            refreshes++;
            return refresh(req);
          }
          if (req.headers['Authorization'] != 'Bearer fresh') return unauthenticated();
          return json({'status': 'success', 'data': {'ok': true}}, 200);
        }),
      )..onSessionExpired = () => expiries++;
      return (client: client, refreshes: () => refreshes, expiries: () => expiries);
    }

    void expectSessionKept(int expiries) {
      expect(expiries, 0, reason: 'nothing refused the refresh token');
      expect(tokenStorage.accessToken, 'expired');
      expect(tokenStorage.refreshToken, 'refresh-1');
    }

    test('socket failure: the transport error reaches the caller, tokens kept', () async {
      final t = build((_) async => throw http.ClientException('Connection reset'));

      await expectLater(t.client.get('/api/v1/products'), throwsA(isA<http.ClientException>()));
      expectSessionKept(t.expiries());
    });

    test('timeout: the TimeoutException reaches the caller, tokens kept', () async {
      final t = build((_) async => throw TimeoutException('refresh'));

      await expectLater(t.client.get('/api/v1/products'), throwsA(isA<TimeoutException>()));
      expectSessionKept(t.expiries());
    });

    for (final status in [500, 502, 504]) {
      test('$status from refresh: a non-verdict connection error, tokens kept', () async {
        final t = build((_) async => http.Response('<html>Bad Gateway</html>', status));

        await expectLater(
          t.client.get('/api/v1/products'),
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', status)
              .having((e) => e.thaiMessage, 'thaiMessage', connectionSentence)),
        );
        expectSessionKept(t.expiries());
      });
    }

    test('429 from refresh: RATE_LIMITED with Retry-After, tokens kept', () async {
      final t = build((_) async => json({
            'status': 'error',
            'error': {'code': 'RATE_LIMITED', 'message': 'Too many requests'},
          }, 429, headers: {'retry-after': '30'}));

      await expectLater(
        t.client.get('/api/v1/products'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 429)
            .having((e) => e.retryAfterSeconds, 'retryAfterSeconds', 30)
            .having((e) => e.thaiMessage, 'thaiMessage', 'ระบบกำลังทำงานหนัก กรุณารอสักครู่')),
      );
      expectSessionKept(t.expiries());
    });

    test('a 200 the client cannot read is not a refusal', () async {
      final t = build((_) async => http.Response('<html>captive portal</html>', 200));

      await expectLater(t.client.get('/api/v1/products'), throwsA(isA<http.ClientException>()));
      expectSessionKept(t.expiries());
    });

    test('401 from refresh ends the session', () async {
      final t = build((_) async => json({
            'status': 'error',
            'error': {'code': 'UNAUTHENTICATED', 'message': 'Device is retired'},
          }, 401));

      await expectLater(
        t.client.get('/api/v1/products'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401)),
      );
      expect(t.expiries(), 1);
      expect(tokenStorage.accessToken, isNull);
      expect(tokenStorage.refreshToken, isNull);
    });

    test('403 from refresh (suspended shop) ends the session', () async {
      final t = build((_) async => json({
            'status': 'error',
            'error': {'code': 'TENANT_SUSPENDED', 'message': 'ร้านนี้ถูกระงับการใช้งาน'},
          }, 403));

      await expectLater(t.client.get('/api/v1/products'), throwsA(isA<ApiException>()));
      expect(t.expiries(), 1);
      expect(tokenStorage.accessToken, isNull);
      expect(tokenStorage.refreshToken, isNull);
    });

    test('the real server\'s enveloped refresh reply refreshes (not a sign-out)', () async {
      // `EnvelopeInterceptor` wraps /auth/refresh like every route. Parsing it
      // flat threw inside the old catch-all, which then cleared the tokens: every
      // successful refresh against the real server signed the cashier out.
      final t = build((_) async => json({
            'status': 'success',
            'data': {'accessToken': 'fresh', 'refreshToken': 'refresh-2'},
          }, 200));

      expect(await t.client.get('/api/v1/products'), {'ok': true});
      expect(t.expiries(), 0);
      expect(tokenStorage.accessToken, 'fresh');
      expect(tokenStorage.refreshToken, 'refresh-2');
    });

    test('a lost reply after the server rotated: the kept token refreshes on retry', () async {
      // ADR-0009: the server reissues a new jti with the same exp and keeps no
      // denylist, so the old refresh token is still accepted. Model that.
      var drop = true;
      final t = build((req) async {
        expect(jsonDecode(req.body)['refreshToken'], 'refresh-1');
        if (drop) {
          drop = false;
          throw http.ClientException('reply lost');
        }
        return json({
          'status': 'success',
          'data': {'accessToken': 'fresh', 'refreshToken': 'refresh-2'},
        }, 200);
      });

      await expectLater(t.client.get('/api/v1/products'), throwsA(isA<http.ClientException>()));
      expect(await t.client.get('/api/v1/products'), {'ok': true});
      expect(t.refreshes(), 2);
      expect(t.expiries(), 0);
      expect(tokenStorage.refreshToken, 'refresh-2');
    });

    test('concurrent callers share one failed refresh and all see the same error', () async {
      final gate = Completer<void>();
      final t = build((_) async {
        await gate.future;
        return http.Response('Bad Gateway', 502);
      });

      final calls = [
        for (var i = 0; i < 5; i++)
          t.client.get('/api/v1/products').then<Object?>((v) => v, onError: (Object e) => e),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete();
      final results = await Future.wait(calls);

      expect(t.refreshes(), 1);
      for (final r in results) {
        expect(r, isA<ApiException>().having((e) => e.statusCode, 'statusCode', 502));
      }
      expectSessionKept(t.expiries());
    });

    test('concurrent callers share one refused refresh: one expiry, all 401', () async {
      final gate = Completer<void>();
      final t = build((_) async {
        await gate.future;
        return unauthenticated();
      });

      final calls = [
        for (var i = 0; i < 5; i++)
          t.client.get('/api/v1/products').then<Object?>((v) => v, onError: (Object e) => e),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete();
      final results = await Future.wait(calls);

      expect(t.refreshes(), 1);
      expect(t.expiries(), 1, reason: 'one refusal, one trip to the login form');
      for (final r in results) {
        expect(r, isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401));
      }
    });

    test('a 401 that lands after another caller refreshed retries without refreshing', () async {
      tokenStorage.accessToken = 'expired';
      tokenStorage.refreshToken = 'refresh-1';
      var refreshes = 0;
      final slow = Completer<void>();
      final client = ApiClient(
        baseUrl: 'http://server.test',
        tokenStorage: tokenStorage,
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/auth/refresh')) {
            refreshes++;
            return json({
              'status': 'success',
              'data': {'accessToken': 'fresh', 'refreshToken': 'refresh-$refreshes'},
            }, 200);
          }
          if (req.url.path.endsWith('/slow') && req.headers['Authorization'] == 'Bearer expired') {
            await slow.future;
          }
          if (req.headers['Authorization'] != 'Bearer fresh') return unauthenticated();
          return json({'status': 'success', 'data': req.url.path}, 200);
        }),
      );

      final slowCall = client.get('/slow');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await client.get('/fast'), '/fast');
      slow.complete();
      expect(await slowCall, '/slow');
      expect(refreshes, 1);
    });
  });

  group('#183 request timeout', () {
    /// A response that never arrives — the hung socket the timeout exists for.
    Future<http.Response> hang() => Completer<http.Response>().future;

    const short = Duration(milliseconds: 200);

    test('a GET that hangs fails as a transport error after readTimeout, not an ApiException', () async {
      final client = ApiClient(
        baseUrl: 'http://server.test',
        httpClient: MockClient((_) => hang()),
        readTimeout: short,
      );

      await expectLater(
        client.get('/api/v1/products'),
        throwsA(allOf(isA<ApiTimeoutException>(), isA<http.ClientException>(), isNot(isA<ApiException>()))),
      );
    });

    test('reads and writes have separate timeouts', () async {
      final client = ApiClient(
        baseUrl: 'http://server.test',
        httpClient: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return http.Response(jsonEncode({'status': 'success', 'data': {'ok': true}}), 201);
        }),
        readTimeout: short,
        writeTimeout: const Duration(seconds: 5),
      );

      await expectLater(client.get('/api/v1/products'), throwsA(isA<http.ClientException>()));
      expect(await client.post('/api/v1/sales', body: {}), {'ok': true});
    });

    test('defaults: 15 s for reads, 40 s for writes', () {
      final client = ApiClient(baseUrl: 'http://server.test', httpClient: MockClient((_) => hang()));
      expect(client.readTimeout, const Duration(seconds: 15));
      expect(client.writeTimeout, const Duration(seconds: 40));
    });

    test('a timed-out POST is sent once — never retried by the client', () async {
      var sends = 0;
      final client = ApiClient(
        baseUrl: 'http://server.test',
        tokenStorage: tokenStorage..accessToken = 'a'..refreshToken = 'r',
        httpClient: MockClient((_) {
          sends++;
          return hang();
        }),
        writeTimeout: short,
      );

      await expectLater(
        client.post('/api/v1/sales', body: {}, headers: {'Idempotency-Key': 'k'}),
        throwsA(isA<http.ClientException>()),
      );
      expect(sends, 1);
    });

    test('a timeout on /auth/refresh keeps both tokens, and uses readTimeout (#161)', () async {
      tokenStorage.accessToken = 'expired';
      tokenStorage.refreshToken = 'refresh-1';
      var expiries = 0;
      final client = ApiClient(
        baseUrl: 'http://server.test',
        tokenStorage: tokenStorage,
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/auth/refresh')) return hang();
          return http.Response(
            jsonEncode({'status': 'error', 'error': {'code': 'UNAUTHENTICATED', 'message': 'expired'}}),
            401,
          );
        }),
        readTimeout: short,
        // A write timeout the test would never outlive: the refresh must not use it.
        writeTimeout: const Duration(minutes: 5),
      )..onSessionExpired = () => expiries++;

      await expectLater(client.post('/api/v1/sales', body: {}), throwsA(isA<ApiTimeoutException>()));
      expect(expiries, 0);
      expect(tokenStorage.accessToken, 'expired');
      expect(tokenStorage.refreshToken, 'refresh-1');
    });

    test('two requests waiting on one hung refresh both fail; the next call refreshes afresh', () async {
      tokenStorage.accessToken = 'expired';
      tokenStorage.refreshToken = 'refresh-1';
      var expiries = 0;
      var refreshes = 0;
      final client = ApiClient(
        baseUrl: 'http://server.test',
        tokenStorage: tokenStorage,
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/auth/refresh')) {
            refreshes++;
            if (refreshes == 1) return hang();
            return http.Response(
              jsonEncode({'status': 'success', 'data': {'accessToken': 'fresh', 'refreshToken': 'refresh-2'}}),
              200,
            );
          }
          if (req.headers['Authorization'] == 'Bearer fresh') {
            return http.Response(jsonEncode({'status': 'success', 'data': {'ok': true}}), 200);
          }
          return http.Response(
            jsonEncode({'status': 'error', 'error': {'code': 'UNAUTHENTICATED', 'message': 'expired'}}),
            401,
          );
        }),
        readTimeout: short,
      )..onSessionExpired = () => expiries++;

      final a = client.get('/api/v1/products');
      final b = client.get('/api/v1/customers');
      await Future.wait([
        expectLater(a, throwsA(isA<ApiTimeoutException>())),
        expectLater(b, throwsA(isA<ApiTimeoutException>())),
      ]);
      expect(refreshes, 1, reason: 'B must wait on A\'s refresh, not start its own');
      expect(expiries, 0);
      expect(tokenStorage.accessToken, 'expired');
      expect(tokenStorage.refreshToken, 'refresh-1');

      expect(await client.get('/api/v1/products'), {'ok': true});
      expect(refreshes, 2, reason: 'the timed-out refresh must not stay cached');
    });
  });

  group('#200 AbortableRequest on timeout', () {
    const short = Duration(milliseconds: 200);

    test('after timeout the underlying request is aborted (#200)', () async {
      final abortedCompleter = Completer<void>();
      var isAbortable = false;

      final client = ApiClient(
        baseUrl: 'http://server.test',
        httpClient: MockClient.streaming((req, bodyStream) async {
          if (req case http.Abortable(:final abortTrigger?)) {
            isAbortable = true;
            abortTrigger.then((_) {
              if (!abortedCompleter.isCompleted) {
                abortedCompleter.complete();
              }
            });
          }
          return Completer<http.StreamedResponse>().future;
        }),
        readTimeout: short,
      );

      await expectLater(
        client.get('/api/v1/products'),
        throwsA(allOf(
          isA<ApiTimeoutException>(),
          isA<http.ClientException>(),
          isNot(isA<ApiException>()),
        )),
      );

      expect(isAbortable, isTrue, reason: 'Request must be an AbortableRequest');
      await expectLater(
        abortedCompleter.future.timeout(const Duration(seconds: 1)),
        completes,
        reason: 'abortTrigger must complete when the request times out',
      );
    });

    test('when client completes with RequestAbortedException, ApiTimeoutException still surfaces (#200)', () async {
      final aborted = Completer<void>();
      final client = ApiClient(
        baseUrl: 'http://server.test',
        httpClient: MockClient.streaming((req, bodyStream) async {
          final completer = Completer<http.StreamedResponse>();
          if (req case http.Abortable(:final abortTrigger?)) {
            abortTrigger.then((_) {
              if (!aborted.isCompleted) aborted.complete();
              completer.completeError(http.RequestAbortedException(req.url));
            });
          }
          return completer.future;
        }),
        readTimeout: short,
      );

      await expectLater(
        client.get('/api/v1/products'),
        throwsA(allOf(
          isA<ApiTimeoutException>(),
          isA<http.ClientException>(),
          isNot(isA<ApiException>()),
        )),
      );
      await expectLater(
        aborted.future.timeout(const Duration(seconds: 1)),
        completes,
        reason: 'abortTrigger must have been triggered',
      );
    });

    test('a successful request does not trigger abort (#200)', () async {
      var aborted = false;
      final client = ApiClient(
        baseUrl: 'http://server.test',
        httpClient: MockClient.streaming((req, bodyStream) async {
          if (req case http.Abortable(:final abortTrigger?)) {
            abortTrigger.then((_) => aborted = true);
          }
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode({'status': 'success', 'data': {'ok': true}}))),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        readTimeout: const Duration(seconds: 5),
      );

      final result = await client.get('/api/v1/products');
      expect(result, {'ok': true});
      expect(aborted, isFalse);
    });

    test('a 401 retry creates a new AbortableRequest with its own abortTrigger (#200)', () async {
      tokenStorage.accessToken = 'expired';
      tokenStorage.refreshToken = 'good-refresh-token';

      final abortTriggers = <Future<void>>[];
      var callCount = 0;

      final client = ApiClient(
        baseUrl: 'http://server.test',
        tokenStorage: tokenStorage,
        httpClient: MockClient.streaming((req, bodyStream) async {
          if (req.url.path.endsWith('/auth/refresh')) {
            return http.StreamedResponse(
              Stream.value(utf8.encode(jsonEncode({
                'status': 'success',
                'data': {'accessToken': 'new-token', 'refreshToken': 'new-refresh'},
              }))),
              200,
              headers: {'content-type': 'application/json'},
            );
          }

          if (req case http.Abortable(:final abortTrigger?)) {
            abortTriggers.add(abortTrigger);
          }

          callCount++;
          if (callCount == 1) {
            return http.StreamedResponse(
              Stream.value(utf8.encode(jsonEncode({'statusCode': 401, 'message': 'Token expired'}))),
              401,
              headers: {'content-type': 'application/json'},
            );
          }

          // Second request hangs and times out
          return Completer<http.StreamedResponse>().future;
        }),
        readTimeout: short,
      );

      await expectLater(
        client.get('/api/v1/products'),
        throwsA(isA<ApiTimeoutException>()),
      );

      expect(callCount, 2);
      expect(abortTriggers.length, 2);
      expect(abortTriggers[0], isNot(same(abortTriggers[1])), reason: 'Retry must have its own abortTrigger');

      // The first request (401) was not aborted because it completed normally
      var firstAborted = false;
      abortTriggers[0].then((_) => firstAborted = true);

      // The second request (hung) was aborted on timeout
      final secondAborted = Completer<void>();
      abortTriggers[1].then((_) => secondAborted.complete());

      await expectLater(secondAborted.future.timeout(const Duration(seconds: 1)), completes);
      expect(firstAborted, isFalse);
    });
  });
}
