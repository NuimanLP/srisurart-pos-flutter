// Base HTTP Client with automatic Bearer token injection, 401 refresh interceptor,
// 429 rate-limiting detection, and standardized error envelope parsing.

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../data/storage/token_storage.dart';
import '../../domain/models/auth_models.dart';
import 'api_exception.dart';

class ApiClient {
  ApiClient({
    String? baseUrl,
    http.Client? httpClient,
    this.tokenStorage,
    this.onSessionExpired,
    this.readTimeout = defaultReadTimeout,
    this.writeTimeout = defaultWriteTimeout,
  })  : baseUrl = (baseUrl ?? const String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:3000'))
            .replaceAll(RegExp(r'/+$'), ''),
        _client = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _client;
  final TokenStorage? tokenStorage;

  /// How long a `GET` — and `/auth/refresh` — waits for its response before
  /// failing (#183).
  ///
  /// Reads are safe to repeat and nothing in the API takes longer than a few
  /// hundred milliseconds to read, so the counter is told sooner. A refresh is
  /// safe to repeat too (ADR-0009: no denylist, no reuse detection).
  static const Duration defaultReadTimeout = Duration(seconds: 15);

  /// How long every other method — the money/stock writes — waits before
  /// failing (#183).
  ///
  /// Above nginx's own worst case (`server/docker/nginx/nginx.conf`):
  /// `proxy_next_upstream error timeout` retries a failed 2 s connect, so a
  /// slow API answers through nginx after about 2 + 2 + 30 s. At 40 s the
  /// proxy's own 504 normally ends the wait first, and this only fires when the
  /// link to nginx is what hung. Waiting that long for a write is deliberate —
  /// a real answer is worth more to the counter than an early "fate unknown".
  static const Duration defaultWriteTimeout = Duration(seconds: 40);

  final Duration readTimeout;
  final Duration writeTimeout;

  /// Called when the refresh token is gone or the server refuses it — the
  /// session is over and only a fresh login can continue.
  ///
  /// 🔴 Mutable because the thing that must react to it, `AuthCubit`, is built
  /// from the `AuthRepository` this client already backs, so it cannot be passed
  /// to the constructor. Before this was wired, `_executeRefresh` called a hook
  /// nobody had set: the tokens were cleared and every later request 401'd, but
  /// no state anywhere said the session had ended.
  void Function()? onSessionExpired;

  Future<bool>? _refreshFuture;
  int _refreshFutureSession = 0;

  /// Which signed-in person the stored tokens belong to. Bumped by
  /// [beginSession] on every login and logout (never by a refresh, which is
  /// the same person). Anything that started under an older number — a
  /// request, a refresh — belongs to someone who has since left the till: its
  /// 401 is not retried, its refreshed tokens are not stored, and its refusal
  /// does not sign anyone out. Without this a refresh sent with the previous
  /// person's token and answered after the next login overwrote the new
  /// session, and the new person then acted as the previous one.
  int _session = 0;

  /// The stored tokens now belong to a different person (login or logout).
  /// Called by `AuthRepository` before it writes or clears a session.
  void beginSession() => _session++;

  Uri _buildUri(String path, [Map<String, dynamic>? queryParameters]) {
    final cleanPath = path.startsWith('/') ? path : '/$path';
    final fullUrl = '$baseUrl$cleanPath';
    final uri = Uri.parse(fullUrl);
    if (queryParameters == null || queryParameters.isEmpty) {
      return uri;
    }
    final cleanParams = queryParameters.map((k, v) => MapEntry(k, v?.toString() ?? ''));
    return uri.replace(queryParameters: cleanParams);
  }

  /// [session]: the session the request was started for. The token is
  /// attached only if that is still the current session once it has been read
  /// — otherwise [_StaleSession] is thrown and the request never leaves, so a
  /// login landing mid-request can never send it as the new person.
  Future<Map<String, String>> _buildHeaders({
    Map<String, String>? extraHeaders,
    bool skipAuth = false,
    int? session,
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

    if (!skipAuth && tokenStorage != null) {
      final token = await tokenStorage!.getAccessToken();
      if (session != null && session != _session) throw const _StaleSession();
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    }

    if (extraHeaders != null) {
      headers.addAll(extraHeaders);
    }
    return headers;
  }

  Future<dynamic> get(
    String path, {
    Map<String, String>? headers,
    Map<String, dynamic>? queryParameters,
    bool skipAuth = false,
  }) {
    return _send(
      'GET',
      path,
      headers: headers,
      queryParameters: queryParameters,
      skipAuth: skipAuth,
      timeout: readTimeout,
    );
  }

  Future<dynamic> post(
    String path, {
    dynamic body,
    Map<String, String>? headers,
    bool skipAuth = false,
  }) {
    return _send(
      'POST',
      path,
      body: body,
      headers: headers,
      skipAuth: skipAuth,
      timeout: writeTimeout,
    );
  }

  Future<dynamic> put(
    String path, {
    dynamic body,
    Map<String, String>? headers,
    bool skipAuth = false,
  }) {
    return _send(
      'PUT',
      path,
      body: body,
      headers: headers,
      skipAuth: skipAuth,
      timeout: writeTimeout,
    );
  }

  Future<dynamic> patch(
    String path, {
    dynamic body,
    Map<String, String>? headers,
    bool skipAuth = false,
  }) {
    return _send(
      'PATCH',
      path,
      body: body,
      headers: headers,
      skipAuth: skipAuth,
      timeout: writeTimeout,
    );
  }

  Future<dynamic> delete(
    String path, {
    Map<String, String>? headers,
    bool skipAuth = false,
  }) {
    return _send(
      'DELETE',
      path,
      headers: headers,
      skipAuth: skipAuth,
      timeout: writeTimeout,
    );
  }

  Future<PaginatedResult> getPaginated(
    String path, {
    Map<String, dynamic>? queryParameters,
    Map<String, String>? headers,
    bool skipAuth = false,
  }) async {
    final response = await _executeWithRetry(
      (abortTrigger, session) async {
        final uri = _buildUri(path, queryParameters);
        final h = await _buildHeaders(
          extraHeaders: headers,
          skipAuth: skipAuth,
          session: session,
        );
        return _sendAbortable(
          'GET',
          uri,
          headers: h,
          abortTrigger: abortTrigger,
        );
      },
      path: path,
      skipAuth: skipAuth,
      timeout: readTimeout,
    );

    final statusCode = response.statusCode;
    if (statusCode >= 200 && statusCode < 300) {
      final body = response.body.trim();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final data = decoded['data'] is List ? (decoded['data'] as List) : <dynamic>[];
        final meta = decoded['meta'] is Map<String, dynamic>
            ? (decoded['meta'] as Map<String, dynamic>)
            : <String, dynamic>{};
        return PaginatedResult(data: data, meta: meta);
      }
    }
    return _handleResponse(response) as PaginatedResult;
  }

  Future<http.Response> _sendAbortable(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    String? body,
    required Future<void> abortTrigger,
  }) async {
    final request = http.AbortableRequest(method, uri, abortTrigger: abortTrigger);
    if (headers != null) {
      request.headers.addAll(headers);
    }
    if (body != null) {
      request.body = body;
    }
    final streamed = await _client.send(request);
    return http.Response.fromStream(streamed);
  }

