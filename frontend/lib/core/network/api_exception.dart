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

/// A server refusal, already resolved to the sentence the counter should read.
///
/// `toString()` is that sentence and nothing else — no `Exception: ` prefix, no
/// class name — so the three screens' `replaceFirst('Exception: ', '')` idiom
/// renders it unchanged and none of them had to learn a new type.
///
/// [code] is kept because one caller genuinely needs it: `checkout_screen`
/// answers a `CREDIT_LIMIT_EXCEEDED` by showing the override dialog and
/// re-sending with the counter's consent (`02_API_SCREENS.md §8.2`). Resolving
/// that from the Thai text would be string-matching a translation.
class PosException implements Exception {
  const PosException(this.code, this.message, [this.details]);

  /// The server's error code, e.g. `CREDIT_LIMIT_EXCEEDED`.
  final String code;

  /// The Thai sentence from `ServerErrorResolver` (`02_API_SCREENS.md §8.1`).
  final String message;

  /// The server's `error.details`, carried verbatim. `CREDIT_LIMIT_EXCEEDED`
  /// sends `{creditLimit, creditBalance, newBalance}`, and those are the numbers
  /// the override dialog must show — the screen's own cached `MechanicRow` is
  /// what was wrong in the first place.
  final Object? details;

  @override
  String toString() => message;
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
    throw PosException(e.code, e.thaiMessage, e.details);
