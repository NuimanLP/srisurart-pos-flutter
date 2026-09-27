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

  test(
    'opening again the same day archives the prior shift and opens a new one '
    '(08 §11, #453 — several shifts a day)',
    () async {
      final first = await repo.openShift(1000);
      final second = await repo.openShift(9999);
      expect(second.id, isNot(first.id));
      expect(second.startingCash, 9999);
      expect(second.dateStr, today());
      expect(second.isActive, isTrue);

      final prior = await (db.select(
        db.shifts,
      )..where((t) => t.id.equals(first.id))).getSingle();
      expect(prior.isActive, isFalse);
      expect(prior.autoArchived, isTrue); // never counted
      expect(prior.archivedAt, isNotNull);

      final drawer = await repo.getCashDrawer();
      expect(drawer!.shift.id, second.id);
    },
  );

  test(
    'opening with an existing id returns that shift, archives nothing',
    () async {
      final first = await repo.openShift(1000, id: 'sh_client_1');
      expect(first.id, 'sh_client_1');

      final again = await repo.openShift(9999, id: 'sh_client_1');
      expect(again.id, 'sh_client_1');
      expect(again.startingCash, 1000); // unchanged
      expect(again.isActive, isTrue);

      final all = await db.select(db.shifts).get();
      expect(all.length, 1);
      expect(all.single.autoArchived, isFalse);
    },
  );

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

  group('cashCountFrom (08 §11, #452 — where a drawer count starts)', () {
    Future<ShiftRow> seed(
      String id,
      String dateStr,
      DateTime openedAt, {
      bool active = false,
    }) async {
      final row = ShiftRow(
        id: id,
        dateStr: dateStr,
        startingCash: 500,
        openedAt: openedAt,
        isActive: active,
        autoArchived: false,
      );
      await db.into(db.shifts).insert(row);
      return row;
    }

    test('the only shift of its day counts from midnight (null)', () async {
      final only = await seed('a', '2026-09-27', DateTime(2026, 9, 27, 8));
      expect(await repo.cashCountFrom(only), isNull);
    });

    test(
      'shifts opened before multi-shift reconcile as before: one per day, '
      'yesterday\'s never moves today\'s bound',
      () async {
        await seed('y', '2026-09-26', DateTime(2026, 9, 26, 8));
        final today = await seed(
          't',
          '2026-09-27',
          DateTime(2026, 9, 27, 8),
          active: true,
        );
        expect(await repo.cashCountFrom(today), isNull);
      },
    );

    test('a later shift of the same day counts from its own opening', () async {
      final first = await seed('1', '2026-09-27', DateTime(2026, 9, 27, 8));
      final second = await seed(
        '2',
        '2026-09-27',
        DateTime(2026, 9, 27, 14),
        active: true,
      );
      expect(await repo.cashCountFrom(second), DateTime(2026, 9, 27, 14));
      expect(await repo.cashCountFrom(first), isNull);
    });
  });
}
