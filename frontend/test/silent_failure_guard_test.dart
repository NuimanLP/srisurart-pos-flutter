// Silent-failure guard (2026-10-03 live UX test).
//
// An `async` UI handler that awaits a repository/cubit WRITE with no catch
// fails silently: the Future's error goes to the zone handler, the counter sees
// nothing, and the button just "does nothing". `purchase_orders_screen.dart`'s
// `_delete`/`_receive`/`_cancel` were exactly this until PR #572. This test
// scans every file under `lib/presentation/` and fails on any awaited write
// that is not inside a `try` whose catch-all clause SURFACES the error.
//
// The scan is textual, like `api_repository_contract_test.dart`, so a future
// handler cannot reintroduce the bug unnoticed.
//
// HOW IT DECIDES
// 1. Comments and string literals are blanked first (offsets kept), so braces
//    or words inside Thai messages never move the brace count.
// 2. A "write call" is an `await` statement whose expression calls a method on
//    a repository-ish receiver — an identifier containing `repo`/`Repo`, a
//    `context.read<…Repository|Cubit|Service|Facade>()`, or a local/field the
//    same file assigns from such a `read<…>()` or declares with such a type —
//    and whose method name is NOT a read (see [_readPrefixes]).
// 3. It is guarded when some enclosing `try { … }` has a catch-all clause
//    (`catch (…)` or `on Object catch` — `on Exception` lets an `Error` escape)
//    whose body contains a surfacing token (see [_surfaces]): SnackBar, a
//    dialog, setState, emit, `_alert`/`_warn`/`_toast`/`_show…`, a private
//    `_…Error…(` helper, or a rethrow/throw.
// 4. The awaited expression ends at the first `;` or `{`, so a write inside a
//    closure argument (`showDialog(builder: (_) {…})`) is judged at its own
//    `await`, not attributed to the outer one.
//
// KNOWN LIMITS (heuristic — read before trusting a green run)
// - A write whose error is meant to propagate to a CALLER that catches it
//   cannot be proven here; such methods go in [_allowlist] with the reason.
// - An `await` inside a closure that sits lexically inside a `try` is counted
//   as guarded although the closure may run later, outside it.
// - A catch body that merely names a surfacing token (e.g. `setState` that
//   only clears a spinner) passes; the test checks the shape, not the message.
// - A write that is NOT awaited (`repo.x();`, `.then(…)`) is not seen here —
//   `discarded_futures`/`unawaited_futures` in analysis_options.yaml cover part
//   of that.
// - Receivers named outside the conventions in (2) are missed.
// - Allowlist keys are `<file>|<receiver.method>`, so one entry covers every
//   call of that method on that receiver in the file.
// - `lib/presentation/blocs/` is skipped (see [_skipped]); the screens that
//   await a cubit method are what is checked.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Method-name prefixes treated as reads (not checked).
const _readPrefixes = [
  'get', 'watch', 'list', 'is', 'has', 'find', 'search', 'count', 'session',
  'export', 'cashCountFrom', 'catColor', 'productIdsWith', 'openDocumentRefs',
  // ShiftsRepository's computed expected-cash reads (#580).
  'drawerCash',
];

/// Paths (prefixes) skipped entirely, with the reason.
const _skipped = {
  // Cubits are not handlers: a write a cubit awaits either propagates to the
  // screen that awaited the cubit method (itself a checked "write call") or is
  // turned into an emitted error state there. Checking both layers would demand
  // a catch at each.
  'lib/presentation/blocs/',
};

