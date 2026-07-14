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
    );
    await db.into(db.mechanics).insert(row);
    return row;
  }

  Future<void> updateMechanic(String id, MechanicsCompanion patch) async {
    await (db.update(db.mechanics)..where((t) => t.id.equals(id))).write(patch);
  }

  Future<void> deleteMechanic(String id) async {
    await (db.delete(db.mechanics)..where((t) => t.id.equals(id))).go();
  }

  /// Records a credit settlement and reduces the mechanic's balance (clamped 0).
  ///
  /// Transactional (mirrors db.js: insert payment + reduce mechanic balance):
  ///   newP = { ...p, id:newId('cp'), receiptNo:docNo('CP'), date:now }
  ///   mech.creditBalance = max(0, (creditBalance||0) - amount)
  Future<CreditPaymentRow> addCreditPayment({
    required String mechanicId,
    required double amount,
    String? note,
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
            .write(MechanicsCompanion(creditBalance: Value(newBalance)));
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
}
