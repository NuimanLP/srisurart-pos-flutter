// CustomersRepository — customers + loyalty (sa_customers).
//
// db.js methods ported (lines 174-189):
//  • getCustomers()            → all customers (seeded in AppDatabase.onCreate).
//  • addCustomer(c)            → code = 'CUS' + zero-padded(max+1, width 3);
//    id newId('c'); points/totalSpend = 0; createdAt = today (ISO yyyy-MM-dd).
//    Returns the new CustomerRow.
//  • updateCustomer(id, patch) → merge patch.
//  • deleteCustomer(id)        → remove.
//
// db.js addCustomer:
//   const maxNum = all.reduce((max, x) => {
//     const n = parseInt((x.code||'').replace('CUS',''),10);
//     return isNaN(n)?max:Math.max(max,n); }, 0);
//   const code = 'CUS' + String(maxNum + 1).padStart(3, '0');
//   const newC = { ...c, id:_newId('c'), code, points:0, totalSpend:0,
//                  createdAt: new Date().toISOString().slice(0,10) };

import 'package:drift/drift.dart';

import '../../core/utils/dates.dart';
import '../../core/utils/ids.dart';
import '../db/database.dart';

class CustomersRepository {
  final AppDatabase db;
  CustomersRepository(this.db);

  Future<List<CustomerRow>> getCustomers() => db.select(db.customers).get();

  /// Auto-assigns code (CUS###) and id; zero-inits points/totalSpend; returns
  /// the new customer. The caller supplies name/nameTH/phone/address via the
  /// companion — id, code, points, totalSpend and createdAt are overwritten here
  /// to mirror db.js (`{ ...c, id, code, points:0, totalSpend:0, createdAt }`).
  Future<CustomerRow> addCustomer(CustomersCompanion data) async {
    final all = await getCustomers();

    // maxNum = highest numeric suffix of any existing CUS code (0 if none parse).
    var maxNum = 0;
    for (final c in all) {
      final digits = c.code.replaceFirst('CUS', '');
      final n = int.tryParse(digits);
      if (n != null && n > maxNum) maxNum = n;
    }
    final code = 'CUS${(maxNum + 1).toString().padLeft(3, '0')}';

    final today = todayKey();
    final id = newId('c');

    final row = data.copyWith(
      id: Value(id),
      code: Value(code),
      points: const Value(0),
      totalSpend: const Value(0),
      createdAt: Value(today),
      updatedAt: Value(DateTime.now()),
    );

    await db.into(db.customers).insert(row);
    return (db.select(db.customers)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> updateCustomer(String id, CustomersCompanion patch) async {
    await (db.update(db.customers)..where((t) => t.id.equals(id)))
        .write(patch.copyWith(updatedAt: Value(DateTime.now())));
  }

  Future<void> deleteCustomer(String id) async {
    await (db.delete(db.customers)..where((t) => t.id.equals(id))).go();
  }
}
