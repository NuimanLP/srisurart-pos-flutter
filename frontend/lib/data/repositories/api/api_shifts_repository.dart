// ApiShiftsRepository — #56 fe.3, the API-backed ShiftsRepository.
//
// Talks to `POST /api/v1/shifts/open|close|current/entries`
// (`server/src/shifts/shifts.controller.ts`) and patches the local Drift
// `Shifts`/`DrawerEntries` rows from the response. Per ADR-0010 §3 this class
// NEVER calls `ShiftsRepository.openShift/addDrawerEntry/closeShift` on the
// injected [drift] instance and NEVER wraps a network call in `db.transaction`
// — those are the Drift transactional services, and calling one after the
// server has already committed the write is exactly the double-write
// `api_repository_contract_test.dart` exists to catch. All arithmetic
// (pointsGranted-equivalents here: none — shifts carry no derived numbers)
// and every id/timestamp comes off the response; nothing is computed locally.
//
// Reads (`getCashDrawer`/`getShiftHistory`) are #55's slice (server does not
// yet expose a client-facing `GET /shifts/current`/`GET /shifts/history` read
// path this repository is allowed to call — and the brief is explicit: do
// NOT call `GET /shifts/current` from here). They delegate to the injected
// Drift repo unchanged.

import 'package:drift/drift.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../domain/models/aggregates.dart';
import '../../db/database.dart';
import '../shifts_repository.dart';
import 'api_wire.dart';

class ApiShiftsRepository implements ShiftsRepository {
  ApiShiftsRepository({
    required this.api,
    required this.db,
    required this.drift,
  });

  final ApiClient api;

  /// Required by the implicit `ShiftsRepository` interface (its `db` field is
  /// final, so implementing the class means implementing this getter too).
  /// Used here ONLY for plain row `select`/`insert`/`update` patches — never
  /// `db.transaction`.
  @override
  final AppDatabase db;

  /// The Drift implementation, kept around for the reads this slice does not
  /// own (see file header) and for nothing else.
  final ShiftsRepository drift;

  /// The `Idempotency-Key` of a drawer write that never got a verdict.
  ///
  /// 🔴 `addDrawerEntry` is the one that costs money: none of these endpoints
  /// takes a client-generated id, so on a lost reply a second press writes a
  /// SECOND `drawer_entries` row and the closing count is out by that amount,
  /// with nothing on either side to notice. `open`/`close` are parked under the
  /// same rule for the same reason — a verdict closes the attempt, a 5xx does
  /// not.
  final PendingWrites _pending = PendingWrites('sh');

  // ── Reads — #55's slice, delegated unchanged. ──────────────────────────

  @override
  Future<ShiftWithEntries?> getCashDrawer() => drift.getCashDrawer();

  @override
  Future<List<ShiftWithEntries>> getShiftHistory() => drift.getShiftHistory();

  // ── Writes — hit the server, then patch Drift from the response. ──────

  /// `POST /shifts/open`. The server decides whether this is a same-day
  /// re-open (returns the existing shift unchanged) or a new day (archives
  /// the prior shift first) — this repository never re-derives that, it only
  /// writes down whatever `ShiftWithEntries` comes back.
  @override
  Future<ShiftRow> openShift(double startingCash) {
    return rethrowThai(() async {
      final attempt = _pending.of('open|${wireMoney(startingCash)}');
      final response = await _send(
        attempt,
        '/api/v1/shifts/open',
        {'startingCash': wireMoney(startingCash)},
      );
      final row = await _patchShiftWithEntries(response);
      _pending.close(attempt);
      return row;
    });
  }

  /// `POST /shifts/close`. Stamps `closedAt` + `physicalCash` from the
  /// response; the shift stays `isActive` (it is still the current drawer
  /// until the next `openShift` archives it — same rule as the Drift repo,
  /// just enforced server-side now).
  @override
  Future<ShiftRow?> closeShift(double physicalCash) {
    return rethrowThai(() async {
      final attempt = _pending.of('close|${wireMoney(physicalCash)}');
      final response = await _send(
        attempt,
        '/api/v1/shifts/close',
        {'physicalCash': wireMoney(physicalCash)},
      );
      final row = await _patchShiftWithEntries(response);
      _pending.close(attempt);
      return row;
    });
  }

