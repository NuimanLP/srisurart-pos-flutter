// Money helpers — currency formatting + JS-exact rounding.
//
// Quote currency in the JS app shows `฿N.toLocaleString()`. Rounding throughout
// db.js is `Math.round(value * 100) / 100`. Loyalty points are `Math.floor(total / 10)`.

import 'package:intl/intl.dart';

final NumberFormat _bahtFormat = NumberFormat('#,##0.##');
final NumberFormat _baht2Format = NumberFormat('#,##0.00');

/// Formats a number as a baht string, e.g. `฿1,250.5` / `฿85`.
String baht(num v) => '฿${_bahtFormat.format(v)}';

/// Baht with exactly 2 decimals, e.g. `฿1,250.50` / `฿85.00`.
/// For cost/margin views where the fixed precision is part of the display.
String baht2(num v) => '฿${_baht2Format.format(v)}';

/// JS-exact 2-decimal rounding: `Math.round(v * 100) / 100`.
/// Returned as a double.
double round2(num v) => (v * 100).round() / 100;

/// Money in integer satang, e.g. `450.25` → `45025` — add satang, not doubles.
int toSatang(num amount) => (amount * 100).round();

/// Satang as a CSV money cell: `1234.50`, negatives in accounting brackets
/// `(107.00)`. Brackets, not a minus sign: csvSafe (which every CSV cell
/// passes) turns a leading `-` into `'-…` text, while Excel reads `(107.00)`
/// as the number −107.
String csvMoney(int satang) {
  final abs = satang.abs();
  final text = '${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
  return satang < 0 ? '($text)' : text;
}

/// Loyalty points granted for a sale total: `Math.floor(total / 10)`.
int pointsFor(num total) => (total / 10).floor();

/// A rate (e.g. `Settings.taxRate`) as a trimmed string for display in
/// "... N%" labels: whole numbers drop the decimal (`7` not `7.0`), a
/// fractional rate keeps it (`7.5`). Not currency — use `baht`/`baht2` for
/// money. #480: shared by the price-calculator tab and the shelf-label VAT%
/// text so both format a non-default VAT the same way.
String formatRate(num v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();
