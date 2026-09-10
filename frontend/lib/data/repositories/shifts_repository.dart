// ShiftsRepository — cash-drawer shifts + drawer entries.
//
// Ports db.js lines 546-585 (getCashDrawer / getShiftHistory / openShift /
// addDrawerEntry / closeShift). In db.js a single active shift lives in
// `sa_cash_drawer` and every past shift in `sa_shift_history`. Here, per
// CONTRACT §2 mapping notes, the single active shift is the Shifts row with
// isActive == true; all other Shifts rows are the history.
//
// Behaviour parity points:
//   - openShift: same-day re-open returns the existing active shift unchanged;
//     otherwise the prior active shift is archived FIRST (isActive=false, and
//     if it was never closed: autoArchived=true + archivedAt=now) so a day is
//     never lost, then a fresh active shift is inserted. Wrapped in a txn.
//   - addDrawerEntry: throws 'No open shift' if none active; blocks new money
//     entries once the active shift is closed (CLAUDE.md: the cash drawer
//     blocks new money entries after close).
//   - closeShift: stamps closedAt + physicalCash on the active shift; it stays
//     isActive=true (the current drawer) until the next openShift archives it.

import 'package:drift/drift.dart';

import '../../core/utils/dates.dart';
import '../../core/utils/ids.dart';
import '../../domain/models/aggregates.dart';
import '../db/database.dart';

class ShiftsRepository {
  final AppDatabase db;
  ShiftsRepository(this.db);

  /// The single active shift (isActive == true) with its drawer entries
  /// (newest first), or null when no drawer is open.
  Future<ShiftWithEntries?> getCashDrawer() async {
    final shift =
        await (db.select(db.shifts)
              ..where((t) => t.isActive.equals(true))
              ..orderBy([(t) => OrderingTerm.desc(t.openedAt)])
              ..limit(1))
            .getSingleOrNull();
    if (shift == null) return null;
    final entries = await _entriesFor(shift.id);
    return ShiftWithEntries(shift, entries);
  }

  /// All inactive shifts (isActive == false), newest openedAt first, each with
  /// its drawer entries.
  Future<List<ShiftWithEntries>> getShiftHistory() async {
    final shifts =
        await (db.select(db.shifts)
              ..where((t) => t.isActive.equals(false))
              ..orderBy([(t) => OrderingTerm.desc(t.openedAt)]))
            .get();
    final result = <ShiftWithEntries>[];
    for (final s in shifts) {
      result.add(ShiftWithEntries(s, await _entriesFor(s.id)));
    }
    return result;
  }

  /// Drawer entries for a shift, newest first.
  Future<List<DrawerEntryRow>> _entriesFor(String shiftId) {
    return (db.select(db.drawerEntries)
          ..where((t) => t.shiftId.equals(shiftId))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
  }

  /// Open a shift for today. If an active shift already exists for the same
  /// dateStr, returns it unchanged. Otherwise archives the prior active shift
  /// FIRST (never lose a day) and inserts a new active shift.
  Future<ShiftRow> openShift(double startingCash) {
    return db.transaction(() async {
      final today = todayKey();

      final existing =
          await (db.select(db.shifts)
                ..where((t) => t.isActive.equals(true))
                ..orderBy([(t) => OrderingTerm.desc(t.openedAt)])
                ..limit(1))
              .getSingleOrNull();

      if (existing != null && existing.dateStr == today) {
        return existing;
      }

      // Archive the prior active shift BEFORE opening a new one.
      if (existing != null) {
        final now = DateTime.now();
        final autoArchive = existing.closedAt == null;
        await (db.update(
          db.shifts,
        )..where((t) => t.id.equals(existing.id))).write(
          ShiftsCompanion(
            isActive: const Value(false),
            autoArchived: autoArchive
                ? const Value(true)
                : Value(existing.autoArchived),
            archivedAt: autoArchive ? Value(now) : Value(existing.archivedAt),
          ),
        );
      }

      final id = newId('sh');
      await db
          .into(db.shifts)
          .insert(
            ShiftsCompanion.insert(
              id: id,
              dateStr: today,
              startingCash: startingCash,
              openedAt: DateTime.now(),
              isActive: const Value(true),
            ),
          );

      return (db.select(db.shifts)..where((t) => t.id.equals(id))).getSingle();
    });
  }

  /// Add a drawer entry to the active shift. Throws if no shift is open, and
  /// blocks new entries once the active shift has been closed.
  Future<DrawerEntryRow> addDrawerEntry(
    String type,
    double amount,
    String? note,
  ) async {
    final shift =
        await (db.select(db.shifts)
              ..where((t) => t.isActive.equals(true))
              ..orderBy([(t) => OrderingTerm.desc(t.openedAt)])
              ..limit(1))
            .getSingleOrNull();
    if (shift == null) throw Exception('No open shift');
    if (shift.closedAt != null) {
      throw Exception('ลิ้นชักปิดแล้ว ไม่สามารถบันทึกรายการเงินเพิ่มได้');
    }

    final row = DrawerEntryRow(
      id: newId('de'),
      shiftId: shift.id,
      type: type,
      amount: amount,
      note: note ?? '',
      createdAt: DateTime.now(),
    );
    await db.into(db.drawerEntries).insert(row);
    return row;
  }

  /// Close the active shift: stamp closedAt + physicalCash. The shift stays
  /// isActive=true (the current drawer) until the next openShift archives it.
  /// Returns the updated row, or null when no shift is open.
  Future<ShiftRow?> closeShift(double physicalCash) async {
    final shift =
        await (db.select(db.shifts)
              ..where((t) => t.isActive.equals(true))
              ..orderBy([(t) => OrderingTerm.desc(t.openedAt)])
              ..limit(1))
            .getSingleOrNull();
    if (shift == null) return null;

    await (db.update(db.shifts)..where((t) => t.id.equals(shift.id))).write(
      ShiftsCompanion(
        closedAt: Value(DateTime.now()),
        physicalCash: Value(physicalCash),
      ),
    );
    return (db.select(
      db.shifts,
    )..where((t) => t.id.equals(shift.id))).getSingle();
  }
}
