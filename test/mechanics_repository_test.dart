import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/mechanics_repository.dart';

void main() {
  late AppDatabase db;
  late MechanicsRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = MechanicsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('getMechanics returns seeded mechanics (M001-M003)', () async {
    final all = await repo.getMechanics();
    expect(all.length, 3);
    final codes = all.map((m) => m.code).toList()..sort();
    expect(codes, ['M001', 'M002', 'M003']);
  });

  test('addMechanic auto-increments the M-code (max+1, padded to 3)', () async {
    final m = await repo.addMechanic(
      MechanicsCompanion.insert(
        id: 'IGNORED',
        code: 'IGNORED', // overwritten by the repo
        name: 'New Guy',
        createdAt: 'IGNORED',
        creditLimit: const Value(1500),
      ),
    );
    // Seed has M001..M003 → next is M004.
    expect(m.code, 'M004');
    expect(m.id.startsWith('m'), isTrue);
    expect(m.creditLimit, 1500);
    expect(m.creditBalance, 0);
    expect(m.totalSales, 0);
    expect(m.totalCredit, 0);
    expect(m.totalMarkup, 0);
    expect(m.totalDiscount, 0);
    // createdAt = today yyyy-MM-dd.
    expect(RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(m.createdAt), isTrue);

    // Add another → M005 (auto-increments off the new max).
    final m2 = await repo.addMechanic(
      MechanicsCompanion.insert(
        id: 'IGNORED',
        code: 'x',
        name: 'Another',
        createdAt: 'x',
      ),
    );
    expect(m2.code, 'M005');
  });

  test('addMechanic on an empty table starts at M001', () async {
    await db.delete(db.mechanics).go();
    final m = await repo.addMechanic(
      MechanicsCompanion.insert(
        id: 'IGNORED',
        code: 'x',
        name: 'First',
        createdAt: 'x',
      ),
    );
    expect(m.code, 'M001');
  });

  test(
    'addCreditPayment records the payment and reduces creditBalance',
    () async {
      // Give m1 a balance of 1000.
      await (db.update(db.mechanics)..where((t) => t.id.equals('m1'))).write(
        const MechanicsCompanion(creditBalance: Value(1000)),
      );

      final pay = await repo.addCreditPayment(mechanicId: 'm1', amount: 300);
      expect(pay.id.startsWith('cp'), isTrue);
      expect(pay.receiptNo.startsWith('CP'), isTrue);
      expect(pay.amount, 300);
      expect(pay.mechanicId, 'm1');

      final payments = await repo.getCreditPayments();
      expect(payments.length, 1);
      expect(payments.first.id, pay.id);

      final mech = await (db.select(
        db.mechanics,
      )..where((t) => t.id.equals('m1'))).getSingle();
      expect(mech.creditBalance, 700); // 1000 - 300
    },
  );

  test('addCreditPayment clamps creditBalance at 0 (never negative)', () async {
    await (db.update(db.mechanics)..where((t) => t.id.equals('m1'))).write(
      const MechanicsCompanion(creditBalance: Value(200)),
    );

    await repo.addCreditPayment(mechanicId: 'm1', amount: 500);

    final mech = await (db.select(
      db.mechanics,
    )..where((t) => t.id.equals('m1'))).getSingle();
    expect(mech.creditBalance, 0); // max(0, 200 - 500)
  });

  test('getCreditPayments returns newest-first', () async {
    await repo.addCreditPayment(mechanicId: 'm1', amount: 100);
    // Even within the same second (drift stores DateTime as epoch seconds), the
    // rowid tiebreaker must keep the later insert first.
    final second = await repo.addCreditPayment(mechanicId: 'm2', amount: 50);

    final payments = await repo.getCreditPayments();
    expect(payments.length, 2);
    expect(payments.first.id, second.id); // newest first
  });
}
