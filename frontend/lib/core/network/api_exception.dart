// Structured exception for API errors returned by the NestJS backend.

import 'server_error_resolver.dart';

class ApiException implements Exception {
  ApiException({
    required this.statusCode,
    required this.code,
    this.serverMessage,
    this.details,
    this.retryAfterSeconds,
  });

  /// HTTP status code (e.g. 400, 401, 403, 409, 429, 500).
  final int statusCode;

  /// Backend error code (e.g. 'INSUFFICIENT_STOCK', 'RATE_LIMITED', 'TENANT_SUSPENDED').
  final String code;

  /// Original message sent from the server.
  final String? serverMessage;

  /// Structured error details (e.g. stock shortfall list, credit limit info).
  final dynamic details;

  /// Value of the Retry-After header in seconds (for 429 RATE_LIMITED), if present.
  final int? retryAfterSeconds;

  /// User-facing Thai message resolved via [ServerErrorResolver].
  String get thaiMessage => ServerErrorResolver.resolve(
        code,
        serverMessage: serverMessage,
        details: details,
      );

  @override
  String toString() {
    final retryInfo = retryAfterSeconds != null ? ' (Retry-After: ${retryAfterSeconds}s)' : '';
    return 'ApiException(status: $statusCode, code: $code, message: "$thaiMessage"$retryInfo)';
  }
}
