// MechanicsRepository — mechanics + credit payments (sa_mechanics / sa_credit_payments).
//
// Implementation owned by the **Mechanics service agent**.
//
// db.js methods ported (db.js lines 517-544):
//  • getMechanics()            → all mechanics.
//  • addMechanic(m)            → code = 'M' + zero-padded(max+1); id newId('m');
//    creditBalance/totalSales/totalCredit/totalMarkup/totalDiscount = 0;
//    creditLimit from input; createdAt = today (yyyy-MM-dd). Returns the new MechanicRow.
//  • updateMechanic(id, data)  → merge patch.
//  • deleteMechanic(id)        → remove.
//  • addCreditPayment(p)       → id newId('cp'), receiptNo docNo('CP'), date now;
//    then reduce that mechanic's creditBalance by amount (clamped at 0).
//    Returns the new CreditPaymentRow. (Transactional.)
//  • getCreditPayments()       → all credit payments newest-first.

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/utils/ids.dart';
import '../db/database.dart';

class MechanicsRepository {
  final AppDatabase db;
  MechanicsRepository(this.db);

  Future<List<MechanicRow>> getMechanics() => db.select(db.mechanics).get();

  /// Auto-assigns code (M###) and id; returns the new mechanic.
  ///
  /// Mirrors db.js addMechanic:
  ///   maxNum = reduce over all codes (parseInt of code with 'M' stripped, NaN→ignored)
  ///   code   = 'M' + (maxNum + 1) padded to 3 digits
  ///   id     = newId('m'); createdAt = today (yyyy-MM-dd)
  ///   creditLimit kept from input; balance/sales/credit/markup/discount forced to 0.
  Future<MechanicRow> addMechanic(MechanicsCompanion data) async {
    final all = await getMechanics();
    var maxNum = 0;
    for (final m in all) {
      final digits = m.code.replaceAll('M', '');
      final n = int.tryParse(digits);
      if (n != null && n > maxNum) maxNum = n;
    }
    final code = 'M${(maxNum + 1).toString().padLeft(3, '0')}';
    final now = DateTime.now();
    final createdAt =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final row = MechanicRow(
      id: newId('m'),
      code: code,
      name: data.name.present ? data.name.value : '',
      nameTH: data.nameTH.present ? data.nameTH.value : null,
      nickname: data.nickname.present ? data.nickname.value : null,
      shopName: data.shopName.present ? data.shopName.value : null,
      phone: data.phone.present ? data.phone.value : null,
      note: data.note.present ? data.note.value : null,
      creditLimit: data.creditLimit.present ? data.creditLimit.value : 0,
      creditBalance: 0,
      totalSales: 0,
      totalCredit: 0,
      totalDiscount: 0,
      totalMarkup: 0,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
    await db.into(db.mechanics).insert(row);
    return row;
  }

  Future<void> updateMechanic(String id, MechanicsCompanion patch) async {
    await (db.update(db.mechanics)..where((t) => t.id.equals(id)))
        .write(patch.copyWith(updatedAt: Value(DateTime.now())));
  }

  Future<void> deleteMechanic(String id) async {
    await (db.delete(db.mechanics)..where((t) => t.id.equals(id))).go();
  }

  /// Records a credit settlement and reduces the mechanic's balance (clamped 0).
  ///
  /// Transactional (mirrors db.js: insert payment + reduce mechanic balance):
  ///   newP = { ...p, id:newId('cp'), receiptNo:docNo('CP'), date:now }
  ///   mech.creditBalance = max(0, (creditBalance||0) - amount)
  ///
  /// [paymentMethod] and [allowOverpayment] exist for `POST
  /// /mechanics/:id/credit-payments` (#24), which needs both on the wire. The
  /// Drift table has no method column, so this local path does not store them —
  /// the screen still folds the method into [note] for the history line — and a
  /// local write has no server to refuse an overpayment, so the flag is moot here.
  Future<CreditPaymentRow> addCreditPayment({
    required String mechanicId,
    required double amount,
    String? note,
    required String paymentMethod,
    bool allowOverpayment = false,
  }) async {
    return db.transaction(() async {
      final row = CreditPaymentRow(
        id: newId('cp'),
        receiptNo: docNo('CP'),
        mechanicId: mechanicId,
        amount: amount,
        date: DateTime.now(),
        note: note,
      );
      await db.into(db.creditPayments).insert(row);

      // Reduce mechanic balance (only if the mechanic exists), clamped at 0.
      final mech = await (db.select(
        db.mechanics,
      )..where((t) => t.id.equals(mechanicId))).getSingleOrNull();
      if (mech != null) {
        var newBalance = mech.creditBalance - amount;
        if (newBalance < 0) newBalance = 0;
        await (db.update(db.mechanics)..where((t) => t.id.equals(mechanicId)))
            .write(
              MechanicsCompanion(
                creditBalance: Value(newBalance),
                updatedAt: Value(DateTime.now()),
              ),
            );
      }

      return row;
    });
  }

  /// All credit payments, newest first.
  ///
  /// db.js prepends each new payment, so newest-first there is insertion order.
  /// Drift stores DateTime as unix epoch *seconds*, so two payments in the same
  /// second tie on `date`; we break the tie by SQLite's implicit `rowid` (which
  /// increases monotonically with insertion order) so newest stays first.
  Future<List<CreditPaymentRow>> getCreditPayments() async {
    final rows = await db
        .customSelect(
          'SELECT * FROM credit_payments ORDER BY date DESC, rowid DESC',
          readsFrom: {db.creditPayments},
        )
        .get();
    return rows.map((r) => db.creditPayments.map(r.data)).toList();
  }

  // ── Credit-payment outbox (#24 / #275) ──────────────────────────────────────
  // Phase 2 (Slice 9, Ticket #275): Credit payment outbox ops live in `outbox_ops`
  // with type 'credit_payment.create'. Legacy rows in `pending_credit_payments`
  // are migrated automatically so no rows are lost.

  /// Payments taken at the counter that the server has not confirmed, oldest
  /// first — both the ones still to send and the ones it refused.
  Future<List<PendingCreditPaymentRow>> getPendingCreditPayments() async {
    await migratePendingCreditPayments(db);
    final ops = await (db.select(db.outboxOps)
          ..where((t) => t.type.equals('credit_payment.create'))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    return ops.map(outboxOpToPendingCreditPayment).toList();
  }

  /// Sends whatever is still queued. Nothing to send without a server.
  Future<void> flushPendingCreditPayments() async {}

  /// Drops a payment the server REFUSED. A row still queued is never dropped:
  /// it may already be committed with only the reply lost.
  Future<void> discardRejectedCreditPayment(String id) async {
    await migratePendingCreditPayments(db);
    final ops = await (db.select(db.outboxOps)
          ..where((t) =>
              t.type.equals('credit_payment.create') &
              t.status.equals('rejected')))
        .get();
    for (final op in ops) {
      final row = outboxOpToPendingCreditPayment(op);
      if (op.opId == id || row.id == id) {
        await (db.delete(db.outboxOps)..where((t) => t.opId.equals(op.opId)))
            .go();
      }
    }
  }

  /// A person confirmed a refused overpayment: queue it again with the flag and
  /// send. The id stays — the server never stored the refused attempt, and the id
  /// is its replay check — but the `Idempotency-Key` is new, because the body
  /// changed and a key may not be reused for a different body.
  Future<void> resendRejectedAllowingOverpayment(String id) async {
    await migratePendingCreditPayments(db);
    final ops = await (db.select(db.outboxOps)
          ..where((t) =>
              t.type.equals('credit_payment.create') &
              t.status.equals('rejected')))
        .get();
    for (final op in ops) {
      final row = outboxOpToPendingCreditPayment(op);
      if (op.opId == id || row.id == id) {
        Map<String, dynamic> payload = {};
        try {
          final decoded = jsonDecode(op.payload);
          if (decoded is Map<String, dynamic>) {
            payload = Map<String, dynamic>.from(decoded);
          }
        } catch (_) {}
        payload['allowOverpayment'] = true;

        await (db.update(db.outboxOps)
              ..where((t) => t.opId.equals(op.opId)))
            .write(
          OutboxOpsCompanion(
            idempotencyKey: Value(newId('idem')),
            payload: Value(jsonEncode(payload)),
            status: const Value('pending'),
            attempts: const Value(0),
            lastCode: const Value(null),
            lastMessage: const Value(null),
            lastDetails: const Value(null),
          ),
        );
      }
    }
    await flushPendingCreditPayments();
  }
}

/// Converts an [OutboxOpRow] with type `credit_payment.create` into a
/// [PendingCreditPaymentRow] consumed by the presentation layer and shift guards.
PendingCreditPaymentRow outboxOpToPendingCreditPayment(OutboxOpRow op) {
  Map<String, dynamic> payload = {};
  try {
    final decoded = jsonDecode(op.payload);
    if (decoded is Map<String, dynamic>) {
      payload = decoded;
    }
  } catch (_) {}

  return PendingCreditPaymentRow(
    id: (payload['id'] ?? op.opId) as String,
    idempotencyKey: op.idempotencyKey,
    mechanicId: (payload['mechanicId'] ?? '') as String,
    amount: (payload['amount'] ?? '0.00').toString(),
    paymentMethod: (payload['paymentMethod'] ?? 'เงินสด').toString(),
    note: payload['note'] as String?,
    allowOverpayment: payload['allowOverpayment'] == true,
    createdAt: op.createdAt,
    rejectedCode: op.status == 'rejected' ? (op.lastCode ?? 'REJECTED') : null,
    rejectedMessage: op.status == 'rejected' ? op.lastMessage : null,
  );
}

/// Migrates any legacy rows in `pending_credit_payments` (#24) into `outbox_ops`
/// (Phase 2, Ticket #275). Runs atomically so no rows are lost during migration.
Future<void> migratePendingCreditPayments(AppDatabase db) async {
  final legacyRows = await (db.select(db.pendingCreditPayments)).get();
  if (legacyRows.isEmpty) return;

  await db.transaction(() async {
    for (final row in legacyRows) {
      final localId = row.id;
      final payload = {
        'id': localId,
        'mechanicId': row.mechanicId,
        'amount': row.amount,
        'paymentMethod': row.paymentMethod,
        if (row.note != null && row.note!.isNotEmpty) 'note': row.note,
        if (row.allowOverpayment) 'allowOverpayment': true,
        'date': row.createdAt.toUtc().toIso8601String(),
      };
      final aggregates = [
        'cp:$localId',
        'shift',
        'mechanic:${row.mechanicId}',
      ];
      final opId = newId('op');
      await db.into(db.outboxOps).insert(
            OutboxOpsCompanion(
              opId: Value(opId),
              idempotencyKey: Value(row.idempotencyKey),
              type: const Value('credit_payment.create'),
              payload: Value(jsonEncode(payload)),
              aggregates: Value(jsonEncode(aggregates)),
              createdAt: Value(row.createdAt),
              status: Value(row.rejectedCode != null ? 'rejected' : 'pending'),
              attempts: const Value(0),
              lastCode: Value(row.rejectedCode),
              lastMessage: Value(row.rejectedMessage),
            ),
          );
      await (db.delete(db.pendingCreditPayments)
            ..where((t) => t.id.equals(row.id)))
          .go();
    }
  });
}

/// Thrown by `addCreditPayment` when the payment was saved on this device but
/// the server has not confirmed it yet.
///
/// 🔴 Not a failure: the cash is taken and the payment WILL be sent. The screen
/// must close the dialog and say so, because a cashier who reads "failed" presses
/// again — and that second press is a second payment.
class CreditPaymentQueued implements Exception {
  const CreditPaymentQueued();

  @override
  String toString() =>
      'บันทึกการรับชำระไว้ในเครื่องแล้ว — ยังส่งเข้าระบบไม่ได้ จะส่งให้อัตโนมัติ '
      '(ยอดค้างจะลดเมื่อส่งสำเร็จ) ไม่ต้องกดรับชำระซ้ำ';
}
