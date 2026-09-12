// The wire conventions every ApiRepository shares (#56, ADR-0010).
//
// Three things live here and nowhere else, because two repositories getting
// them subtly different is exactly the "invariant ชุดที่สอง" ADR-0010 §3 bans:
//
//  1. **Money crosses the wire as a string** (`"1234.50"`, 02_API_SCREENS.md
//     §1.1). The server parses a JSON number too, but `0.1 + 0.2` is how a
//     receipt total ends up a satang off the paper in the customer's hand, so
//     the client sends the string form and never the double.
//  2. **Timestamps are ISO-8601 UTC** and become local `DateTime`s here.
//  3. **A field the response omits leaves its row alone** — `keepMoney` below.
//  4. **An `ApiException` must never reach a screen.** Checkout / Returns /
//     Cash Drawer all render a failure as
//     `e.toString().replaceFirst('Exception: ', '')` — see
//     `returns_screen.dart:242` and `cash_drawer_screen.dart:211`. A raw
//     `ApiException.toString()` would print `ApiException(status: 409,
//     code: …)` at the counter. So every repository here wraps its call in
//     [rethrowThai], which re-throws a [PosException]: `toString()` is the
//     resolved Thai sentence and nothing else, so every screen renders it
//     exactly as it renders a Drift service's `Exception('สต็อกไม่พอ…')`.
//  5. **Only a 4xx is a verdict** — [isVerdict] and [PendingWrites]. A write
//     whose reply was lost has NOT necessarily failed, and the retry must
//     carry the first attempt's id and `Idempotency-Key` or it becomes a
//     second bill. This is the money rule of the whole slice.

import 'package:drift/drift.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/utils/ids.dart';
import '../../db/database.dart';

/// Parses a `NUMERIC` as the API hands it back (`"1234.50"`, or a JSON number
/// from a handler that skipped the string form). `null` → 0.
double money(Object? wire) {
  if (wire == null) return 0;
  if (wire is num) return wire.toDouble();
  return double.parse(wire as String);
}

/// Same as [money] but keeps `null` as `null` — for the nullable columns
/// (`physicalCash`, `mechanicCreditBalanceAfter`, `mechanicDelta`).
double? moneyOrNull(Object? wire) => wire == null ? null : money(wire);

/// Baht → the wire's two-decimal string. `1250.5` → `"1250.50"`.
///
/// Rounds through integer satang rather than `toStringAsFixed`, which is a
/// float formatting of a float and rounds half-to-even on some inputs; the
/// server's `toSatang` refuses anything with a third decimal, so a value that
/// formats a hair off is a 400 at the counter.
String wireMoney(num baht) {
  final satang = (baht * 100).round();
  final sign = satang < 0 ? '-' : '';
  final abs = satang.abs();
  return '$sign${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
}

/// ISO-8601 from the server → a local `DateTime`, which is what every Drift
/// `DateTimeColumn` in this app holds.
DateTime stamp(Object? wire) => DateTime.parse(wire as String).toLocal();

DateTime? stampOrNull(Object? wire) => wire == null ? null : stamp(wire);

/// A fresh `Idempotency-Key` header for one money/stock write.
///
/// One key per logical attempt, generated BEFORE the request and reused
/// verbatim on every retry of that same attempt — that is the whole point of
/// the header (`server/README.md` *Idempotency*). Minting one per call would
/// hand the server a new key each time and ring the bill up twice, which is
/// #56 AC2 — so the money paths do not call this directly, they go through
/// [PendingWrites], which is what remembers the attempt across presses.
Map<String, String> idempotencyKey() => {'Idempotency-Key': newId('idem')};

/// Runs [body] and converts an [ApiException] into the plain `Exception` the
/// screens already know how to display. Everything else (a `SocketException`,
/// a `TimeoutException`) is left alone: it is not a server verdict and has no
/// Thai sentence of its own.
Future<T> rethrowThai<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on ApiException catch (e) {
    throw PosException(e.code, e.thaiMessage, e.details);
  }
}

/// Whether [e] is the server's FINAL answer about a money/stock write — that
/// is, whether the attempt that raised it can safely be forgotten.
///
/// 🔴 Only a 4xx is a verdict. A 5xx (including nginx's own 502/504 — `ApiClient`
/// sets no timeout, so a proxy read-timeout is the likeliest shape of a lost
/// reply) and a 429 both leave the bill's fate UNKNOWN: the transaction may have
/// committed and only the reply was lost. Forgetting the attempt there means the
/// counter's next press mints a fresh id and a fresh `Idempotency-Key`, which
/// misses both of the server's defences at once and rings the customer up twice.
///
/// 503 `IDEMPOTENCY_KEY_IN_FLIGHT` is the sharpest case and falls out of the
/// same rule: it means *the original is still running*, so it is the one reply
/// that must never close an attempt.
bool isVerdict(ApiException e) => e.statusCode < 500 && e.statusCode != 429;

