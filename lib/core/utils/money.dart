// Money helpers — currency formatting + JS-exact rounding.
//
// Quote currency in the JS app shows `฿N.toLocaleString()`. Rounding throughout
// db.js is `Math.round(value * 100) / 100`. Loyalty points are `Math.floor(total / 10)`.

import 'package:intl/intl.dart';

final NumberFormat _bahtFormat = NumberFormat('#,##0.##');

/// Formats a number as a baht string, e.g. `฿1,250.5` / `฿85`.
String baht(num v) => '฿${_bahtFormat.format(v)}';

/// JS-exact 2-decimal rounding: `Math.round(v * 100) / 100`.
/// Returned as a double.
double round2(num v) => (v * 100).round() / 100;

/// Loyalty points granted for a sale total: `Math.floor(total / 10)`.
int pointsFor(num total) => (total / 10).floor();
