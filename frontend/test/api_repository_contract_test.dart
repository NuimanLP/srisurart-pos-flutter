// #56 AC6: "No ApiRepository in this slice calls a Drift transactional
// service — enforced by a test."
//
// ADR-0010 §3's rule is that an ApiRepository hits the server and then
// patches Drift rows from the response; it must NEVER also call one of the
// Drift *transactional services* (`saveSale`, `createReturn`, `openShift`,
// `addDrawerEntry`, `closeShift`, `receivePO`) or hold a `db.transaction`
// open ACROSS a network call. Calling one of those after the server has already
// committed the write double-runs the same invariant twice — the concrete
// failure mode is a DOUBLE STOCK DECREMENT: the server decrements stock
// inside `POST /sales`, and if the client then also called the Drift
// `saveSale`, that method decrements stock AGAIN against the (already
// updated) local cache, so one sale removes two units of stock from a
// product that only left the shop once.
//
// This is checked at the source level, on purpose: it is the only way to
// prove a *future* ApiRepository can't reintroduce the call, rather than
// only proving today's code happens not to.
//
// The matcher looks for a DOT before the transactional method's name
// (`.openShift(`, `.saveSale(`, ...) — that is what a *call* on some object
// looks like — and is deliberately blind to the method being *declared*
// (`Future<ShiftRow> openShift(double startingCash) {` has no leading dot)
// or being called as a *delegated read* (`getCashDrawer`/`getShiftHistory`
// are not in the banned list at all — #55's reads are allowed to delegate).
//
// `db.transaction(...)` itself is NOT banned, and the first draft of this test
// banning it outright was wrong — it red-flagged the correct code in
// `api_sales_repository.dart` and `api_returns_repository.dart`, which open a
// LOCAL-ONLY transaction *after* the response has landed so that a header row
// and its FK-bearing lines cannot be half-written. What ADR-0010 §3 actually
// forbids is a second run of the invariant, and what a transaction must never
// do is span the wire: a Drift transaction held open for the duration of an
// HTTP round trip locks the cache behind the slowest thing in the system, and
// on a timeout it rolls back rows describing a sale the server has already
// committed and printed a receipt for. So the rule is scoped to that: no API
// call inside a transaction block.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The Drift transactional services ApiRepository classes may never call.
const _bannedCalls = [
  '.saveSale(',
  '.createReturn(',
  '.openShift(',
  '.addDrawerEntry(',
  '.closeShift(',
  '.receivePO(',
];

/// How an HTTP call out of an `ApiRepository` looks: the injected [ApiClient]
/// is the only way any of them reaches the network.
final _apiCall = RegExp(r'\b_?api\.(get|post|put|delete)\(');

/// Lines inside a `db.transaction(...)` block that reach the network. The
/// block is delimited by brace depth counted from the `db.transaction(` line,
/// which is exact enough here because none of these files puts a brace inside
/// a string literal.
List<String> _networkInsideTransaction(List<String> lines) {
  final violations = <String>[];
  for (var start = 0; start < lines.length; start++) {
    if (!lines[start].contains('db.transaction(')) continue;
    var depth = 0;
    for (var i = start; i < lines.length; i++) {
      final line = lines[i];
      if (i > start && _apiCall.hasMatch(line)) {
        violations.add(
          'line ${i + 1}: ${line.trim()}  '
          '(network call inside the db.transaction( opened on line ${start + 1})',
        );
      }
      depth += '{'.allMatches(line).length - '}'.allMatches(line).length;
      if (i > start && depth <= 0) break;
    }
  }
  return violations;
}

/// Returns every banned pattern found in [source], each paired with the
/// 1-based line number it occurs on (for a useful failure message).
List<String> _violationsIn(String source) {
  final violations = <String>[];
  final lines = source.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    for (final pattern in _bannedCalls) {
      if (line.contains(pattern)) {
        violations.add('line ${i + 1}: ${line.trim()}  (matched "$pattern")');
      }
    }
  }
  return violations..addAll(_networkInsideTransaction(lines));
}