  Future<dynamic> _send(
    String method,
    String path, {
    dynamic body,
    Map<String, String>? headers,
    Map<String, dynamic>? queryParameters,
    bool skipAuth = false,
    required Duration timeout,
  }) {
    return _sendWithRetry(
      (abortTrigger, session) async {
        final uri = _buildUri(path, queryParameters);
        final h = await _buildHeaders(
          extraHeaders: headers,
          skipAuth: skipAuth,
          session: session,
        );
        final encodedBody = body != null ? (body is String ? body : jsonEncode(body)) : null;
        return _sendAbortable(
          method,
          uri,
          headers: h,
          body: encodedBody,
          abortTrigger: abortTrigger,
        );
      },
      path: path,
      skipAuth: skipAuth,
      timeout: timeout,
    );
  }

  Future<http.Response> _executeWithRetry(
    Future<http.Response> Function(Future<void> abortTrigger, int session)
        rawExecute, {
    required String path,
    required bool skipAuth,
    required Duration timeout,
  }) async {
    // Every send — the first and the one retry after a 401 — gets its own
    // [timeout], and the refresh in between gets [readTimeout]; so one call
    // waits at most 2 × timeout + readTimeout. A timeout is never retried
    // here: it throws out of this method.
    //
    // [session] is captured before the first await: every send attaches a
    // token only while it is still current (see [_buildHeaders]). A send whose
    // session ended meanwhile never leaves and reads as a 401 — the same
    // verdict the server gives a request with no valid token.
    final session = _session;
    Future<http.Response> execute() async {
      try {
        return await _withTimeout(
          (abortTrigger) => rawExecute(abortTrigger, session),
          timeout,
          path,
        );
      } on _StaleSession {
        return _staleSessionResponse();
      }
    }

    final sentWith = await tokenStorage?.getAccessToken();
    final response = await execute();

    // 401 Unauthorized handling & automatic token refresh
    if (response.statusCode == 401 && !skipAuth && !_isAuthPath(path)) {
      // Sent for someone who has since logged out: never resend it as
      // whoever is signed in now. It fails with its own 401.
      if (session != _session) return response;
      // A concurrent caller already refreshed while this request was on the
      // wire: retry with the token it stored instead of refreshing again.
      final current = await tokenStorage?.getAccessToken();
      if (current != null && current.isNotEmpty && current != sentWith) {
        return await execute();
      }
      // Throws when the refresh's fate is unknown (transport failure, 5xx,
      // 429) — see [_executeRefresh].
      final refreshed = await _handleTokenRefresh();
      if (refreshed && session == _session) {
        return await execute();
      }
    }

    return response;
  }

