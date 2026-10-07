// PosException — a refusal already in the Thai sentence the counter reads.
// Kept apart from api_exception.dart so lib/presentation/ never imports the
// HTTP layer (CLAUDE.md: an ApiException must never reach a screen).

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
