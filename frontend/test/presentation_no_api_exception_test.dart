// CLAUDE.md binding rule: "An `ApiException` must never reach a screen —
// convert via `rethrowThai` / `rethrowServerRefusal` to a plain Thai-string
// `Exception`/`PosException`." The conversion belongs in the repository
// layer (as `AuthRepository.login`/`changePassword` and
// `OfflinePinRepository.setPin` do), so nothing under lib/presentation/ may
// import the HTTP error type or inspect it. Checked at the source level so a
// future screen cannot reintroduce it. `PosException` lives in
// `core/errors/pos_exception.dart` for exactly this reason.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final _apiExceptionImport = RegExp(r'''import\s+['"][^'"]*api_exception\.dart['"]''');
final _apiExceptionRef = RegExp(r'\bApiException\b');

void main() {
  test('no file under lib/presentation/ imports or references ApiException',
      () {
    final files = Directory('lib/presentation')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    expect(files, isNotEmpty);

    final offences = <String>[];
    for (final f in files) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        // Comments may name the type when explaining why it is absent.
        final code = lines[i].split('//').first;
        if (_apiExceptionImport.hasMatch(code) ||
            _apiExceptionRef.hasMatch(code)) {
          offences.add('${p.normalize(f.path)}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(offences, isEmpty,
        reason: 'Convert ApiException in the repository layer instead '
            '(rethrowThai / rethrowServerRefusal → PosException):\n'
            '${offences.join('\n')}');
  });
}
