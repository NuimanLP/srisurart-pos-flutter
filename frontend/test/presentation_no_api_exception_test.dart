// CLAUDE.md binding rule: "An `ApiException` must never reach a screen —
// convert via `rethrowThai` / `rethrowServerRefusal` to a plain Thai-string
// `Exception`/`PosException`." The conversion belongs in the repository
// layer (as `AuthRepository.login`/`changePassword` and
// `OfflinePinRepository.setPin` do), so nothing under lib/presentation/ may
// import the HTTP error type or inspect it. Checked at the source level so a
// future screen cannot reintroduce it. `PosException` lives in
// `core/errors/pos_exception.dart` for exactly this reason. The runtime side —
// that no repository lets one out — is `api_exception_never_escapes_test.dart`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// `\s` spans newlines, so an import split over several lines still matches.
final _apiExceptionImport =
    RegExp(r'''import\s+['"][^'"]*api_exception\.dart['"]''');
final _apiExceptionRef = RegExp(r'\bApiException\b');

/// The offences in one file's [source]. Only whole-line `//` comments are
/// skipped (comments may name the type when explaining why it is absent): a
/// `//` inside code — `'http://x'` — must not hide the rest of its line.
List<String> offencesIn(String path, String source) {
  final lines = source.split('\n');
  final code = [
    for (final l in lines) l.trimLeft().startsWith('//') ? '' : l,
  ];
  final offences = <String>[];
  final joined = code.join('\n');
  for (final m in _apiExceptionImport.allMatches(joined)) {
    final line = '\n'.allMatches(joined.substring(0, m.start)).length;
    offences.add('$path:${line + 1}: ${lines[line].trim()}');
  }
  for (var i = 0; i < code.length; i++) {
    if (_apiExceptionRef.hasMatch(code[i])) {
      offences.add('$path:${i + 1}: ${lines[i].trim()}');
    }
  }
  return offences;
}

void main() {
  test('no file under lib/presentation/ imports or references ApiException',
      () {
    final files = Directory(p.join('lib', 'presentation'))
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    expect(files, isNotEmpty);

    final offences = [
      for (final f in files)
        ...offencesIn(p.normalize(f.path), f.readAsStringSync()),
    ];
    expect(offences, isEmpty,
        reason: 'Convert ApiException in the repository layer instead '
            '(rethrowThai / rethrowServerRefusal → PosException):\n'
            '${offences.join('\n')}');
  });

  group('the scan itself', () {
    test('a // inside code does not hide the rest of the line', () {
      expect(
        offencesIn('x.dart', "final u = 'http://x'; if (e is ApiException) {}"),
        hasLength(1),
      );
    });

    test('a whole-line comment may name the type', () {
      expect(offencesIn('x.dart', '  // never an ApiException here'), isEmpty);
    });

    test('an import split over two lines is caught', () {
      expect(
        offencesIn('x.dart', "import\n    '../../core/network/api_exception.dart';"),
        hasLength(1),
      );
    });
  });
}
