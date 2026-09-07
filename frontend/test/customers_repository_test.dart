import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/customers_repository.dart';

void main() {
  late AppDatabase db;
  late CustomersRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = CustomersRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> clearCustomers() async {
    await db.delete(db.customers).go();
  }

  test(
    'addCustomer auto-increments CUS code from CUS001 on an empty table',
    () async {
      await clearCustomers();
      final c = await repo.addCustomer(
        const CustomersCompanion(
          name: Value('Walk-in'),
          nameTH: Value('ลูกค้า'),
        ),
      );
      expect(c.code, 'CUS001');
    },
  );

  test(
    'addCustomer zero-inits points and totalSpend and sets createdAt/id',
    () async {
      await clearCustomers();
      final c = await repo.addCustomer(
        const CustomersCompanion(name: Value('A'), nameTH: Value('เอ')),
      );
      expect(c.points, 0);
      expect(c.totalSpend, 0);
      expect(c.id.startsWith('c'), isTrue);
      // createdAt is ISO yyyy-MM-dd (10 chars).
      expect(c.createdAt.length, 10);
      expect(c.createdAt, DateTime.now().toIso8601String().substring(0, 10));
    },
  );

  test(
    'addCustomer auto-increments past the existing max CUS number',
    () async {
      await clearCustomers();
      // Seed two existing customers with non-sequential codes.
      await db
          .into(db.customers)
          .insert(
            CustomersCompanion.insert(
              id: 'x1',
              code: 'CUS005',
              name: 'Five',
              nameTH: 'ห้า',
              createdAt: '2025-01-01',
            ),
          );
      await db
          .into(db.customers)
          .insert(
            CustomersCompanion.insert(
              id: 'x2',
              code: 'CUS002',
              name: 'Two',
              nameTH: 'สอง',
              createdAt: '2025-01-01',
            ),
          );

      final c = await repo.addCustomer(
        const CustomersCompanion(name: Value('Six'), nameTH: Value('หก')),
      );
      // max is 5 → next is CUS006.
      expect(c.code, 'CUS006');
    },
  );

  test('addCustomer ignores codes whose suffix does not parse', () async {
    await clearCustomers();
    await db
        .into(db.customers)
        .insert(
          CustomersCompanion.insert(
            id: 'b1',
            code: 'BAD',
            name: 'Bad',
            nameTH: 'แย่',
            createdAt: '2025-01-01',
          ),
        );
    final c = await repo.addCustomer(
      const CustomersCompanion(name: Value('First'), nameTH: Value('หนึ่ง')),
    );
    // No parseable CUS number → maxNum stays 0 → CUS001.
    expect(c.code, 'CUS001');
  });

  test(
    'addCustomer overrides caller-supplied id/code/points/totalSpend',
    () async {
      await clearCustomers();
      final c = await repo.addCustomer(
        const CustomersCompanion(
          id: Value('SHOULD_BE_IGNORED'),
          code: Value('ZZZ999'),
          name: Value('B'),
          nameTH: Value('บี'),
          points: Value(99),
          totalSpend: Value(123.45),
        ),
      );
      expect(c.id, isNot('SHOULD_BE_IGNORED'));
      expect(c.code, 'CUS001');
      expect(c.points, 0);
      expect(c.totalSpend, 0);
      expect(c.name, 'B');
      expect(c.nameTH, 'บี');
    },
  );

  test('getCustomers returns inserted customers', () async {
    await clearCustomers();
    await repo.addCustomer(
      const CustomersCompanion(name: Value('A'), nameTH: Value('เอ')),
    );
    await repo.addCustomer(
      const CustomersCompanion(name: Value('B'), nameTH: Value('บี')),
    );
    final all = await repo.getCustomers();
    expect(all.length, 2);
    expect(all.map((c) => c.code).toSet(), {'CUS001', 'CUS002'});
  });

  test('updateCustomer merges patch fields only', () async {
    await clearCustomers();
    final c = await repo.addCustomer(
      const CustomersCompanion(name: Value('A'), nameTH: Value('เอ')),
    );
    await repo.updateCustomer(
      c.id,
      const CustomersCompanion(phone: Value('0812345678')),
    );
    final updated = await (db.select(
      db.customers,
    )..where((t) => t.id.equals(c.id))).getSingle();
    expect(updated.phone, '0812345678');
    expect(updated.name, 'A'); // untouched
    expect(updated.code, 'CUS001'); // untouched
  });

  test('deleteCustomer removes the row', () async {
    await clearCustomers();
    final c = await repo.addCustomer(
      const CustomersCompanion(name: Value('A'), nameTH: Value('เอ')),
    );
    await repo.deleteCustomer(c.id);
    final all = await repo.getCustomers();
    expect(all.where((x) => x.id == c.id), isEmpty);
  });
}
