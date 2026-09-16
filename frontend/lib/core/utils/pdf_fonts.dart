// Local (bundled-asset) replacements for the `printing` package's
// `PdfGoogleFonts.sarabun*()` / `.barlowCondensedBold()` (#271).
//
// `PdfGoogleFonts` fetches its TTF over the network on first use — the same
// offline-PWA problem `google_fonts` had (flutter#163554), but it is a
// *separate* mechanism: setting `GoogleFonts.config.allowRuntimeFetching =
// false` (see main.dart) does nothing for it. These four weights are the
// same TTFs declared as the `Sarabun` / `BarlowCondensed` font families in
// pubspec.yaml (see core/theme/app_theme.dart), loaded directly as
// `pw.Font`s via `rootBundle` instead of fetched from fonts.gstatic.com.
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;

/// Bundled PDF fonts for receipt / credit-note / quote / report generation.
/// Each getter loads its [pw.Font] once and caches the in-flight Future.
class PosPdfFonts {
  PosPdfFonts._();

  static Future<pw.Font>? _sarabunRegular;
  static Future<pw.Font>? _sarabunSemiBold;
  static Future<pw.Font>? _sarabunBold;
  static Future<pw.Font>? _barlowCondensedBold;

  static Future<pw.Font> _load(String asset) async {
    final bytes = await rootBundle.load(asset);
    return pw.Font.ttf(bytes);
  }

  // A failed load (missing/corrupt asset, e.g. a stale web deploy) must not be
  // cached forever — `??=` assigns the Future synchronously, so a rejected one
  // would otherwise permanently break printing for the rest of the session.
  // Clearing the field on error lets the next call retry.
  static Future<pw.Font> sarabunRegular() =>
      _sarabunRegular ??= _load(
        'assets/fonts/Sarabun-Regular.ttf',
      ).onError((e, st) {
        _sarabunRegular = null;
        Error.throwWithStackTrace(e!, st);
      });

  static Future<pw.Font> sarabunSemiBold() =>
      _sarabunSemiBold ??= _load(
        'assets/fonts/Sarabun-SemiBold.ttf',
      ).onError((e, st) {
        _sarabunSemiBold = null;
        Error.throwWithStackTrace(e!, st);
      });

  static Future<pw.Font> sarabunBold() =>
      _sarabunBold ??= _load('assets/fonts/Sarabun-Bold.ttf').onError((e, st) {
        _sarabunBold = null;
        Error.throwWithStackTrace(e!, st);
      });

  static Future<pw.Font> barlowCondensedBold() =>
      _barlowCondensedBold ??= _load(
        'assets/fonts/BarlowCondensed-Bold.ttf',
      ).onError((e, st) {
        _barlowCondensedBold = null;
        Error.throwWithStackTrace(e!, st);
      });
}
