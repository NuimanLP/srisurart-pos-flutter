// Regression test for #271: the five font assets `pubspec.yaml` declares and
// `core/theme/app_theme.dart` / `core/utils/pdf_fonts.dart` reference by
// literal path must actually exist and load. Nothing else catches this — a
// typo'd asset key or a `fonts:` block lost in a merge is invisible to
// `dart analyze`, and `flutter test` never exercises the theme's `fontFamily`
// resolution against real glyph data (see the note in
// checkout_credit_override_test.dart: the bundled face isn't loaded in
// tests). This only proves the files are present and declared, not that the
// on-screen/PDF rendering looks right.

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/core/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const assets = [
    'assets/fonts/Sarabun-Regular.ttf',
    'assets/fonts/Sarabun-Medium.ttf',
    'assets/fonts/Sarabun-SemiBold.ttf',
    'assets/fonts/Sarabun-Bold.ttf',
    'assets/fonts/BarlowCondensed-Bold.ttf',
  ];

  for (final asset in assets) {
    test('$asset is bundled and loads', () async {
      final data = await rootBundle.load(asset);
      expect(data.lengthInBytes, greaterThan(0));
    });
  }

  test('AppTheme.light uses the bundled Sarabun family', () {
    expect(AppTheme.light.textTheme.bodyMedium!.fontFamily, 'Sarabun');
  });
}