  Future<dynamic> _sendWithRetry(
    Future<http.Response> Function(Future<void> abortTrigger, int session)
        execute, {
    required String path,
    required bool skipAuth,
    required Duration timeout,
  }) async {
    final response = await _executeWithRetry(
      execute,
      path: path,
      skipAuth: skipAuth,
      timeout: timeout,
    );
    return _handleResponse(response);
  }

  /// Fails [send] with an [ApiTimeoutException] — an [http.ClientException],
  /// the class a dropped socket raises — once [timeout] has passed with no
  /// response (#183).
  ///
  /// 🔴 A timeout is NOT a verdict. The request may have reached the server and
  /// committed; only the reply is missing. So it must never surface as an
  /// [ApiException]: `isVerdict` would read a 4xx-looking one as an answer,
  /// `PendingWrites` would forget the bill's id and `Idempotency-Key`, and the
  /// counter's second press would ring the bill up twice. As a transport error
  /// it takes exactly the path a lost socket takes everywhere — the attempt
  /// stays parked, the refresh keeps both tokens.
  ///
  /// The timed-out request is cancelled via [http.AbortableRequest] so an
  /// abandoned XHR does not keep holding a browser connection slot (#200).
  Future<http.Response> _withTimeout(
    Future<http.Response> Function(Future<void> abortTrigger) send,
    Duration timeout,
    String path,
  ) {
    final abortCompleter = Completer<void>();
    final uri = _buildUri(path);
    final responseFuture = send(abortCompleter.future);
    return responseFuture.timeout(
      timeout,
      onTimeout: () {
        if (!abortCompleter.isCompleted) {
          abortCompleter.complete();
        }
        responseFuture.ignore();
        throw ApiTimeoutException(timeout, uri);
      },
    );
  }

  bool _isAuthPath(String path) {
    return path.contains('/auth/token') ||
        path.contains('/auth/refresh') ||
        path.contains('/auth/device');
  }

  Future<bool> _handleTokenRefresh() async {
    if (tokenStorage == null) return false;

    // Concurrency lock: reuse the ongoing refresh — but only one made for the
    // same person. A refresh still in flight for the previous person is left
    // to fail on its own; this session starts its own.
    final pending = _refreshFuture;
    if (pending != null && _refreshFutureSession == _session) {
      return pending;
    }

    final future = _executeRefresh();
    _refreshFuture = future;
    _refreshFutureSession = _session;
    try {
      return await future;
    } finally {
      if (identical(_refreshFuture, future)) _refreshFuture = null;
    }
  }

