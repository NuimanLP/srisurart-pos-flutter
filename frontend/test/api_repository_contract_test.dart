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

/// Reads that #55's API repositories may answer from the cache when the network
/// is down. A read served stale is ADR-0010's whole design; a WRITE re-run
/// locally is not.
const _fallbackReads = {
  'getPOs',
  'getQuotes',
  'getCategories',
  'getCustomers',
  'getMechanics',
  'getAll',
};

/// `return super.receivePO(` / `await super.deletePO(` -> the method name.
String? _superWriteName(String line) {
  if (!line.contains('return super.') && !line.contains('await super.')) {
    return null;
  }
  final rest = line.substring(line.indexOf('super.') + 'super.'.length);
  final paren = rest.indexOf('(');
  if (paren <= 0) return null;
  return rest.substring(0, paren);
}

bool _isSwallowingCatch(String line) {
  final t = line.trim();
  return t == '} catch (_) {' || t == '} catch (_) {}';
}

/// #55's API repositories (`lib/data/repositories/api_*.dart`, one level up from
/// #56's folder) EXTEND their Drift counterpart and fall back to
/// `super.<write>()` when the server cannot be reached. That fallback is
/// legitimate — phase 1 plans no cutover, so with no server the app must keep
/// working on Drift — but only when the server never answered.
///
/// 🔴 An `ApiException` means it DID answer, and on a 5xx the write may well
/// have committed with only the reply lost. Falling through then re-runs the
/// invariant: a second weighted-average cost and a second `movements` row out of
/// `receivePO`, a second `credit_payments` row, a second quote. So every write
/// fallback must be preceded by an `on ApiException` clause that rethrows.
List<String> _unguardedFallbacks(String source) {
  final violations = <String>[];
  final lines = source.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final name = _superWriteName(lines[i]);
    if (name == null || _fallbackReads.contains(name)) continue;
    for (var j = i; j >= 0; j--) {
      if (!_isSwallowingCatch(lines[j])) continue;
      final guarded =
          j >= 2 &&
          lines[j - 1].contains('rethrowServerRefusal(') &&
          lines[j - 2].contains('on ApiException catch');
      if (!guarded) {
        violations.add(
          'line ${i + 1}: ${lines[i].trim()}  '
          '(falls back to Drift after the catch on line ${j + 1}, which '
          'swallows a server refusal instead of rethrowing it)',
        );
      }
      break;
    }
  }
  return violations;
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

  test('self-check: the fallback matcher catches an unguarded write', () {
    const unguarded = '''
  Future<List<String>> receivePO(String id) async {
    try {
      return _unmatched(await apiClient.post('/receive'));
    } catch (_) {
      // Offline fallback
    }

    return super.receivePO(id);
  }
''';
    expect(_unguardedFallbacks(unguarded), isNotEmpty);

    const guarded = '''
  Future<List<String>> receivePO(String id) async {
    try {
      return _unmatched(await apiClient.post('/receive'));
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } catch (_) {
      // Offline fallback
    }

    return super.receivePO(id);
  }
''';
    expect(_unguardedFallbacks(guarded), isEmpty);

    // A READ served from the cache is the design, not a violation.
    const cachedRead = '''
  Future<List<PurchaseOrderRow>> getPOs() async {
    try {
      return _fromWire(await apiClient.get('/purchase-orders'));
    } catch (_) {}

    return super.getPOs();
  }
''';
    expect(_unguardedFallbacks(cachedRead), isEmpty);
  });

  test(
    'no api_*_repository.dart re-runs a Drift write after the server answered',
    () {
      final dir = Directory(p.join('lib', 'data', 'repositories'));
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('api_'))
          .where((f) => f.path.endsWith('.dart'))
          .toList();

      expect(
        files,
        isNotEmpty,
        reason: "#55's API repositories should be here by now",
      );

      final allViolations = <String>[];
      for (final file in files) {
        final source = file.readAsStringSync();
        final violations = [
          ..._unguardedFallbacks(source),
          ..._networkInsideTransaction(source.split('\n')),
        ];
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
            'A write whose reply was a server refusal must reach the counter, '
            'not be quietly re-done against Drift. On a 5xx the server may have '
            'committed and only the reply was lost, so the local re-run is a '
            'SECOND PO receipt, credit payment or quote. Found:'
            '\n${allViolations.join('\n')}',
      );
    },
  );

  test('#54 AC6: nothing the client sends carries deviceId or tenantId', () {
    // Both come from the token, never from the request — ADR-0004: `did`/`drole`
    // are never read from a body, and the tenant is the guard's to decide. A
    // client that can name either can be made to name someone else's.
    final dirs = [
      Directory(p.join('lib', 'data', 'repositories')),
      Directory(p.join('lib', 'core', 'network')),
      Directory(p.join('lib', 'data', 'services')),
    ];

    final offenders = <String>[];
    for (final dir in dirs) {
      if (!dir.existsSync()) continue;
      for (final file in dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final lines = file.readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          if (!line.contains("'deviceId'") && !line.contains("'tenantId'")) {
            continue;
          }
          offenders.add('${p.relative(file.path)}:${i + 1}: ${line.trim()}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'A request naming its own device or tenant is a request that can name '
          "someone else's. Both travel in the token. Found:"
          '\n${offenders.join('\n')}',
    );
  });
}