/// `<file>|<receiver.method>` (as the failure message prints it) → why that
/// awaited write is safe (or deferred).
/// The test also fails on an entry that no longer matches anything.
const _allowlist = <String, String>{
  'lib/presentation/screens/products_screen.dart|repo.deleteMany':
      'deleteMany never throws: every failure is a per-id Thai reason in '
          'BulkDeleteResult.failed, which both callers show.',
  'lib/presentation/screens/mechanics_screen.dart|repo.discardRejectedCreditPayment':
      'runs through _run(), whose catch shows the error as a SnackBar.',
  'lib/presentation/widgets/login_form.dart|cubit.login':
      'AuthCubit.login catches every error and emits Unauthenticated with a '
          'Thai errorMessage, which this form shows (auth_cubit_test.dart).',
  'lib/presentation/widgets/change_password_form.dart|read<AuthCubit>().changePassword':
      'AuthCubit.changePassword catches everything and emits the error state '
          'this form renders.',
  'lib/presentation/widgets/device_enrolment_dialog.dart|cubit.enrolDevice':
      'AuthCubit.enrolDevice returns false for any error except PosException, '
          'which the dialog\'s `on PosException` clause shows.',
  'lib/presentation/widgets/login_form.dart|cubit.loginWithOfflinePin':
      'AuthCubit.loginWithOfflinePin catches every error, emits Unauthenticated '
          'with a Thai errorMessage and returns PinVerifyError, which this form '
          'shows (auth_cubit_pin_test.dart).',
};

/// Blanks comments and string literals (keeping offsets and newlines) so that
/// brace counting and token search only ever see code.
String _codeOnly(String src) {
  final out = StringBuffer();
  var i = 0;
  final n = src.length;

  void blank(int from, int to) {
    for (var k = from; k < to; k++) {
      out.write(src[k] == '\n' ? '\n' : ' ');
    }
  }

  // Scans a string literal starting at [start]; returns the index after it.
  late int Function(int start) scanString;
  // Scans code until the `}` closing an interpolation; returns index after it.
  int scanInterpolation(int start) {
    var depth = 1;
    var k = start;
    while (k < n) {
      final c = src[k];
      if (c == "'" ||
          c == '"' ||
          (c == 'r' &&
              k + 1 < n &&
              (src[k + 1] == "'" || src[k + 1] == '"') &&
              !RegExp(r'\w').hasMatch(src[k - 1]))) {
        k = scanString(k);
        continue;
      }
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return k + 1;
      }
      k++;
    }
    return n;
  }

  scanString = (int start) {
    var k = start;
    var raw = false;
    if (src[k] == 'r') {
      raw = true;
      k++;
    }
    final q = src[k];
    final triple = k + 2 < n && src[k + 1] == q && src[k + 2] == q;
    final delim = triple ? '$q$q$q' : q;
    k += delim.length;
    while (k < n) {
      if (!raw && src[k] == r'\') {
        k += 2;
        continue;
      }
      if (!raw && src[k] == r'$' && k + 1 < n && src[k + 1] == '{') {
        k = scanInterpolation(k + 2);
        continue;
      }
      if (src.startsWith(delim, k)) return k + delim.length;
      if (!triple && src[k] == '\n') return k; // unterminated: stop at EOL
      k++;
    }
    return n;
  };

  while (i < n) {
    if (src.startsWith('//', i)) {
      final end = src.indexOf('\n', i);
      final stop = end < 0 ? n : end;
      blank(i, stop);
      i = stop;
    } else if (src.startsWith('/*', i)) {
      final end = src.indexOf('*/', i + 2);
      final stop = end < 0 ? n : end + 2;
      blank(i, stop);
      i = stop;
    } else if (src[i] == "'" ||
        src[i] == '"' ||
        (src[i] == 'r' &&
            i + 1 < n &&
            (src[i + 1] == "'" || src[i + 1] == '"') &&
            (i == 0 || !RegExp(r'\w').hasMatch(src[i - 1])))) {
      final end = scanString(i);
      blank(i, end);
      i = end;
    } else {
      out.write(src[i]);
      i++;
    }
  }
  return out.toString();
}

int _matchingBrace(String code, int open) {
  var depth = 0;
  for (var k = open; k < code.length; k++) {
    if (code[k] == '{') depth++;
    if (code[k] == '}') {
      depth--;
      if (depth == 0) return k;
    }
  }
  return code.length;
}

class _Try {
  _Try(this.start, this.end, this.guards);
  final int start;
  final int end;

  /// True when a catch-all clause in its chain surfaces the error.
  final bool guards;
}

