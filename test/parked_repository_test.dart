// Unit tests for ParkedRepository.
//
// Invariants under test (db.js lines 387-395 parity):
//  • parkSale stores the cart blob as a JSON payload + a parkedAt timestamp,
//    and leaves Products completely untouched (parked bills never touch stock).
//  • getParked returns the parked row (newest-first).
//  • deleteParked removes it.

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/parked_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';

void main() {
  late AppDatabase db;
  late ParkedRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = ParkedRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  const input = ParkedInput(
    items: [
      SaleLineInput(
        productId: 'p1',
        name: 'Brake Pad',
        qty: 3,
        price: 120.0,
        partNo: 'BP-001',
        nameTH: 'ผ้าเบรก',
      ),
      SaleLineInput(productId: 'p2', name: 'Oil Filter', qty: 1, price: 80.0),
    ],
    customerId: 'c1',
    customerName: 'สมชาย',
    mechanicId: 'm1',
    mechanicName: 'ช่างเอ',
    discount: 50.0,
    extra: {'note': 'hold for pickup'},
  );

  test(
    'parkSale stores payload JSON + parkedAt and leaves Products untouched',
    () async {
      final productsBefore = (await db.select(db.products).get())
          .map((p) => p.id)
          .toSet();
      final before = DateTime.now();

      final row = await repo.parkSale(input);

      final after = DateTime.now();

      // id prefix from newId('pk').
      expect(row.id, startsWith('pk'));

      // parkedAt is a real timestamp captured during the call.
      expect(
        row.parkedAt.isBefore(before.subtract(const Duration(seconds: 1))),
        isFalse,
      );
      expect(
        row.parkedAt.isAfter(after.add(const Duration(seconds: 1))),
        isFalse,
      );

      // payload decodes to the full cart blob.
      final blob = jsonDecode(row.payload) as Map<String, dynamic>;
      expect(blob['customerId'], 'c1');
      expect(blob['customerName'], 'สมชาย');
      expect(blob['mechanicId'], 'm1');
      expect(blob['mechanicName'], 'ช่างเอ');
      expect(blob['discount'], 50.0);
      expect(blob['note'], 'hold for pickup'); // extra carried through
      expect(blob['id'], row.id);
      expect(blob['parkedAt'], row.parkedAt.toIso8601String());

      final items = (blob['items'] as List).cast<Map<String, dynamic>>();
      expect(items, hasLength(2));
      expect(items[0]['productId'], 'p1');
      expect(items[0]['name'], 'Brake Pad');
      expect(items[0]['qty'], 3);
      expect(items[0]['price'], 120.0);
      expect(items[0]['partNo'], 'BP-001');
      expect(items[0]['nameTH'], 'ผ้าเบรก');
      expect(items[1]['productId'], 'p2');
      expect(items[1].containsKey('partNo'), isFalse);

      // Products table is completely untouched — same set of ids, none mutated.
      final productsAfter = (await db.select(db.products).get())
          .map((p) => p.id)
          .toSet();
      expect(productsAfter, equals(productsBefore));
    },
  );

  test('getParked returns the stored bill, newest-first', () async {
    final row = await repo.parkSale(input);

    final all = await repo.getParked();
    expect(all, hasLength(1));
    expect(all.first.id, row.id);
    expect(all.first.payload, row.payload);

    // Park a second one — must sort newest-first by parkedAt desc.
    final second = await repo.parkSale(
      const ParkedInput(
        items: [
          SaleLineInput(productId: 'p9', name: 'Wiper', qty: 1, price: 10),
        ],
      ),
    );
    final allTwo = await repo.getParked();
    expect(allTwo, hasLength(2));
    expect(allTwo.first.id, second.id);
    expect(allTwo.last.id, row.id);
  });

  test('deleteParked removes the bill', () async {
    final row = await repo.parkSale(input);
    expect(await repo.getParked(), hasLength(1));

    await repo.deleteParked(row.id);
    expect(await repo.getParked(), isEmpty);

    // Deleting a non-existent id is a no-op (does not throw).
    await repo.deleteParked('pk_does_not_exist');
    expect(await repo.getParked(), isEmpty);
  });
}