  /// Refreshes the token pair. `true` = refreshed; `false` = the session is
  /// over (tokens cleared, [onSessionExpired] fired); **throws** when the
  /// refresh's fate is unknown.
  ///
  /// 🔴 Only a server refusal ends the session: `401`/`403` from
  /// `/auth/refresh` (expired past 04:00, user deactivated, device retired,
  /// shop suspended — ADR-0009). Everything else — a dropped socket, a timeout,
  /// a 5xx (nginx's own 502/504 included), a 429, a reply we cannot parse —
  /// says nothing about the refresh token, which is still valid, so the tokens
  /// are kept and the ORIGINAL request fails as a connection error. The same
  /// rule as `isVerdict` for writes (#161): clearing here signed a cashier out
  /// mid-shift on a flaky shop network.
  ///
  /// Rotation is safe to retry: the server reissues a refresh token with a new
  /// `jti` but the same `exp`, and keeps no denylist or reuse detection
  /// (ADR-0009 dropped both), so the token kept after a lost reply still works.
  Future<bool> _executeRefresh() async {
    final storage = tokenStorage;
    if (storage == null) return false;
    final session = _session;
    final currentRefreshToken = await storage.getRefreshToken();
    if (currentRefreshToken == null || currentRefreshToken.isEmpty) {
      await _expireSession(storage, session);
      return false;
    }
    // #558: a session signed for a device (`did`) whose device token is no
    // longer stored (an IndexedDB entry cleared or evicted mid-session) is
    // over — the server would keep refreshing it as that till until 04:00,
    // while this browser can no longer push its outbox or log in as it.
    // Ending the session keeps the local DB and its outbox (clearAuthTokens).
    if (JwtClaims.tryParse(currentRefreshToken)?.did != null) {
      final deviceToken = await storage.getDeviceToken();
      if (deviceToken == null || deviceToken.isEmpty) {
        await _expireSession(storage, session);
        return false;
      }
    }

    // A transport failure propagates as-is (ClientException, TimeoutException…):
    // it is what the original request would have thrown had its own socket
    // dropped, and every caller already reads it as "the server never answered".
    // A timeout is one of those (#183) — it keeps both tokens.
    const refreshPath = '/api/v1/auth/refresh';
    final response = await _withTimeout(
      (abortTrigger) async => _sendAbortable(
        'POST',
        _buildUri(refreshPath),
        headers: await _buildHeaders(skipAuth: true),
        body: jsonEncode({'refreshToken': currentRefreshToken}),
        abortTrigger: abortTrigger,
      ),
      readTimeout,
      refreshPath,
    );
    final status = response.statusCode;

    if (status == 401 || status == 403) {
      await _expireSession(storage, session);
      return false;
    }

    if (status >= 200 && status < 300) {
      final AuthTokens tokens;
      try {
        final decoded = jsonDecode(response.body);
        // The server wraps every success in `{status: 'success', data}`
        // (EnvelopeInterceptor); a flat body is accepted too.
        final json = decoded is Map<String, dynamic> && decoded['data'] is Map<String, dynamic>
            ? decoded['data'] as Map<String, dynamic>
            : decoded as Map<String, dynamic>;
        tokens = AuthTokens.fromJson(json);
      } catch (_) {
        // A 200 we cannot read (a captive portal's HTML page, say) is not a
        // refusal either.
        throw http.ClientException('Unreadable refresh response', response.request?.url);
      }
      // The person who sent this refresh logged out while it was on the wire:
      // its tokens are theirs, never the new session's. Drop them.
      if (session != _session) return false;
      await storage.setAccessToken(tokens.accessToken);
      await storage.setRefreshToken(tokens.refreshToken);
      return true;
    }

    if (status >= 500) {
      // No code and no server text: a proxy's 5xx body is HTML, and the empty
      // code resolves to ServerErrorResolver's connection sentence.
      throw ApiException(statusCode: status, code: '');
    }
    // 429 (RATE_LIMITED, with Retry-After) and any other 4xx: the refresh's
    // own error, tokens untouched.
    _handleResponse(response);
    throw ApiException(statusCode: status, code: '');
  }

  /// Ends [session] — and only that one.
  ///
  /// A refusal can land after the counter logged out (and maybe a new person
  /// logged in). Clearing then would sign the new person out, or turn a
  /// deliberate logout into an "expiry" that keeps `?from=`. So a refusal for
  /// an older session changes nothing; the stale request fails with its 401.
  Future<void> _expireSession(TokenStorage storage, int session) async {
    if (session != _session) return;
    await storage.clearAuthTokens();
    if (session != _session) return;
    _session++;
    onSessionExpired?.call();
  }

