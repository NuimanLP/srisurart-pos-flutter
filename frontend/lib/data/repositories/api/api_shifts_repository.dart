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
//
// Phase 2 (#452, 08 §6.1/§7): `shift.open` and `drawer.entry` are queued ops.
// Both endpoints now take the client's id, minted ONCE per attempt with its
// `Idempotency-Key` ([PendingWrites]). Degraded, or a lost connection with the
// sync engine wired → the local row and its `outbox_ops` row are written in ONE
// local transaction under that same id + key ([_openOffline] / [_entryOffline]),
// and `SyncService` pushes it later. Still never a Drift transactional service.

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_error_resolver.dart';
import '../../../core/network/transport_failure.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/ids.dart';
import '../../../domain/models/aggregates.dart';
import '../../db/database.dart';
import '../../sync/sync_facade.dart';
import '../../sync/sync_service.dart';
import '../mechanics_repository.dart';
import '../shifts_repository.dart';
import 'api_wire.dart';

class ApiShiftsRepository implements ShiftsRepository {
  ApiShiftsRepository({
    required this.api,
    required this.db,
    required this.drift,
    this.mechanics,
    this.syncService,
    this.syncFacade,
  });

  final ApiClient api;

  /// The credit-payment outbox (#24) — flushes it before a close when no
  /// [syncService] is wired. See [closeShift].
  final MechanicsRepository? mechanics;

  final SyncService? syncService;
  final SyncFacade? syncFacade;

  SyncService? get _sync =>
      syncService ??
      (syncFacade is SyncService ? syncFacade as SyncService : null);