final _surfaces = RegExp(
  r'SnackBar|showDialog|showConfirm|setState\s*\(|\bemit\s*\(|\brethrow\b|\bthrow\b'
  r'|\b_?(alert|warn|toast)\w*\s*\(|\b_show\w*\s*\(|\b_\w*[Ee]rror\w*\s*\(',
);

List<_Try> _tries(String code) {
  final result = <_Try>[];
  for (final m in RegExp(r'\btry\s*\{').allMatches(code)) {
    final open = code.indexOf('{', m.start);
    final close = _matchingBrace(code, open);
    var k = close + 1;
    var guards = false;
    while (true) {
      final rest = code.substring(k);
      final clause =
          RegExp(r'^\s*(on\s+[\w<>?, ]+?\s*(catch\s*\([^)]*\))?|catch\s*\([^)]*\)|finally)\s*\{')
              .firstMatch(rest);
      if (clause == null) break;
      final bodyOpen = k + clause.end - 1;
      final bodyClose = _matchingBrace(code, bodyOpen);
      final head = clause.group(1)!.trim();
      final catchAll = head.startsWith('catch') ||
          RegExp(r'^on\s+Object\s+catch').hasMatch(head);
      if (catchAll && _surfaces.hasMatch(code.substring(bodyOpen, bodyClose))) {
        guards = true;
      }
      k = bodyClose + 1;
    }
    result.add(_Try(open, close, guards));
  }
  return result;
}

final _serviceType = r'\w*(?:Repository|Cubit|Service|Facade)';

/// Identifiers in this file that hold a repository-ish object.
Set<String> _receiverNames(String code) {
  final names = <String>{};
  for (final m in RegExp('(\\w+)\\s*=\\s*context\\s*\\.\\s*(?:read|watch)<$_serviceType>\\(\\)')
      .allMatches(code)) {
    names.add(m.group(1)!);
  }
  for (final m in RegExp('\\b$_serviceType\\??\\s+(\\w+)\\s*[;,=)]').allMatches(code)) {
    names.add(m.group(1)!);
  }
  return names;
}

/// `getAll`/`isLocked` are reads; `issueOffline`/`listen` are not (the prefix
/// must end the name or be followed by an upper-case letter).
bool _isRead(String method) => _readPrefixes.any((pre) =>
    method == pre ||
    (method.startsWith(pre) &&
        RegExp('[A-Z]').hasMatch(method[pre.length])));

/// Every unguarded awaited write in [source], as collapsed await expressions
/// paired with their 1-based line.
List<({int line, String call})> _unguardedWrites(String source) {
  final code = _codeOnly(source);
  final tries = _tries(code);
  final names = _receiverNames(code);
  final namePattern = names.isEmpty ? '' : '|\\b(?:${names.join('|')})';
  final receiver = RegExp(
    '(?:\\b\\w*[Rr]epo(?:sitory)?\\b|read<$_serviceType>\\(\\)$namePattern)'
    '\\s*\\.\\s*(\\w+)\\s*\\(',
  );
  final found = <({int line, String call})>[];
  for (final m in RegExp(r'\bawait\b').allMatches(code)) {
    final end = code.substring(m.start).indexOf(RegExp(r'[;{]'));
    final stmt = code
        .substring(m.start, end < 0 ? code.length : m.start + end)
        .replaceAll(RegExp(r'\s+'), ' ');
    final call = receiver.firstMatch(stmt);
    if (call == null || _isRead(call.group(1)!)) continue;
    final guarded =
        tries.any((t) => t.start < m.start && m.start < t.end && t.guards);
    if (guarded) continue;
    final line = '\n'.allMatches(code.substring(0, m.start)).length + 1;
    // `repo.deletePO` / `read<X>().addSupplier` — the allowlist key.
    final head = call.group(0)!.replaceAll(RegExp(r'\s'), '');
    found.add((line: line, call: head.substring(0, head.length - 1)));
  }
  return found;
}

