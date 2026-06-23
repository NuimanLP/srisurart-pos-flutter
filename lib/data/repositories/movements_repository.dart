// MovementsRepository — stock movement log (sa_movements in db.js).
//
// db.js methods ported:
//   getMovements() → all movements, newest first (db.js prepends new entries).
//   addMovement(m) → inserts { ...m, id:_newId('mv'), date:now } and returns it.
//
// FULLY IMPLEMENTED (low-risk, other agents depend on it).

import 'package:drift/drift.dart';

import '../../core/utils/ids.dart';
import '../db/database.dart';

class MovementsRepository {
  final AppDatabase db;
  MovementsRepository(this.db);

  /// All movements, newest first (db.js stores them prepended → order by date desc).
  Future<List<MovementRow>> getMovements() {
    return (db.select(db.movements)
          ..orderBy([(t) => OrderingTerm.desc(t.date)]))
        .get();
  }

  /// Insert a movement and return the stored row.
  /// Mirrors db.js addMovement: assigns id via newId('mv') and date = now.
  Future<MovementRow> addMovement({
    required String productId,
    required String partNo,
    required String name,
    required int delta,
    required String type,
    String? note,
    required int stockAfter,
  }) async {
    final row = MovementRow(
      id: newId('mv'),
      productId: productId,
      partNo: partNo,
      name: name,
      delta: delta,
      type: type,
      note: note,
      stockAfter: stockAfter,
      date: DateTime.now(),
    );
    await db.into(db.movements).insert(row);
    return row;
  }
}