/// A value to write, or [Value.absent] when the response did not carry the
/// field at all.
///
/// 🔴 Absent must leave the column as it is. Writing a default (0, or a locally
/// derived number) for a missing field is the silent-corruption path the ADR
/// forbids: a stale figure is visibly old, a fabricated one is not.
Value<double> keepMoney(double? v) =>
    v == null ? const Value.absent() : Value(v);

/// One `movements[]` entry from a server response → the local log row.
///
/// Every number is the server's: `delta` and `stockAfter` are what it actually
/// wrote, and `type` is its own label ('sale' / 'return' / 'void' — migration
/// `1788652800003` separated void from return precisely so reports stop counting
/// one as the other, so it is copied, never inferred from which endpoint replied).
MovementRow movementRowFromWire(Map<String, dynamic> mv) => MovementRow(
  id: mv['id'] as String,
  productId: mv['productId'] as String,
  partNo: mv['partNo'] as String? ?? '',
  name: mv['name'] as String? ?? '',
  delta: mv['delta'] as int,
  type: mv['type'] as String,
  note: mv['note'] as String?,
  stockAfter: mv['stockAfter'] as int,
  date: stamp(mv['date']),
);

/// One attempt at a money/stock write: the id the endpoint is to record it
/// under and the `Idempotency-Key` it is sent with.
class PendingWrite {
  const PendingWrite._({
    required this.fingerprint,
    required this.id,
    required this.headers,
  });

  /// What identifies "this same action, sent again". See [PendingWrites].
  final String fingerprint;

  /// The client-generated document id. Used by `POST /sales`, which takes the
  /// bill id from the client so the server can recognise a replay by it
  /// (`existingSale`); ignored by the endpoints that mint their own id, where
  /// the `Idempotency-Key` is the only defence.
  final String id;

  /// The `Idempotency-Key` header, minted once and reused on every retry.
  final Map<String, String> headers;
}

/// The money/stock writes this device has sent and never got a verdict for.
///
/// 🔴 This is what stops a cashier's second press after a lost reply from
/// becoming a second bill, a second credit note, or a second drawer entry.
/// `ApiClient` sets no timeout and the shop's link is not reliable, so the
/// ordinary failure is: the request commits server-side, the reply is lost, the
/// counter reads `ขายไม่สำเร็จ…` and presses again. Re-sending the SAME id and
/// the SAME `Idempotency-Key` makes that second press replay the first write.
/// Minting a fresh pair defeats both of the server's defences at once.
///
/// An entry is dropped the moment the server gives a verdict ([isVerdict]) — and
/// otherwise after [_ttl], because the fingerprint is a value, not an identity:
/// two genuinely different walk-ins buying one ฿250 oil filter for cash produce
/// the same fingerprint, and without an expiry the second one would replay the
/// first one's bill hours later. Ten minutes is far longer than a counter takes
/// to press again and far shorter than the gap between two coincidentally
/// identical carts.
class PendingWrites {
  PendingWrites(this._idPrefix);

  final String _idPrefix;
  final Map<String, _Parked> _open = {};

  static const Duration _ttl = Duration(minutes: 10);

  /// The id + `Idempotency-Key` [fingerprint] should be sent under: a new pair
  /// the first time, the SAME pair while the first attempt's fate is unknown.
  PendingWrite of(String fingerprint) {
    final parked = _open[fingerprint];
    if (parked != null && DateTime.now().difference(parked.at) < _ttl) {
      return parked.write;
    }
    final write = PendingWrite._(
      fingerprint: fingerprint,
      id: newId(_idPrefix),
      headers: idempotencyKey(),
    );
    _open[fingerprint] = _Parked(write, DateTime.now());
    return write;
  }

  /// The server answered: the next press is a new action, not a retry.
  void close(PendingWrite write) => _open.remove(write.fingerprint);

  /// Close the attempt only if [e] is a verdict. A 5xx or a 429 leaves it
  /// parked, which is the entire point of this class — see [isVerdict].
  void closeIfVerdict(PendingWrite write, ApiException e) {
    if (isVerdict(e)) close(write);
  }
}

class _Parked {
  const _Parked(this.write, this.at);
  final PendingWrite write;
  final DateTime at;
}
