import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/shifts_repository.dart';

void main() {
  late AppDatabase db;
  late ShiftsRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = ShiftsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  String today() => DateTime.now().toIso8601String().substring(0, 10);

  test('openShift creates an active shift', () async {
    final s = await repo.openShift(1000);
    expect(s.isActive, isTrue);
    expect(s.startingCash, 1000);
    expect(s.dateStr, today());
    expect(s.closedAt, isNull);
    expect(s.physicalCash, isNull);

    final drawer = await repo.getCashDrawer();
    expect(drawer, isNotNull);
    expect(drawer!.shift.id, s.id);
    expect(drawer.entries, isEmpty);
  });

  test('opening again the same day returns the same shift', () async {
    final first = await repo.openShift(1000);
    final second = await repo.openShift(9999);
    expect(second.id, first.id);
    expect(second.startingCash, 1000); // unchanged
    // Still exactly one shift in the DB, and it is active.
    final all = await db.select(db.shifts).get();
    expect(all.length, 1);
    expect(all.single.isActive, isTrue);
  });

  test(
    'opening on a different day archives the prior (never-closed → auto)',
    () async {
      // Seed a prior active shift dated yesterday that was never closed.
      const yId = 'sh_yesterday';
      await db
          .into(db.shifts)
          .insert(
            ShiftsCompanion.insert(
              id: yId,
              dateStr: '2020-01-01',
              startingCash: 500,
              openedAt: DateTime(2020, 1, 1, 8),
              isActive: const Value(true),
            ),
          );

      final fresh = await repo.openShift(1000);
      expect(fresh.dateStr, today());
      expect(fresh.isActive, isTrue);

      final prior = await (db.select(
        db.shifts,
      )..where((t) => t.id.equals(yId))).getSingle();
      expect(prior.isActive, isFalse);
      expect(prior.autoArchived, isTrue);
      expect(prior.archivedAt, isNotNull);

      // History contains exactly the archived prior shift.
      final history = await repo.getShiftHistory();
      expect(history.length, 1);
      expect(history.single.shift.id, yId);

      // Active drawer is the new shift.
      final drawer = await repo.getCashDrawer();
      expect(drawer!.shift.id, fresh.id);
    },
  );

  test(
    'opening on a different day after CLOSE archives without autoArchived',
    () async {
      // Prior active shift dated yesterday that WAS closed.
      const yId = 'sh_yesterday_closed';
      await db
          .into(db.shifts)
          .insert(
            ShiftsCompanion.insert(
              id: yId,
              dateStr: '2020-01-01',
              startingCash: 500,
              openedAt: DateTime(2020, 1, 1, 8),
              closedAt: Value(DateTime(2020, 1, 1, 18)),
              physicalCash: const Value(480),
              isActive: const Value(true),
            ),
          );

      await repo.openShift(1000);

      final prior = await (db.select(
        db.shifts,
      )..where((t) => t.id.equals(yId))).getSingle();
      expect(prior.isActive, isFalse);
      expect(prior.autoArchived, isFalse); // was closed, not auto-archived
      expect(prior.archivedAt, isNull);
    },
  );

  test('addDrawerEntry throws with no open shift', () async {
    expect(
      () => repo.addDrawerEntry('in', 100, 'tip'),
      throwsA(isA<Exception>()),
    );
  });

  test('addDrawerEntry inserts on the active shift', () async {
    await repo.openShift(1000);
    final e1 = await repo.addDrawerEntry('in', 100, 'first');
    final e2 = await repo.addDrawerEntry('out', 50, 'second');

    expect(e1.id.startsWith('de'), isTrue);
    expect(e1.note, 'first');
    expect(e2.amount, 50);

    final drawer = await repo.getCashDrawer();
    expect(drawer!.entries.length, 2);
    // Both entries are present on the active shift's drawer.
    expect(drawer.entries.map((e) => e.id).toSet(), {e1.id, e2.id});
  });

  test(
    'getCashDrawer returns drawer entries newest-first by createdAt',
    () async {
      final s = await repo.openShift(1000);
      // Insert with explicit, distinct createdAt timestamps to assert ordering
      // deterministically (real inserts span milliseconds).
      await db
          .into(db.drawerEntries)
          .insert(
            DrawerEntryRow(
              id: 'de_old',
              shiftId: s.id,
              type: 'in',
              amount: 10,
              note: '',
              createdAt: DateTime(2026, 1, 1, 9),
            ),
          );
      await db
          .into(db.drawerEntries)
          .insert(
            DrawerEntryRow(
              id: 'de_new',
              shiftId: s.id,
              type: 'in',
              amount: 20,
              note: '',
              createdAt: DateTime(2026, 1, 1, 17),
            ),
          );

      final drawer = await repo.getCashDrawer();
      expect(drawer!.entries.first.id, 'de_new');
      expect(drawer.entries.last.id, 'de_old');
    },
  );

  test('closeShift sets closedAt + physicalCash', () async {
    await repo.openShift(1000);
    final closed = await repo.closeShift(1234.5);
    expect(closed, isNotNull);
    expect(closed!.closedAt, isNotNull);
    expect(closed.physicalCash, 1234.5);
    // Stays active as the current drawer until next openShift.
    expect(closed.isActive, isTrue);

    final drawer = await repo.getCashDrawer();
    expect(drawer!.shift.id, closed.id);
  });

  test('closeShift returns null when no shift is open', () async {
    final closed = await repo.closeShift(100);
    expect(closed, isNull);
  });

  test('addDrawerEntry after close is blocked', () async {
    await repo.openShift(1000);
    await repo.closeShift(1000);
    expect(
      () => repo.addDrawerEntry('in', 100, 'late'),
      throwsA(isA<Exception>()),
    );
  });
}