void main() {
  test('self-check: an unguarded awaited write is caught', () {
    const bad = '''
  Future<void> _delete(PurchaseOrderRow po) async {
    final repo = context.read<PurchaseOrdersRepository>();
    final ok = await showConfirm(context, 'ลบ {', 'x');
    if (!ok) return;
    await repo.deletePO(po.id);
    _refresh();
  }
''';
    final found = _unguardedWrites(bad);
    expect(found.map((f) => f.call), ['repo.deletePO']);
    expect(found.single.line, 5);
  });

  test('self-check: other receiver shapes are caught', () {
    const bad = '''
  Future<void> _a() async {
    await context.read<SalesRepository>().saveSale(input);
  }
  Future<void> _b() async {
    final sales = context.read<SalesRepository>();
    await sales
        .voidSale(id);
  }
  Future<void> _c() async {
    await context.read<AuthCubit>().logout();
  }
''';
    expect(_unguardedWrites(bad), hasLength(3));
  });

  test('self-check: the PR #572 shape is guarded; reads and swallowing catches are judged right', () {
    const good = '''
  Future<void> _cancel(PurchaseOrderRow po) async {
    final repo = context.read<PurchaseOrdersRepository>();
    final settings = await repo.getSettings();
    try {
      await repo.cancelPO(po.id);
    } on PosException catch (e) {
      _showError(e);
    } catch (e) {
      _showError(e);
      return;
    }
  }
''';
    expect(_unguardedWrites(good), isEmpty);

    const swallowed = '''
  Future<void> _x() async {
    try {
      await repo.cancelPO(id);
    } catch (_) {
      // nothing — the counter never learns it failed
    }
  }
''';
    expect(_unguardedWrites(swallowed), hasLength(1));

    const typedOnly = '''
  Future<void> _x() async {
    try {
      await repo.cancelPO(id);
    } on PosException catch (e) {
      _showError(e);
    }
  }
''';
    expect(_unguardedWrites(typedOnly), hasLength(1),
        reason: 'any other exception type still escapes silently');

    const exceptionOnly = '''
  Future<void> _x() async {
    try {
      await repo.cancelPO(id);
    } on Exception catch (e) {
      _showError(e);
    }
  }
''';
    expect(_unguardedWrites(exceptionOnly), hasLength(1),
        reason: 'an Error (StateError, TypeError) still escapes silently');

    // A write inside a dialog builder is judged at its own await only.
    const nested = '''
  Future<void> _x() async {
    await showDialog<void>(context: context, builder: (_) {
      return Button(onPressed: () async {
        await repo.cancelPO(id);
      });
    });
  }
''';
    expect(_unguardedWrites(nested).map((f) => f.line), [4]);

    // `report`/`reportCubit`-style names are not repository receivers.
    const notARepo = '''
  Future<void> _x() async {
    await report.print();
  }
''';
    expect(_unguardedWrites(notARepo), isEmpty);
  });

  test('no presentation handler awaits a write that can fail silently', () {
    final dir = Directory(p.join('lib', 'presentation'));
    final violations = <String>[];
    final seenKeys = <String>{};
    for (final file in dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final rel = p.posix.joinAll(p.split(p.relative(file.path)));
      if (_skipped.any(rel.startsWith)) continue;
      for (final f in _unguardedWrites(file.readAsStringSync())) {
        final key = '$rel|${f.call}';
        if (_allowlist.containsKey(key)) {
          seenKeys.add(key);
          continue;
        }
        violations.add('$rel:${f.line}: ${f.call}');
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'An awaited repository/cubit write with no surfacing catch fails '
          'silently: the counter sees nothing. Wrap it as PR #572 did '
          '(try { … } catch (e) { SnackBar with the Thai message }), or add '
          "'<file>|<call>' to _allowlist with a reason. Found:\n"
          '${violations.join('\n')}',
    );

    final stale = _allowlist.keys.where((k) => !seenKeys.contains(k)).toList();
    expect(stale, isEmpty,
        reason: 'These allowlist entries no longer match anything — remove '
            'them:\n${stale.join('\n')}');
  });
}
