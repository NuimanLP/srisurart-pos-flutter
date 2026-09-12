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
  })  : baseUrl = (baseUrl ?? const String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:3000'))
            .replaceAll(RegExp(r'/+$'), ''),
        _client = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _client;
  final TokenStorage? tokenStorage;

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

  Future<Map<String, String>> _buildHeaders({
    Map<String, String>? extraHeaders,
    bool skipAuth = false,
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

    if (!skipAuth && tokenStorage != null) {
      final token = await tokenStorage!.getAccessToken();
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
  }) async {
    return _sendWithRetry(
      () async {
        final uri = _buildUri(path, queryParameters);
        final h = await _buildHeaders(extraHeaders: headers, skipAuth: skipAuth);
        return _client.get(uri, headers: h);
      },
      path: path,
      skipAuth: skipAuth,
    );
  }

  Future<dynamic> post(
    String path, {
    dynamic body,
    Map<String, String>? headers,
    bool skipAuth = false,
  }) async {
    return _sendWithRetry(
      () async {
        final uri = _buildUri(path);
        final h = await _buildHeaders(extraHeaders: headers, skipAuth: skipAuth);
        final encodedBody = body != null ? (body is String ? body : jsonEncode(body)) : null;
        return _client.post(uri, headers: h, body: encodedBody);
      },
      path: path,
      skipAuth: skipAuth,
    );
  }

  Future<dynamic> put(
    String path, {
    dynamic body,
    Map<String, String>? headers,
    bool skipAuth = false,
  }) async {
    return _sendWithRetry(
      () async {
        final uri = _buildUri(path);
        final h = await _buildHeaders(extraHeaders: headers, skipAuth: skipAuth);
        final encodedBody = body != null ? (body is String ? body : jsonEncode(body)) : null;
        return _client.put(uri, headers: h, body: encodedBody);
      },
      path: path,
      skipAuth: skipAuth,
    );
  }

  Future<dynamic> patch(
    String path, {
    dynamic body,
    Map<String, String>? headers,
    bool skipAuth = false,
  }) async {
    return _sendWithRetry(
      () async {
        final uri = _buildUri(path);
        final h = await _buildHeaders(extraHeaders: headers, skipAuth: skipAuth);
        final encodedBody = body != null ? (body is String ? body : jsonEncode(body)) : null;
        return _client.patch(uri, headers: h, body: encodedBody);
      },
      path: path,
      skipAuth: skipAuth,
    );
  }

  Future<dynamic> delete(
    String path, {
    Map<String, String>? headers,
    bool skipAuth = false,
  }) async {
    return _sendWithRetry(
      () async {
        final uri = _buildUri(path);
        final h = await _buildHeaders(extraHeaders: headers, skipAuth: skipAuth);
        return _client.delete(uri, headers: h);
      },
      path: path,
      skipAuth: skipAuth,
    );
  }

  Future<dynamic> _sendWithRetry(
    Future<http.Response> Function() execute, {
    required String path,
    required bool skipAuth,
  }) async {
    final response = await execute();

    // 401 Unauthorized handling & automatic token refresh
    if (response.statusCode == 401 && !skipAuth && !_isAuthPath(path)) {
      final refreshed = await _handleTokenRefresh();
      if (refreshed) {
        // Retry original request once with newly acquired access token
        final retryResponse = await execute();
        return _handleResponse(retryResponse);
      }
    }

    return _handleResponse(response);
  }

  bool _isAuthPath(String path) {
    return path.contains('/auth/token') ||
        path.contains('/auth/refresh') ||
        path.contains('/auth/device');
  }

  Future<bool> _handleTokenRefresh() async {
    if (tokenStorage == null) return false;

    // Concurrency lock: reuse ongoing refresh future
    if (_refreshFuture != null) {
      return _refreshFuture!;
    }

    _refreshFuture = _executeRefresh();
    try {
      final success = await _refreshFuture!;
      return success;
    } finally {
      _refreshFuture = null;
    }
  }

  Future<bool> _executeRefresh() async {
    final storage = tokenStorage;
    if (storage == null) return false;
    final currentRefreshToken = await storage.getRefreshToken();
    if (currentRefreshToken == null || currentRefreshToken.isEmpty) {
      await storage.clearAuthTokens();
      onSessionExpired?.call();
      return false;
    }

    try {
      final uri = _buildUri('/api/v1/auth/refresh');
      final h = await _buildHeaders(skipAuth: true);
      final response = await _client.post(
        uri,
        headers: h,
        body: jsonEncode({'refreshToken': currentRefreshToken}),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final tokens = AuthTokens.fromJson(json);
        await storage.setAccessToken(tokens.accessToken);
        await storage.setRefreshToken(tokens.refreshToken);
        return true;
      } else {
        await storage.clearAuthTokens();
        onSessionExpired?.call();
        return false;
      }
    } catch (_) {
      await storage.clearAuthTokens();
      onSessionExpired?.call();
      return false;
    }
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