  /// `POST /shifts/current/entries`. Returns a bare `DrawerEntry` — see the
  /// FK-trap comment below for why this is the trickiest method in the file.
  @override
  Future<DrawerEntryRow> addDrawerEntry(
    String type,
    double amount,
    String? note,
  ) {
    return rethrowThai(() async {
      final attempt = _pending.of(
        'entry|$type|${wireMoney(amount)}|${note ?? ''}',
      );
      final response = await _send(attempt, '/api/v1/shifts/current/entries', {
        'type': type,
        'amount': wireMoney(amount),
        'note': note,
      });

      final row = DrawerEntryRow(
        id: response['id'] as String,
        shiftId: response['shiftId'] as String,
        type: response['type'] as String,
        amount: money(response['amount']),
        note: (response['note'] as String?) ?? '',
        createdAt: stamp(response['createdAt']),
      );

      // 🔴 FK trap: `DrawerEntries.shiftId` is a real `references(Shifts, #id)`
      // (tables.dart:292), but the server only ever answers this endpoint with
      // a bare `DrawerEntry` — it does not resend the parent `Shift`. On the
      // common path `row.shiftId` is this device's own currently-open shift,
      // which this cache already has (it was patched by the `openShift` call
      // that opened it), so the FK holds and the insert below succeeds.
      //
      // The trap is the uncommon path the brief calls out: a machine whose
      // local `Shifts` row for that shift is missing (reinstalled app, a
      // shift opened on another device, or simply a cache that predates this
      // slice). Two ways to fail badly here were considered and rejected:
      //   1. Insert blindly and let the Drift/sqlite FK violation propagate.
      //      The money is ALREADY recorded server-side at that point, so the
      //      cashier would see a raw database error for a write that in fact
      //      succeeded — worse than doing nothing, because it invites a
      //      confused retry (and a duplicate `POST`, or a duplicate concern
      //      about non-cash reconciliation).
      //   2. Fabricate a placeholder `Shifts` row from the bare `shiftId` so
      //      the FK is satisfied. This is the "invent a value for a field the
      //      response never sent" move ADR-0010 §3 explicitly bans — this
      //      response carries no `dateStr`/`startingCash`/`openedAt` for that
      //      shift, and guessing them would corrupt exactly the row #55's
      //      reads are supposed to fill in correctly later.
      //
      // What this does instead: check whether the parent is already cached,
      // and only persist the entry when it is. When it is not, still RETURN
      // the authoritative row built from the server's response (never
      // swallowed into nothing — a caller that inspects the return value
      // sees the real entry) but skip the local write, so the local DB is
      // never left half-consistent (no orphan FK row, no guessed parent).
      // The entry is not lost: it lives on the server, and the next time
      // this shift is read through #55's sync it will bring the entry with
      // it. `cash_drawer_screen.dart` today discards the return value and
      // re-reads via `getCashDrawer()` (delegated to Drift), so on this rare
      // path the drawer view is stale by one entry until that shift is
      // synced — not corrupted, not lost.
      final parentShift =
          await (db.select(
            db.shifts,
          )..where((t) => t.id.equals(row.shiftId))).getSingleOrNull();
      if (parentShift != null) {
        await db.into(db.drawerEntries).insertOnConflictUpdate(row);
      }
      _pending.close(attempt);
      return row;
    });
  }

  /// `POST`s [body] under [attempt]'s `Idempotency-Key`, keeping the attempt
  /// parked unless the server gives a verdict ([isVerdict]).
  Future<Map<String, dynamic>> _send(
    PendingWrite attempt,
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      return await api.post(path, body: body, headers: attempt.headers)
          as Map<String, dynamic>;
    } on ApiException catch (e) {
      _pending.closeIfVerdict(attempt, e);
      rethrow;
    }
  }

  // ── Patch helpers ───────────────────────────────────────────────────────

  /// Upserts the `Shifts` row from a `ShiftWithEntries` response, then its
  /// `entries` (the parent is always written first, so the entries' FK to it
  /// is always satisfied — unlike the bare-`DrawerEntry` case above).
  Future<ShiftRow> _patchShiftWithEntries(Map<String, dynamic> json) async {
    final shift = await _patchShift(json);
    final entries = (json['entries'] as List<dynamic>?) ?? const [];
    for (final e in entries) {
      final entry = e as Map<String, dynamic>;
      await db.into(db.drawerEntries).insertOnConflictUpdate(
        DrawerEntryRow(
          id: entry['id'] as String,
          shiftId: entry['shiftId'] as String,
          type: entry['type'] as String,
          amount: money(entry['amount']),
          note: (entry['note'] as String?) ?? '',
          createdAt: stamp(entry['createdAt']),
        ),
      );
    }
    return shift;
  }

  Future<ShiftRow> _patchShift(Map<String, dynamic> json) async {
    final row = ShiftRow(
      id: json['id'] as String,
      dateStr: json['dateStr'] as String,
      startingCash: money(json['startingCash']),
      openedAt: stamp(json['openedAt']),
      closedAt: stampOrNull(json['closedAt']),
      physicalCash: moneyOrNull(json['physicalCash']),
      isActive: json['isActive'] as bool,
      autoArchived: json['autoArchived'] as bool,
      archivedAt: stampOrNull(json['archivedAt']),
    );
    await db.into(db.shifts).insertOnConflictUpdate(row);

    // Plain patch, not a re-derivation: the server just told us `row.id` is
    // now THE active shift for this device. `ShiftsRepository.getCashDrawer`
    // (which reads still delegate to) picks `isActive == true` ordered by
    // `openedAt DESC LIMIT 1`, so a stale local row still marked active from
    // before this cache existed, or from a day the app was offline, would
    // not break that query — but clearing it keeps the local table matching
    // "exactly one active shift" the way the Drift-only build always kept it,
    // rather than silently accumulating rows that claim to be active. This is
    // a `WHERE isActive` update on a fact the response already asserted, not
    // a call to `ShiftsRepository.openShift`'s archiving logic.
    if (row.isActive) {
      await (db.update(db.shifts)..where(
            (t) => t.isActive.equals(true) & t.id.equals(row.id).not(),
          ))
          .write(const ShiftsCompanion(isActive: Value(false)));
    }
    return row;
  }
}
