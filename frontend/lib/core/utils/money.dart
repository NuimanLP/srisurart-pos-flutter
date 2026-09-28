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

/// Loyalty points granted for a sale total: `Math.floor(total / 10)`.
int pointsFor(num total) => (total / 10).floor();

/// A rate (e.g. `Settings.taxRate`) as a trimmed string for display in
/// "... N%" labels: whole numbers drop the decimal (`7` not `7.0`), a
/// fractional rate keeps it (`7.5`). Not currency — use `baht`/`baht2` for
/// money. #480: shared by the price-calculator tab and the shelf-label VAT%
/// text so both format a non-default VAT the same way.
String formatRate(num v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();
