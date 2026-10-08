// Unit tests for FavoritesRepository (sell-screen stars, this device only) and
// the pure favoritesFirst ordering helper.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/favorites_repository.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';

void main() {
  late AppDatabase db;
  late FavoritesRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = FavoritesRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('empty by default', () async {
    expect(await repo.getFavorites(), isEmpty);
  });

  test('toggle stars, then unstars', () async {
    expect(await repo.toggle('a'), {'a'});
    expect(await repo.toggle('b'), {'a', 'b'});
    expect(await repo.toggle('a'), {'b'});
    expect(await repo.getFavorites(), {'b'});
  });

  test(
    'persists in AppMeta as a JSON array, readable by a new instance',
    () async {
      await repo.toggle('x');
      final row =
          await (db.select(db.appMeta)
                ..where((t) => t.key.equals(FavoritesRepository.favoritesKey)))
              .getSingle();
      expect(row.value, '["x"]');
      expect(await FavoritesRepository(db).getFavorites(), {'x'});
    },
  );

  test(
    'a corrupt stored value reads as empty and is overwritten by toggle',
    () async {
      await db
          .into(db.appMeta)
          .insertOnConflictUpdate(
            const AppMetaCompanion(
              key: Value(FavoritesRepository.favoritesKey),
              value: Value('not json'),
            ),
          );
      expect(await repo.getFavorites(), isEmpty);
      expect(await repo.toggle('y'), {'y'});
    },
  );

  test('a non-list JSON value ({}) reads as empty', () async {
    await db
        .into(db.appMeta)
        .insertOnConflictUpdate(
          const AppMetaCompanion(
            key: Value(FavoritesRepository.favoritesKey),
            value: Value('{}'),
          ),
        );
    expect(await repo.getFavorites(), isEmpty);
  });

  test('a tenant switch (resetTenantCache) clears favorites', () async {
    await repo.toggle('x');
    await db.resetTenantCache();
    expect(await repo.getFavorites(), isEmpty);
  });

  group('favoritesFirst', () {
    late List<ProductRow> products;
    setUp(() async {
      products = await ProductsRepository(db).getAll();
      expect(products.length, greaterThanOrEqualTo(4));
    });

    List<String> ids(List<ProductRow> l) => l.map((p) => p.id).toList();

    test('no favorites keeps the order', () {
      expect(ids(favoritesFirst(products, {})), ids(products));
    });

    test('starred first, each group in its original order (stable)', () {
      final favs = {products[3].id, products[1].id};
      final out = favoritesFirst(products, favs);
      expect(ids(out), [
        products[1].id,
        products[3].id,
        for (final p in products)
          if (!favs.contains(p.id)) p.id,
      ]);
    });

    test('onlyFavorites keeps only starred; unknown ids are ignored', () {
      final out = favoritesFirst(products, {
        products[2].id,
        'deleted-product',
      }, onlyFavorites: true);
      expect(ids(out), [products[2].id]);
    });
  });
}
