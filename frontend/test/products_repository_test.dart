import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/repositories/movements_repository.dart';

void main() {
  late AppDatabase db;
  late ProductsRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = ProductsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('getAll returns seeded products with categories', () async {
    final all = await repo.getAll();
    expect(all.length, 12);
    // All seeded products already have a category (no zone migration needed).
    expect(all.every((p) => p.category.isNotEmpty), isTrue);
  });

  test('add with a fresh partNo inserts and assigns a p-prefixed id', () async {
    final added = await repo.add(
      ProductsCompanion.insert(
        id: 'IGNORED',
        partNo: 'NEW-001',
        name: 'New Part',
        nameTH: 'ของใหม่',
        category: 'ไฟฟ้า',
        brand: 'Acme',
        price: 100,
        cost: 50,
        stock: 5,
        minStock: 1,
      ),
    );
    expect(added, isNotNull);
    expect(added!.partNo, 'NEW-001');
    expect(added.id.startsWith('p'), isTrue);
    expect(added.id == 'IGNORED', isFalse);
    expect((await repo.getAll()).length, 13);
  });

  test('add trims the partNo before storing', () async {
    final added = await repo.add(
      ProductsCompanion.insert(
        id: 'x',
        partNo: '  PAD-001  ',
        name: 'Pad',
        nameTH: 'แพด',
        category: 'เบรก',
        brand: 'B',
        price: 10,
        cost: 5,
        stock: 1,
        minStock: 1,
      ),
    );
    expect(added, isNotNull);
    expect(added!.partNo, 'PAD-001');
  });

  test('add with blank partNo returns null and inserts nothing', () async {
    final added = await repo.add(
      ProductsCompanion.insert(
        id: 'x',
        partNo: '   ',
        name: 'Blank',
        nameTH: 'ว่าง',
        category: 'ไฟฟ้า',
        brand: 'B',
        price: 1,
        cost: 1,
        stock: 1,
        minStock: 1,
      ),
    );
    expect(added, isNull);
    expect((await repo.getAll()).length, 12);
  });

  test('add with duplicate partNo (case-insensitive) returns null', () async {
    // Seed product p1 has partNo 'HN-15412-KVB'.
    final added = await repo.add(
      ProductsCompanion.insert(
        id: 'x',
        partNo: 'hn-15412-kvb',
        name: 'Dup',
        nameTH: 'ซ้ำ',
        category: 'เครื่องยนต์',
        brand: 'B',
        price: 1,
        cost: 1,
        stock: 1,
        minStock: 1,
      ),
    );
    expect(added, isNull);
    expect((await repo.getAll()).length, 12);
  });

  test(
    'update to a colliding partNo (another product) returns false',
    () async {
      // Try to set p2's partNo to p1's partNo (case-insensitive collision).
      final ok = await repo.update(
        'p2',
        const ProductsCompanion(partNo: Value('HN-15412-KVB')),
      );
      expect(ok, isFalse);
      final p2 = await repo.getById('p2');
      expect(p2!.partNo, 'NGK-BR8ES-11'); // unchanged
    },
  );

  test('update keeping the same partNo on the same product succeeds', () async {
    final ok = await repo.update(
      'p1',
      const ProductsCompanion(
        partNo: Value('HN-15412-KVB'),
        name: Value('Renamed'),
      ),
    );
    expect(ok, isTrue);
    final p1 = await repo.getById('p1');
    expect(p1!.name, 'Renamed');
  });

  test(
    'update with a non-colliding partNo succeeds and applies patch',
    () async {
      final ok = await repo.update(
        'p1',
        const ProductsCompanion(partNo: Value('HN-99999-XYZ')),
      );
      expect(ok, isTrue);
      final p1 = await repo.getById('p1');
      expect(p1!.partNo, 'HN-99999-XYZ');
    },
  );

  test('delete removes the product', () async {
    await repo.delete('p1');
    expect(await repo.getById('p1'), isNull);
    expect((await repo.getAll()).length, 11);
  });

  test('adjustStock positive delta adds stock and writes a movement', () async {
    // p1 seeded stock = 48.
    await repo.adjustStock('p1', 5, 'adjust', 'restock');
    final p1 = await repo.getById('p1');
    expect(p1!.stock, 53);

    final moves = await MovementsRepository(db).getMovements();
    expect(moves.length, 1);
    expect(moves.first.productId, 'p1');
    expect(moves.first.delta, 5);
    expect(moves.first.type, 'adjust');
    expect(moves.first.note, 'restock');
    expect(moves.first.stockAfter, 53);
  });

  test(
    'adjustStock below zero CLAMPS to 0 and writes a movement with stockAfter 0',
    () async {
      // p8 seeded stock = 5; subtract 10 → clamp at 0.
      await repo.adjustStock('p8', -10, 'adjust', null);
      final p8 = await repo.getById('p8');
      expect(p8!.stock, 0);

      final moves = await MovementsRepository(db).getMovements();
      expect(moves.length, 1);
      expect(moves.first.delta, -10); // raw delta preserved
      expect(moves.first.stockAfter, 0); // clamped value
    },
  );

  test('adjustStock on a missing product is a no-op (no movement)', () async {
    await repo.adjustStock('nope', 5, 'adjust', null);
    final moves = await MovementsRepository(db).getMovements();
    expect(moves, isEmpty);
  });

  test('getCategories returns seeded categories in palette order', () async {
    final cats = await repo.getCategories();
    expect(cats, ProductsRepository.seedCategories);
  });

  test('addCategory appends; blank and duplicate are ignored', () async {
    await repo.addCategory('  ช่วงล่าง  ');
    var cats = await repo.getCategories();
    expect(cats.last, 'ช่วงล่าง'); // trimmed + appended last

    await repo.addCategory('   '); // blank → ignored
    await repo.addCategory('ช่วงล่าง'); // dup → ignored
    cats = await repo.getCategories();
    expect(cats.where((c) => c == 'ช่วงล่าง').length, 1);
    expect(cats.length, ProductsRepository.seedCategories.length + 1);
  });

  test('deleteCategory removes a category', () async {
    await repo.deleteCategory('ไฟฟ้า');
    final cats = await repo.getCategories();
    expect(cats.contains('ไฟฟ้า'), isFalse);
  });

  test('catColor is stable by category index (palette order)', () async {
    final cats = await repo.getCategories();
    for (var i = 0; i < cats.length; i++) {
      final color = await repo.catColor(cats[i]);
      expect(
        color,
        ProductsRepository.catPalette[i % ProductsRepository.catPalette.length],
      );
    }
    // เครื่องยนต์ is index 0 → first palette color.
    expect(await repo.catColor('เครื่องยนต์'), '#1E4A80');
    // ไฟฟ้า is index 1 → second palette color.
    expect(await repo.catColor('ไฟฟ้า'), '#C04E10');
  });

  test(
    'catColor for an unknown category uses the hash fallback (deterministic)',
    () async {
      final c1 = await repo.catColor('ไม่รู้จัก');
      final c2 = await repo.catColor('ไม่รู้จัก');
      expect(c1, c2); // stable
      expect(ProductsRepository.catPalette.contains(c1), isTrue);
    },
  );
}
