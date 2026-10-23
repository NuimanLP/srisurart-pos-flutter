// drawer_expense.dart — the expense categories of a cash-drawer "out" entry
// and the monthly "เงินสดออกไปไหน" summary (owner 2026-10-23: water,
// electricity and wages are paid out of the drawer; there is no accountant).
//
// No schema change: the category lives in the entry's free-text `note` as a
// standard prefix — `ค่าไฟ` or `ค่าไฟ: <free text>` — written by the chips on
// the cash-drawer screen. Only that exact shape is recognised (no keyword
// guessing): `ค่าน้ำมัน` is NOT `ค่าน้ำ`. Pure functions only.
//
// 🔴 The summary groups entries by the LOCAL CALENDAR MONTH of `createdAt`,
// NOT by shift — on purpose: it answers "what did the shop pay out in
// October". An entry at 00:30 on 1 Nov in a shift opened 31 Oct counts in
// November here, while that shift's drawer count
// (`ShiftsRepository.drawerCash`, by shift) still includes it. Do not "fix"
// this toward the shift rule.

import '../../core/utils/dates.dart';
import '../../core/utils/money.dart';
import '../../data/db/database.dart';

/// The catch-all chip.
const String otherCategory = 'อื่นๆ';

/// The chip categories, in chip order.
const List<String> expenseCategories = [
  'ค่าน้ำ',
  'ค่าไฟ',
  'ค่าแรง',
  'จ่ายซัพ',
  otherCategory,
];

/// Report group: the `อื่นๆ` chip plus any note without a standard prefix.
const String otherOrUnknownGroup = 'อื่นๆ/ไม่ระบุ';

/// Report group: an out entry with a blank note (kept apart from อื่นๆ).
const String blankNoteGroup = 'ไม่มีหมายเหตุ';

/// Report groups, in display order: each named category, then the two
/// catch-alls.
final List<String> expenseGroups = [
  for (final c in expenseCategories)
    if (c != otherCategory) c,
  otherOrUnknownGroup,
  blankNoteGroup,
];

/// The category and free text of [note], when it starts with a standard
/// prefix: exactly `<category>`, or `<category>:` followed by anything.
({String category, String rest})? _split(String? note) {
  final t = (note ?? '').trim();
  for (final c in expenseCategories) {
    if (t == c) return (category: c, rest: '');
    if (t.startsWith('$c:')) {
      return (category: c, rest: t.substring(c.length + 1).trim());
    }
  }
  return null;
}

/// The chip category of [note], or null when it has no standard prefix.
String? expenseCategoryOf(String? note) => _split(note)?.category;

/// What a tap on [category]'s chip leaves in the note field: the prefix, with
/// any free text already typed kept after it (an earlier chip's prefix is
/// replaced, not stacked). Ends in `: ` so typing continues after the colon.
String withExpenseCategory(String category, String note) {
  final rest = _split(note)?.rest ?? note.trim();
  return rest.isEmpty ? '$category: ' : '$category: $rest';
}

/// [note] without its category prefix (the free text only); a note with no
/// prefix is returned unchanged.
String withoutExpenseCategory(String note) => _split(note)?.rest ?? note;

/// The note to save for an out entry whose chip was tapped: a recognised prefix in its standard
/// shape (`ค่าไฟ` / `ค่าไฟ: text`); any other note is returned unchanged.
String normaliseExpenseNote(String note) {
  final s = _split(note);
  if (s == null) return note;
  return s.rest.isEmpty ? s.category : '${s.category}: ${s.rest}';
}

/// The report group of an out entry's [note] (one of [expenseGroups]).
String expenseGroupOf(String? note) {
  if ((note ?? '').trim().isEmpty) return blankNoteGroup;
  final c = expenseCategoryOf(note);
  return (c == null || c == otherCategory) ? otherOrUnknownGroup : c;
}

class ExpenseGroupTotal {
  final String group;
  final int count;
  final int satang;
  const ExpenseGroupTotal(this.group, this.count, this.satang);
}

class DrawerExpenseSummary {
  /// Non-empty groups, in [expenseGroups] order.
  final List<ExpenseGroupTotal> groups;

  /// Every out entry of the month, in satang — the sum of [groups].
  final int totalSatang;
  final int count;
  const DrawerExpenseSummary(this.groups, this.totalSatang, this.count);
}

/// The out entries of [month] (a `yyyy-MM` key of the LOCAL month of
/// `createdAt` — not the shift, see the header) grouped by
/// [expenseGroupOf]. Every out entry lands in exactly one group, so the
/// groups add up to [DrawerExpenseSummary.totalSatang]. `in` entries are
/// ignored.
DrawerExpenseSummary summariseDrawerOut(
  Iterable<DrawerEntryRow> entries,
  String month,
) {
  final counts = <String, int>{};
  final sums = <String, int>{};
  var total = 0;
  var count = 0;
  for (final e in entries) {
    if (e.type != 'out' || monthKey(e.createdAt) != month) continue;
    final g = expenseGroupOf(e.note);
    final s = toSatang(e.amount);
    counts[g] = (counts[g] ?? 0) + 1;
    sums[g] = (sums[g] ?? 0) + s;
    total += s;
    count++;
  }
  return DrawerExpenseSummary(
    [
      for (final g in expenseGroups)
        if (counts.containsKey(g)) ExpenseGroupTotal(g, counts[g]!, sums[g]!),
    ],
    total,
    count,
  );
}