void main() {
  final apiDir = Directory(
    p.join('lib', 'data', 'repositories', 'api'),
  );

  test('self-check: the matcher actually catches a violation', () {
    // Proves _violationsIn is not a no-op before we trust it on the real
    // files below. Mirrors the exact double-stock-decrement failure mode:
    // a hypothetical ApiSalesRepository that patches products from the
    // POST /sales response and THEN also calls the Drift saveSale.
    const violatingSnippet = '''
class ApiSalesRepository implements SalesRepository {
  Future<SaleRow> saveSale(SaleInput input) async {
    final response = await api.post('/api/v1/sales', body: ...);
    // BUG: this double-decrements stock — the server already did it.
    return drift.saveSale(input);
  }
}
''';
    final found = _violationsIn(violatingSnippet);
    expect(
      found,
      isNotEmpty,
      reason: 'matcher failed to catch a call to drift.saveSale(...)',
    );
    expect(found.single, contains('.saveSale('));

    // And the matcher must NOT trip on the declaration line just above it,
    // nor on an unrelated delegated read.
    const cleanSnippet = '''
class ApiShiftsRepository implements ShiftsRepository {
  Future<ShiftRow> openShift(double startingCash) {
    return rethrowThai(() async {
      final response = await api.post('/api/v1/shifts/open', body: {});
      return _patchShiftWithEntries(response);
    });
  }

  Future<ShiftWithEntries?> getCashDrawer() => drift.getCashDrawer();
}
''';
    expect(
      _violationsIn(cleanSnippet),
      isEmpty,
      reason:
          'matcher false-positived on a declaration or an allowed delegated read',
    );
  });

  test('self-check: a transaction may patch locally, but never span the wire', () {
    // The shape both api_sales_repository and api_returns_repository use: the
    // response has already landed, and the transaction only groups the local
    // header + FK-bearing lines so they cannot be half-written.
    const localOnly = '''
    final res = await _api.post('/api/v1/sales', body: body);
    await db.transaction(() async {
      await db.into(db.sales).insert(sale);
      await db.batch((b) { });
    });
''';
    expect(
      _violationsIn(localOnly),
      isEmpty,
      reason: 'a local-only patch transaction is the correct pattern, not a violation',
    );

    // The shape that is genuinely wrong: the cache is locked for the whole
    // round trip, and a timeout rolls back rows for a bill the server kept.
    const spansTheWire = '''
    await db.transaction(() async {
      await db.into(db.sales).insert(sale);
      final res = await _api.post('/api/v1/sales', body: body);
      await db.batch((b) { });
    });
''';
    final found = _violationsIn(spansTheWire);
    expect(
      found,
      isNotEmpty,
      reason: 'matcher missed a network call held inside a db.transaction',
    );
    expect(found.single, contains('network call inside the db.transaction('));
  });

  test(
    'no file under lib/data/repositories/api/ calls a Drift transactional '
    'service or wraps a network call in db.transaction(...)',
    () {
      expect(
        apiDir.existsSync(),
        isTrue,
        reason: '${apiDir.path} should exist by the time this slice ships',
      );

      final dartFiles = apiDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();

      expect(
        dartFiles,
        isNotEmpty,
        reason: 'expected at least api_wire.dart under ${apiDir.path}',
      );

      final allViolations = <String>[];
      for (final file in dartFiles) {
        final violations = _violationsIn(file.readAsStringSync());
        if (violations.isNotEmpty) {
          allViolations.add(
            '${p.relative(file.path)}:\n  ${violations.join('\n  ')}',
          );
        }
      }

      expect(
        allViolations,
        isEmpty,
        reason:
            'ADR-0010 §3: an ApiRepository must hit the server and then patch '
            'Drift rows from the response — it must never ALSO call the Drift '
            'transactional service for the same action. Doing both runs the '
            "same invariant twice against the same row; concretely, it is a "
            'double stock decrement — the server decrements stock inside '
            'POST /sales, and if the client then also calls the Drift '
            'saveSale, that decrements the (already-updated) local cache '
            'again, so one sale removes two units of stock for a product '
            'that only left the shop once. Found:\n${allViolations.join('\n')}',
      );
    },
  );
}