  dynamic _handleResponse(http.Response response) {
    final statusCode = response.statusCode;
    final body = response.body.trim();

    dynamic decodedJson;
    if (body.isNotEmpty) {
      try {
        decodedJson = jsonDecode(body);
      } catch (_) {
        decodedJson = body;
      }
    }

    // 304 Not Modified (e.g. conditional GET with If-None-Match)
    if (statusCode == 304) {
      return const {'notModified': true};
    }

    // Success responses (2xx)
    if (statusCode >= 200 && statusCode < 300) {
      if (decodedJson is Map<String, dynamic> &&
          decodedJson.containsKey('status') &&
          decodedJson['status'] == 'success' &&
          decodedJson.containsKey('data')) {
        return decodedJson['data'];
      }
      return decodedJson;
    }

    // Error responses (4xx / 5xx)
    String errorCode = 'UNKNOWN_ERROR';
    String? serverMessage;
    dynamic details;
    int? retryAfterSeconds;

    if (statusCode == 429) {
      errorCode = 'RATE_LIMITED';
      final retryHeader = response.headers['retry-after'];
      if (retryHeader != null) {
        retryAfterSeconds = int.tryParse(retryHeader.trim());
      }
    }

    if (decodedJson is Map<String, dynamic>) {
      // 1. Standard envelope: { status: 'error', error: { code, message, details } }
      if (decodedJson['error'] is Map<String, dynamic>) {
        final errMap = decodedJson['error'] as Map<String, dynamic>;
        errorCode = (errMap['code'] as String?) ?? errorCode;
        serverMessage = errMap['message'] as String?;
        details = errMap['details'];
      }
      // 2. Flat custom error: { code, message, details }
      else if (decodedJson.containsKey('code')) {
        errorCode = (decodedJson['code'] as String?) ?? errorCode;
        serverMessage = decodedJson['message'] as String?;
        details = decodedJson['details'];
      }
      // 3. NestJS HttpException: { statusCode, message, error }
      else if (decodedJson.containsKey('message')) {
        final msg = decodedJson['message'];
        if (msg is String) {
          serverMessage = msg;
        } else if (msg is List) {
          serverMessage = msg.join('\n');
        }
        if (decodedJson['error'] is String) {
          errorCode = (decodedJson['error'] as String).toUpperCase().replaceAll(' ', '_');
        }
      }
    } else if (decodedJson is String && decodedJson.isNotEmpty) {
      serverMessage = decodedJson;
    }

    if (errorCode == 'UNKNOWN_ERROR') {
      if (statusCode == 401) {
        errorCode = 'UNAUTHENTICATED';
      } else if (statusCode == 403) {
        errorCode = 'FORBIDDEN';
      } else if (statusCode == 404) {
        errorCode = 'NOT_FOUND';
      } else if (statusCode >= 500) {
        errorCode = 'INTERNAL_SERVER_ERROR';
      }
    }

    throw ApiException(
      statusCode: statusCode,
      code: errorCode,
      serverMessage: serverMessage,
      details: details,
      retryAfterSeconds: retryAfterSeconds,
    );
  }
}

/// A request that got no response within its timeout (#183).
///
/// An [http.ClientException], so every path that reads a dropped socket as
/// "fate unknown" reads a timeout the same way. Its own type exists for one
/// reason: #55's offline fallbacks (`data/repositories/api_*.dart`) must NOT
/// re-run a write on Drift after it. A hung request has almost certainly
/// reached the server and may have committed, so a local re-run is a second
/// write — a second weighted-average cost out of `receivePO`, a second customer.
class ApiTimeoutException extends http.ClientException {
  ApiTimeoutException(Duration timeout, Uri uri)
      : super('No response within ${timeout.inMilliseconds} ms', uri);
}

/// Paginated API response containing items list and pagination metadata.
class PaginatedResult {
  final List<dynamic> data;
  final Map<String, dynamic> meta;

  const PaginatedResult({
    required this.data,
    required this.meta,
  });

  Map<String, dynamic>? get nextCursor =>
      meta['nextCursor'] is Map ? Map<String, dynamic>.from(meta['nextCursor'] as Map) : null;

  int get total => (meta['total'] as num?)?.toInt() ?? 0;
  int get page => (meta['page'] as num?)?.toInt() ?? 1;
  int get totalPages => (meta['totalPages'] as num?)?.toInt() ?? 1;
}

/// A request's session ended (logout / another login) before its token was
/// attached. Never escapes [ApiClient]: it becomes [_staleSessionResponse].
class _StaleSession implements Exception {
  const _StaleSession();
}

http.Response _staleSessionResponse() => http.Response(
      jsonEncode({
        'status': 'error',
        'error': {'code': 'UNAUTHENTICATED', 'message': 'Session changed'},
      }),
      401,
      headers: {'content-type': 'application/json'},
    );