  /// Same rule as `ApiSalesRepository._isDegraded` (08 §5): Degraded or
  /// Syncing, or anything already queued → a new write joins the outbox.
  bool get _isDegraded {
    final sync = _sync;
    if (sync != null) {
      return sync.currentStatus == SyncStatus.degraded ||
          sync.currentStatus == SyncStatus.syncing ||
          sync.currentOutboxRemaining > 0;
    }
    if (syncFacade != null) {
      try {
        final dynamic facade = syncFacade;
        final status = facade.currentStatus;
        if (status == SyncStatus.degraded || status == SyncStatus.syncing) {
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

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
  /// 🔴 `addDrawerEntry` is the one that costs money: on a lost reply a second
  /// press with a fresh id + key writes a SECOND `drawer_entries` row and the
  /// closing count is out by that amount. `open`/`close` are parked under the
  /// same rule for the same reason — a verdict closes the attempt, a 5xx does
  /// not. The attempt's id is the shift id `POST /shifts/open` records.
  final PendingWrites _pending = PendingWrites('sh');

  /// Same as [_pending], for drawer entries — its id is the entry's id.
  final PendingWrites _pendingEntries = PendingWrites('de');

  // ── Reads — #55's slice, delegated unchanged. ──────────────────────────

  @override
  Future<ShiftWithEntries?> getCashDrawer() => drift.getCashDrawer();

  @override
  Future<List<ShiftWithEntries>> getShiftHistory() => drift.getShiftHistory();

  // ── Writes — hit the server, then patch Drift from the response. ──────

  /// `POST /shifts/open` with body `{ id, startingCash }` (08 §11). The server
  /// decides: an existing `id` returns that shift unchanged, otherwise any
  /// active shift is archived and a new one opened — this repository never
  /// re-derives that online, it only writes down the `ShiftWithEntries` that
  /// comes back. Offline it is queued as `shift.open` ([_openOffline]).
  @override
  Future<ShiftRow> openShift(double startingCash, {String? id}) {
    return rethrowThai(() async {
      final attempt = _pending.of(
        'open|${id ?? ''}|${wireMoney(startingCash)}',
      );
      final shiftId = id ?? attempt.id;
      final response = _isDegraded
          ? null
          : await _sendOrQueue(_pending, attempt, '/api/v1/shifts/open', {
              'id': shiftId,
              'startingCash': wireMoney(startingCash),
            });
      final row = response == null
          ? await _openOffline(
              shiftId,
              attempt.headers['Idempotency-Key']!,
              startingCash,
            )
          : await _patchShiftWithEntries(response);
      _pending.close(attempt);
      return row;
    });
  }

  /// `POST /shifts/close`. Stamps `closedAt` + `physicalCash` from the
  /// response; the shift stays `isActive` (it is still the current drawer
  /// until the next `openShift` archives it — same rule as the Drift repo,
  /// just enforced server-side now).
  ///
  /// 🔴 Refused while ANY op is left in `outbox_ops` — `pending`, `stuck` or
  /// `rejected`, of any type (08 §11: the server cannot see the outbox, so the
  /// client enforces it). The server stamps a queued write onto whichever
  /// shift is active when it ARRIVES, so one sent after this close lands in
  /// the next shift and tonight's count is wrong. So the outbox is sent first,
  /// and the close goes out only if it is empty. (This replaces the owner's
  /// 2026-09-13 rule that counted only queued cash credit payments.)
  @override
  Future<ShiftRow?> closeShift(double physicalCash) {
    return rethrowThai(() async {
      // Legacy #24 rows count too — move them into the outbox first.
      await migratePendingCreditPayments(db);
      final sync = _sync;
      if (sync != null) {
        await sync.push();
      } else {
        await mechanics?.flushPendingCreditPayments();
      }
      final unsent = (await db.select(db.outboxOps).get()).length;
      if (unsent > 0) {
        // agent ร่าง, awaiting the owner — catalogued in 02_API_SCREENS §8.1.1.
        throw PosException(
          'OUTBOX_NOT_EMPTY',
          'ยังมี $unsent รายการติดปัญหา / ค้างส่ง '
              '— ต้องส่งเข้าระบบให้หมดก่อนปิดกะ',
        );
      }
      final attempt = _pending.of('close|${wireMoney(physicalCash)}');
      final response = await _send(_pending, attempt, '/api/v1/shifts/close', {
        'physicalCash': wireMoney(physicalCash),
      });
      final row = await _patchShiftWithEntries(response);
      _pending.close(attempt);
      return row;
    });
  }

  /// `POST /shifts/current/entries` with the client's entry id. Returns a bare
  /// `DrawerEntry` — see the FK-trap comment below for why this is the
  /// trickiest method in the file. Offline it is queued as `drawer.entry`
  /// ([_entryOffline]).
  @override
  Future<DrawerEntryRow> addDrawerEntry(
    String type,
    double amount,
    String? note,
  ) {
    return rethrowThai(() async {
      final attempt = _pendingEntries.of(
        'entry|$type|${wireMoney(amount)}|${note ?? ''}',
      );
      final response = _isDegraded
          ? null
          : await _sendOrQueue(
              _pendingEntries,
              attempt,
              '/api/v1/shifts/current/entries',
              {
                'id': attempt.id,
                'type': type,
                'amount': wireMoney(amount),
                'note': note,
              },
            );
      if (response == null) {
        final queued = await _entryOffline(attempt, type, amount, note);
        _pendingEntries.close(attempt);
        return queued;
      }

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
      final parentShift = await (db.select(
        db.shifts,
      )..where((t) => t.id.equals(row.shiftId))).getSingleOrNull();
      if (parentShift != null) {
        await db.into(db.drawerEntries).insertOnConflictUpdate(row);
      }
      _pendingEntries.close(attempt);
      return row;
    });
  }

  /// `POST`s [body] under [attempt]'s `Idempotency-Key`, keeping the attempt
  /// parked in [pending] unless the server gives a verdict ([isVerdict]).
  Future<Map<String, dynamic>> _send(
    PendingWrites pending,
    PendingWrite attempt,
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      return await api.post(path, body: body, headers: attempt.headers)
          as Map<String, dynamic>;
    } on ApiException catch (e) {
      pending.closeIfVerdict(attempt, e);
      rethrow;
    }
  }

  /// [_send], except that a TRANSPORT failure (timeout, dropped socket) with
  /// the sync engine wired returns null: the caller then queues the write under
  /// the SAME id + key (08 §5), and the push replays it if the lost request had
  /// in fact committed. Everything else is rethrown exactly as before — an
  /// `ApiException` (a 4xx verdict, or a 5xx that keeps the attempt parked, as
  /// on the sale path), or a reply that arrived but was not readable (#409).
  Future<Map<String, dynamic>?> _sendOrQueue(
    PendingWrites pending,
    PendingWrite attempt,
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      return await _send(pending, attempt, path, body);
    } catch (e) {
      final sync = _sync;
      if (e is ApiException || sync == null || !isTransportFailure(e)) rethrow;
      sync.recordNonVerdictWrite();
      return null;
    }
  }

  // ── Offline writes (08 §6.1/§7) ─────────────────────────────────────────

  /// Queues `shift.open`: archives the local active shift (same rule as the
  /// Drift repo and the server — never counted → `autoArchived`), inserts the
  /// new shift under the client [id], and inserts the outbox op, all in ONE
  /// local transaction so the shift and its op exist together or not at all.
  /// An [id] already cached is returned unchanged with nothing queued (08 §11).
  Future<ShiftRow> _openOffline(
    String id,
    String idempotencyKey,
    double startingCash,
  ) async {
    final now = DateTime.now();
    final opened = ShiftRow(
      id: id,
      dateStr: todayKey(),
      startingCash: startingCash,
      openedAt: now,
      closedAt: null,
      physicalCash: null,
      isActive: true,
      autoArchived: false,
      archivedAt: null,
    );
    final row = await db.transaction(() async {
      final existingById = await (db.select(
        db.shifts,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (existingById != null) return existingById;

      final prior = await (db.select(
        db.shifts,
      )..where((t) => t.isActive.equals(true))).get();
      for (final p in prior) {
        final autoArchive = p.closedAt == null;
        await (db.update(db.shifts)..where((t) => t.id.equals(p.id))).write(
          ShiftsCompanion(
            isActive: const Value(false),
            autoArchived: autoArchive
                ? const Value(true)
                : Value(p.autoArchived),
            archivedAt: autoArchive ? Value(now) : Value(p.archivedAt),
          ),
        );
      }

      await db.into(db.shifts).insert(opened);
      await _enqueue(
        idempotencyKey: idempotencyKey,
        type: 'shift.open',
        // = the online body + `openedAt`, which only the push op carries
        // (08 §6.4, owner 2026-09-25).
        payload: {
          'id': id,
          'startingCash': wireMoney(startingCash),
          'openedAt': now.toUtc().toIso8601String(),
        },
        aggregates: ['shift:$id'],
        createdAt: now,
      );
      return opened;
    });
    await _afterQueue();
    return row;
  }

  /// Queues `drawer.entry` on the local open shift: the entry row and its
  /// outbox op in ONE local transaction. Refused, with nothing written, when
  /// this device's cache holds no open drawer — the server's own answers.
  Future<DrawerEntryRow> _entryOffline(
    PendingWrite attempt,
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
    if (shift == null) {
      throw PosException(
        'NO_OPEN_SHIFT',
        ServerErrorResolver.resolve('NO_OPEN_SHIFT'),
      );
    }
    if (shift.closedAt != null) {
      throw PosException(
        'DRAWER_CLOSED',
        ServerErrorResolver.resolve('DRAWER_CLOSED'),
      );
    }

    final now = DateTime.now();
    final row = DrawerEntryRow(
      id: attempt.id,
      shiftId: shift.id,
      type: type,
      amount: amount,
      note: note ?? '',
      createdAt: now,
    );
    await db.transaction(() async {
      await db.into(db.drawerEntries).insert(row);
      await _enqueue(
        idempotencyKey: attempt.headers['Idempotency-Key']!,
        type: 'drawer.entry',
        payload: {
          'id': attempt.id,
          'type': type,
          'amount': wireMoney(amount),
          'note': note,
          'createdAt': now.toUtc().toIso8601String(),
        },
        aggregates: ['drawer:${attempt.id}', 'shift:${shift.id}'],
        createdAt: now,
      );
    });
    await _afterQueue();
    return row;
  }

  /// One `outbox_ops` row. Called only inside the caller's transaction.
  Future<void> _enqueue({
    required String idempotencyKey,
    required String type,
    required Map<String, dynamic> payload,
    required List<String> aggregates,
    required DateTime createdAt,
  }) {
    return db
        .into(db.outboxOps)
        .insert(
          OutboxOpsCompanion.insert(
            opId: newId('op'),
            idempotencyKey: idempotencyKey,
            type: type,
            payload: jsonEncode(payload),
            aggregates: jsonEncode(aggregates),
            createdAt: createdAt.toUtc(),
            status: 'pending',
          ),
        );
  }

  /// Same as the sale path: refresh the outbox count, and push unless Degraded.
  Future<void> _afterQueue() async {
    final sync = _sync;
    if (sync == null) return;
    await sync.refreshOutbox();
    if (sync.currentStatus != SyncStatus.degraded) unawaited(sync.push());
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
