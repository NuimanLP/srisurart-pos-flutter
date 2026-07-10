// thai_format — small date/number formatting helpers for the UI layer.
//
// Money lives in core/utils/money.dart (baht()); these cover dates and plain
// number grouping so screens don't re-create NumberFormat/DateFormat instances.
// Dates render in Buddhist-era (พ.ศ.) to match the Thai POS receipts/reports.

import 'package:intl/intl.dart';

final NumberFormat _intFmt = NumberFormat('#,##0');
final DateFormat _dMonthFmt = DateFormat('d MMM', 'th');
final DateFormat _timeFmt = DateFormat('HH:mm');

/// Thousands-grouped integer, e.g. 12345 → "12,345".
String thaiInt(num v) => _intFmt.format(v);

/// Short Thai date with Buddhist year, e.g. "23 มิ.ย. 2569".
String thaiDate(DateTime d) {
  final be = d.year + 543;
  return '${_dMonthFmt.format(d)} $be';
}

/// Date + time, e.g. "23 มิ.ย. 2569 14:35".
String thaiDateTime(DateTime d) => '${thaiDate(d)} ${_timeFmt.format(d)}';

/// HH:mm only.
String thaiTime(DateTime d) => _timeFmt.format(d);

String _two(int n) => n.toString().padLeft(2, '0');

/// Numeric Buddhist-era date, e.g. "23/06/2569" — matches the JS
/// `toLocaleDateString('th-TH')` shape used in CSV exports and receipts.
String thaiDateSlash(DateTime d) =>
    '${_two(d.day)}/${_two(d.month)}/${d.year + 543}';

/// Numeric date + time, e.g. "23/06/2569 14:35" — matches the JS
/// `toLocaleString('th-TH')` shape (BE year, 24h time).
String thaiDateTimeSlash(DateTime d) =>
    '${thaiDateSlash(d)} ${_timeFmt.format(d)}';
