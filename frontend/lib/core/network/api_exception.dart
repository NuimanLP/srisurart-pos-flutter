// Structured exception for API errors returned by the NestJS backend.

import '../errors/pos_exception.dart';
import 'server_error_resolver.dart';

export '../errors/pos_exception.dart';

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

/// Re-throw a server refusal in the form the screens render, from a repository
/// that would otherwise fall through to a LOCAL write.
///
/// 🔴 The offline fallback in `data/repositories/api_*.dart` (#55) exists because
/// phase 1 plans no cutover: with no server reachable the app must keep working
/// on Drift. But it may only run when the server **never answered**. An
/// [ApiException] means it did — including a 5xx, where the write may well have
/// committed and only the reply was lost — and running the Drift transactional
/// service then is a second PO receipt (a second weighted-average cost and a
/// second `movements` row), a second credit payment, a second quote. A refusal
/// the server *did* give must reach the counter, not be quietly re-done locally.
Never rethrowServerRefusal(ApiException e) =>
    throw posExceptionFromApi(e, keepServerTextOn5xx: true);

/// THE conversion of an [ApiException] into what a screen may see. Every
/// repository conversion goes through here; only `AuthRepository.loginRefusal`
/// adds login-specific cases on top.
///
/// For a 4xx or a 429 there is one text: [ApiException.thaiMessage]. A 5xx has
/// two, because the app has always shown two and the screens must not change:
///  - default — [ServerErrorResolver.resolveCounterError]'s connection
///    sentence. That is what a screen rendered when the raw [ApiException]
///    reached it, i.e. on every path converted after #642. The one exception
///    is 503 `IDEMPOTENCY_KEY_IN_FLIGHT`: owner 2026-10-06, its own "wait"
///    sentence on every path, so both modes give the same text for it.
///  - [keepServerTextOn5xx] — [ApiException.thaiMessage], what [rethrowThai] /
///    [rethrowServerRefusal] have always produced (sales, returns, shifts,
///    settings, product delete, PIN setup). It keeps e.g. a 500
///    `INTERNAL_ERROR`'s own server `message` on those paths, where the
///    default would show the connection sentence.
PosException posExceptionFromApi(
  ApiException e, {
  bool keepServerTextOn5xx = false,
}) =>
    PosException(
      e.code,
      keepServerTextOn5xx
          ? e.thaiMessage
          : ServerErrorResolver.resolveCounterError(e),
      e.details,
    );
