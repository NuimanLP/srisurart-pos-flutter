// ShiftsRepository — cash-drawer shifts + drawer entries.
//
// Ports db.js lines 546-585 (getCashDrawer / getShiftHistory / openShift /
// addDrawerEntry / closeShift). In db.js a single active shift lives in
// `sa_cash_drawer` and every past shift in `sa_shift_history`. Here, per
// CONTRACT §2 mapping notes, the single active shift is the Shifts row with
// isActive == true; all other Shifts rows are the history.
//
// Behaviour parity points:
//   - openShift (08 §11, #453 — several shifts a day): re-opening with an id
//     that already exists returns that shift unchanged; otherwise the prior
//     active shift is archived FIRST (isActive=false, and if it was never
//     closed: autoArchived=true + archivedAt=now) so a shift is never lost,
//     then a fresh active shift is inserted. Wrapped in a txn.
//   - addDrawerEntry: throws 'No open shift' if none active; blocks new money
//     entries once the active shift is closed (CLAUDE.md: the cash drawer
//     blocks new money entries after close); refuses a cash-out larger than
//     the drawer's expected cash ([drawerCash], owner 2026-10-03).
//   - closeShift: stamps closedAt + physicalCash on the active shift; it stays
//     isActive=true (the current drawer) until the next openShift archives it.

import 'package:drift/drift.dart';

