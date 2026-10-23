// The cash-out category rules (owner 2026-10-23): a standard note prefix
// written by the chips, read back exactly (no keyword guessing), and a monthly
// summary whose groups add up to the month's total cash-out in satang.

import 'package:flutter_test/flutter_test.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/domain/reports/drawer_expense.dart';

DrawerEntryRow _e(
  String type,
  double amount,
  String? note,
  DateTime at, {
  String? id,
}) => DrawerEntryRow(
  id: id ?? '$type-$amount-$note-${at.microsecondsSinceEpoch}',
  shiftId: 'sh',
  type: type,
  amount: amount,
  note: note,
  createdAt: at,
);

void main() {
  group('expenseCategoryOf', () {
    for (final (note, want) in <(String?, String?)>[
      ('ค่าไฟ', 'ค่าไฟ'),
      ('ค่าไฟ: เดือน ต.ค.', 'ค่าไฟ'),
      ('ค่าไฟ:เดือน ต.ค.', 'ค่าไฟ'),
      ('  ค่าแรง: นาย ก  ', 'ค่าแรง'),
      ('ค่าน้ำ: ', 'ค่าน้ำ'),
      ('จ่ายซัพ: ร้านจินเส็ง', 'จ่ายซัพ'),
      ('อื่นๆ: น้ำแข็ง', 'อื่นๆ'),
      // Not a prefix: a longer word that merely starts with a category.
      ('ค่าน้ำมัน', null),
      ('ค่าน้ำมัน: รถส่งของ', null),
      ('ค่าไฟเดือนนี้', null),
      ('จ่ายค่าไฟ', null),
      ('เติมทอน', null),
      ('', null),
      ('   ', null),
      (null, null),
    ]) {
      test('"$note" → $want', () => expect(expenseCategoryOf(note), want));
    }
  });

  group('withExpenseCategory (chip tap)', () {
    test('blank note → prefix ready for typing', () {
      expect(withExpenseCategory('ค่าไฟ', ''), 'ค่าไฟ: ');
      expect(withExpenseCategory('ค่าไฟ', '  '), 'ค่าไฟ: ');
    });
    test('free text already typed is kept after the prefix', () {
      expect(withExpenseCategory('ค่าแรง', 'นาย ก'), 'ค่าแรง: นาย ก');
    });
    test('another chip replaces the prefix, keeping the free text', () {
      expect(
        withExpenseCategory('ค่าน้ำ', 'ค่าไฟ: บิล ต.ค.'),
        'ค่าน้ำ: บิล ต.ค.',
      );
      expect(withExpenseCategory('ค่าน้ำ', 'ค่าไฟ: '), 'ค่าน้ำ: ');
      expect(withExpenseCategory('ค่าน้ำ', 'ค่าไฟ'), 'ค่าน้ำ: ');
    });
    test('a non-prefix word stays as free text', () {
      expect(withExpenseCategory('อื่นๆ', 'ค่าน้ำมัน'), 'อื่นๆ: ค่าน้ำมัน');
    });
  });

  group('normaliseExpenseNote (save)', () {
    test('a prefix is saved in its standard shape', () {
      expect(normaliseExpenseNote('ค่าไฟ: '), 'ค่าไฟ');
      expect(normaliseExpenseNote('ค่าไฟ:  บิล ต.ค. '), 'ค่าไฟ: บิล ต.ค.');
      expect(normaliseExpenseNote('ค่าไฟ:บิล'), 'ค่าไฟ: บิล');
    });
    test('any other note is unchanged, byte for byte', () {
      for (final n in ['', '  ', 'จ่ายซัพ ร้าน ก ', 'ค่าน้ำมัน', 'เติมทอน']) {
        expect(normaliseExpenseNote(n), n);
      }
    });
  });

  group('expenseGroupOf', () {
    test('categories, อื่นๆ/ไม่ระบุ and blank are distinct groups', () {
      expect(expenseGroupOf('ค่าน้ำ'), 'ค่าน้ำ');
      expect(expenseGroupOf('อื่นๆ: น้ำแข็ง'), otherOrUnknownGroup);
      expect(expenseGroupOf('ค่าน้ำมัน'), otherOrUnknownGroup);
      expect(expenseGroupOf(''), blankNoteGroup);
      expect(expenseGroupOf('  '), blankNoteGroup);
      expect(expenseGroupOf(null), blankNoteGroup);
    });
  });

  group('summariseDrawerOut', () {
    final oct = DateTime(2026, 10, 15, 10);
    final entries = [
      _e('out', 450.25, 'ค่าไฟ: บิล ก.ย.', oct),
      _e('out', 120, 'ค่าไฟ', oct),
      _e('out', 99.99, 'ค่าน้ำ', oct),
      _e('out', 3000, 'ค่าแรง: นาย ก', oct),
      _e('out', 0.1, 'จ่ายซัพ', oct),
      _e('out', 0.2, 'จ่ายซัพ', oct),
      _e('out', 55.5, 'อื่นๆ: น้ำแข็ง', oct),
      _e('out', 80, 'ค่าน้ำมัน', oct),
      _e('out', 33.33, '', oct),
      _e('out', 1, null, oct),
      // Excluded: cash in, and the neighbouring months.
      _e('in', 2000, 'เติมทอน', oct),
      _e('in', 500, 'ค่าไฟ', oct),
      _e('out', 777, 'ค่าไฟ', DateTime(2026, 9, 30, 23, 59, 59, 999)),
      _e('out', 888, 'ค่าไฟ', DateTime(2026, 11, 1)),
    ];

    test('groups add up to the month total of out entries (satang)', () {
      final s = summariseDrawerOut(entries, '2026-10');
      final monthOut = entries
          .where(
            (e) =>
                e.type == 'out' &&
                e.createdAt.year == 2026 &&
                e.createdAt.month == 10,
          )
          .fold<int>(0, (a, e) => a + (e.amount * 100).round());
      expect(s.totalSatang, monthOut);
      expect(s.totalSatang, 384037);
      expect(s.groups.fold<int>(0, (a, g) => a + g.satang), s.totalSatang);
      expect(s.groups.fold<int>(0, (a, g) => a + g.count), s.count);
      expect(s.count, 10);
    });

    test('per group count and satang, in display order', () {
      final s = summariseDrawerOut(entries, '2026-10');
      expect(
        [for (final g in s.groups) (g.group, g.count, g.satang)],
        [
          ('ค่าน้ำ', 1, 9999),
          ('ค่าไฟ', 2, 57025),
          ('ค่าแรง', 1, 300000),
          // 0.1 + 0.2 in doubles is 0.30000000000000004; satang add exactly.
          ('จ่ายซัพ', 2, 30),
          (otherOrUnknownGroup, 2, 13550),
          (blankNoteGroup, 2, 3433),
        ],
      );
    });

    test('month boundaries: first and last instant are in, neighbours out', () {
      final edge = [
        _e('out', 1, 'ค่าไฟ', DateTime(2026, 10, 1)),
        _e('out', 2, 'ค่าไฟ', DateTime(2026, 10, 31, 23, 59, 59, 999)),
        _e('out', 4, 'ค่าไฟ', DateTime(2026, 9, 30, 23, 59, 59, 999)),
        _e('out', 8, 'ค่าไฟ', DateTime(2026, 11, 1)),
      ];
      expect(summariseDrawerOut(edge, '2026-10').totalSatang, 300);
      expect(summariseDrawerOut(edge, '2026-09').totalSatang, 400);
      expect(summariseDrawerOut(edge, '2026-11').totalSatang, 800);
    });

    test('a month with only cash-in is empty', () {
      final s = summariseDrawerOut([_e('in', 500, 'ค่าไฟ', oct)], '2026-10');
      expect(s.count, 0);
      expect(s.totalSatang, 0);
      expect(s.groups, isEmpty);
    });
  });
}
