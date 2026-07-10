// Unit tests for MovementsRepository.
//
// Invariants under test (db.js sa_movements parity):
//  • addMovement assigns id via newId('mv'), stamps date = now, stores the
//    row verbatim and returns it.
//  • getMovements returns newest-first (db.js prepends → date desc).

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/movements_repository.dart';

void main() {
  late AppDatabase db;
  late MovementsRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = MovementsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('addMovement assigns mv-prefixed id, stamps now, stores verbatim',
      () async {
    final before = DateTime.now();
    final row = await repo.addMovement(
      productId: 'p1',
      partNo: 'BP-001',
      name: 'Brake Pad',
      delta: -3,
      type: 'sale',
      note: 'ขายหน้าร้าน',
      stockAfter: 7,
    );
    final after = DateTime.now();

    expect(row.id, startsWith('mv'));
    expect(
      row.date.isBefore(before.subtract(const Duration(seconds: 1))),
      isFalse,
    );
    expect(row.date.isAfter(after.add(const Duration(seconds: 1))), isFalse);

    final stored = await repo.getMovements();
    expect(stored, hasLength(1));
    final s = stored.single;
    expect(s.productId, 'p1');
    expect(s.partNo, 'BP-001');
    expect(s.name, 'Brake Pad');
    expect(s.delta, -3);
    expect(s.type, 'sale');
    expect(s.note, 'ขายหน้าร้าน');
    expect(s.stockAfter, 7);
  });

  test('addMovement allows a null note', () async {
    final row = await repo.addMovement(
      productId: 'p2',
      partNo: 'SP-100',
      name: 'Spark Plug',
      delta: 10,
      type: 'receive',
      stockAfter: 25,
    );
    expect(row.note, isNull);
    expect((await repo.getMovements()).single.note, isNull);
  });

  test('getMovements returns newest-first by date', () async {
    // Insert directly so the two rows get distinct, controlled dates.
    final old = MovementRow(
      id: 'mv_old',
      productId: 'p1',
      partNo: 'BP-001',
      name: 'Brake Pad',
      delta: 5,
      type: 'receive',
      note: null,
      stockAfter: 5,
      date: DateTime(2026, 1, 1, 9, 0),
    );
    final recent = old.copyWith(
      id: 'mv_new',
      date: DateTime(2026, 6, 1, 9, 0),
    );
    await db.into(db.movements).insert(old);
    await db.into(db.movements).insert(recent);

    final all = await repo.getMovements();
    expect(all.map((m) => m.id).toList(), ['mv_new', 'mv_old']);
  });
}