import '../../core/network/api_exception.dart';
import '../../core/utils/dates.dart';
import '../../core/utils/ids.dart';
import '../../core/utils/money.dart';
import '../../domain/models/aggregates.dart';
import '../../domain/reports/net_sales.dart';
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

  /// The cash [drawer] should hold right now, piece by piece — the ONE client
  /// rule, used by the cash-drawer screen, the closing report's drawer check
  /// and [assertCashOutFits]:
  ///
  ///   starting cash + cash sales + cash credit payments − cash refunds
  ///   + money in − money out
  ///
  /// 🔴 Counted BY SHIFT (owner 2026-10-03, replacing #452's time window):
  /// every baht taken or paid while a shift is open belongs to that shift,
  /// even past midnight — the server's `shift_id` rule
  /// (`server/src/reports/drawer-cash.sql.ts`). How each row is attributed:
  ///   • drawer entries — `DrawerEntries.shiftId` ([drawer]'s own entries);
  ///   • sales — `Sales.shiftId == shift.id`; a sale with no `shiftId` (the
  ///     Drift build never stamps one) by its `date` in the shift's interval;
  ///   • returns, credit payments — no shift column locally: by `date` in the
  ///     shift's interval.
  /// The interval is `[openedAt, closedAt]`, open-ended while the shift is
  /// open. A manually voided bill is out; an auto-voided one (credit note in
  /// any shift) stays in ([drawerCashSalesOf]); credit payments count only
  /// in cash ([isCashCreditPayment]).
  Future<DrawerCash> drawerCash(ShiftWithEntries drawer) async {
    final shift = drawer.shift;
    Expression<bool> inShift(GeneratedColumn<DateTime> date) {
      final closed = shift.closedAt;
      final opened = date.isBiggerOrEqualValue(shift.openedAt);
      return closed == null ? opened : opened & date.isSmallerOrEqualValue(closed);
    }

    final sales =
        await (db.select(db.sales)..where(
              (t) =>
                  t.shiftId.equals(shift.id) |
                  (t.shiftId.isNull() & inShift(t.date)),
            ))
            .get();
    final saleIds = [for (final s in sales) s.id];
    final returnedSaleIds = saleIds.isEmpty
        ? <String>{}
        : (await (db.selectOnly(db.returns)
                    ..addColumns([db.returns.saleId])
                    ..where(db.returns.saleId.isIn(saleIds)))
                  .map((r) => r.read(db.returns.saleId)!)
                  .get())
              .toSet();
    final returns = await (db.select(
      db.returns,
    )..where((t) => inShift(t.date))).get();
    final creditPayments = await (db.select(
      db.creditPayments,
    )..where((t) => inShift(t.date))).get();

    double sumEntries(String type) => round2(
      drawer.entries
          .where((e) => e.type == type)
          .fold<double>(0, (s, e) => s + e.amount),
    );

    return DrawerCash(
      startingCash: shift.startingCash,
      cashSales: drawerCashSalesOf(sales, returnedSaleIds),
      cashCreditPayments: creditPayments
          .where((p) => isCashCreditPayment(p.note))
          .fold<double>(0, (s, p) => s + p.amount),
      cashRefunds: returns
          .where((r) => r.refundMethod == 'เงินสด')
          .fold<double>(0, (s, r) => s + r.refundTotal),
      totalIn: sumEntries('in'),
      totalOut: sumEntries('out'),
    );
  }

  /// Refuses a cash-out of [amount] from [shift] larger than its expected
  /// cash ([drawerCash]) — `PosException('DRAWER_INSUFFICIENT_CASH')`. Cash-in
  /// is never limited. The ONE guard for the Drift build's [addDrawerEntry] and
  /// the API build's offline queue (owner 2026-10-03); the server's online
  /// `409 DRAWER_INSUFFICIENT_CASH` is the same refusal.
  Future<void> assertCashOutFits(
    ShiftRow shift,
    String type,
    double amount,
  ) async {
    if (type != 'out') return;
    final expected = (await drawerCash(
      ShiftWithEntries(shift, await _entriesFor(shift.id)),
    )).expected;
    if (exceedsDrawer(amount, expected)) {
      throw PosException(
        'DRAWER_INSUFFICIENT_CASH',
        drawerInsufficientCashMessage(expected),
      );
    }
  }

  /// Drawer entries for a shift, newest first.
  Future<List<DrawerEntryRow>> _entriesFor(String shiftId) {
    return (db.select(db.drawerEntries)
          ..where((t) => t.shiftId.equals(shiftId))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
  }

  /// Open a new shift (08 §11 — several shifts a day are allowed). If [id]
  /// names a shift that already exists, returns it unchanged and archives
  /// nothing. Otherwise archives the prior active shift FIRST (never lose a
  /// shift), even one opened today, and inserts a new active shift under [id]
  /// (or a fresh one).
  Future<ShiftRow> openShift(double startingCash, {String? id}) {
    return db.transaction(() async {
      if (id != null) {
        final existingById = await (db.select(
          db.shifts,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        if (existingById != null) return existingById;
      }

      final existing =
          await (db.select(db.shifts)
                ..where((t) => t.isActive.equals(true))
                ..orderBy([(t) => OrderingTerm.desc(t.openedAt)])
                ..limit(1))
              .getSingleOrNull();

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

      final shiftId = id ?? newId('sh');
      await db
          .into(db.shifts)
          .insert(
            ShiftsCompanion.insert(
              id: shiftId,
              dateStr: todayKey(),
              startingCash: startingCash,
              openedAt: DateTime.now(),
              isActive: const Value(true),
            ),
          );

      return (db.select(
        db.shifts,
      )..where((t) => t.id.equals(shiftId))).getSingle();
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
    await assertCashOutFits(shift, type, amount);

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

/// The drawer's expected cash, piece by piece ([ShiftsRepository.drawerCash]).
class DrawerCash {
  final double startingCash;
  final double cashSales;
  final double cashCreditPayments;
  final double cashRefunds;
  final double totalIn;
  final double totalOut;
  const DrawerCash({
    required this.startingCash,
    required this.cashSales,
    required this.cashCreditPayments,
    required this.cashRefunds,
    required this.totalIn,
    required this.totalOut,
  });

  /// No shift — nothing to count.
  static const empty = DrawerCash(
    startingCash: 0,
    cashSales: 0,
    cashCreditPayments: 0,
    cashRefunds: 0,
    totalIn: 0,
    totalOut: 0,
  );

  double get expected => round2(
    startingCash +
        cashSales +
        cashCreditPayments -
        cashRefunds -
        totalOut +
        totalIn,
  );
}

/// Whether a cash-out of [amount] is more than the drawer's [expected] cash —
/// compared in whole satang, so exactly the expected amount is allowed.
bool exceedsDrawer(double amount, double expected) =>
    (amount * 100).round() > (expected * 100).round();

/// Owner, 2026-10-03: a cash-out larger than the drawer holds is refused.
/// Ratified by the owner 2026-10-03 (PR #580) — 02_API_SCREENS.md §8/§8.1.
/// With the amount when it is known; the plain form otherwise (server path).
String drawerInsufficientCashMessage([num? have]) => have == null
    ? 'เงินในลิ้นชักไม่พอ'
    : 'เงินในลิ้นชักไม่พอ (มี ${baht(have)})';
