// ProductsRepository — products + categories (sa_products / sa_categories).
//
// Implementation of the Products service contract. Ports db.js:
//   getProducts/saveProducts/addProduct/updateProduct/deleteProduct/adjustStock
//   getCategories/addCategory/deleteCategory + getCatColor.
//
// Behaviour (from db.js):
//  • getAll/watchAll → on read, migrate legacy `zone` field to `category` using
//    zoneMap {Engine:เครื่องยนต์, Electrical:ไฟฟ้า, Oils:น้ำมัน, Brakes:เบรก,
//    Body:ตัวถัง} → fall back to raw zone, else 'เครื่องยนต์'.
//  • add → returns NULL on blank partNo OR duplicate partNo (case-insensitive);
//    otherwise inserts with id = newId('p') and the trimmed partNo.
//  • update → returns FALSE if the new partNo collides with ANOTHER product
//    (case-insensitive); otherwise applies the patch and returns TRUE.
//  • adjustStock → MANUAL adjust CLAMPS at 0 (max(0, stock+delta)), updates the
//    product, AND logs a movement via MovementsRepository.
//  • getCategories → Categories ordered by position; SEED_CATEGORIES if empty.
//  • catColor → CAT_PALETTE[index-in-categories % len], hash fallback for unknown.

import 'package:drift/drift.dart';

import '../../core/utils/ids.dart';
import '../db/database.dart';
import 'movements_repository.dart';

class ProductsRepository {
  final AppDatabase db;
  ProductsRepository(this.db);

  /// SEED_CATEGORIES from db.js — fallback when the Categories table is empty.
  static const List<String> seedCategories = [
    'เครื่องยนต์',
    'ไฟฟ้า',
    'น้ำมัน',
    'เบรก',
    'ตัวถัง',
  ];

  /// Category color palette — consistent color per category name (db.js CAT_PALETTE).
  static const List<String> catPalette = [
    '#1E4A80',
    '#C04E10',
    '#3B6D11',
    '#6B2DA8',
    '#1A6B5C',
    '#8B4513',
    '#1A5C8B',
    '#8B2840',
    '#4A6B1A',
    '#6B4A1A',
  ];

  /// Legacy zone → category mapping (db.js getProducts zoneMap).
  static const Map<String, String> _zoneMap = {
    'Engine': 'เครื่องยนต์',
    'Electrical': 'ไฟฟ้า',
    'Oils': 'น้ำมัน',
    'Brakes': 'เบรก',
    'Body': 'ตัวถัง',
  };

  /// Port of db.js getProducts' read migration: if `category` is empty, derive
  /// it from the legacy `zone` field via zoneMap (fall back to raw zone, else
  /// 'เครื่องยนต์'). Stored row classes are immutable → return a copy.
  ProductRow _migrate(ProductRow p) {
    if (p.category.isNotEmpty) return p;
    final zone = p.zone;
    final category =
        (zone != null ? _zoneMap[zone] : null) ?? zone ?? 'เครื่องยนต์';
    return p.copyWith(category: category);
  }

  Future<List<ProductRow>> getAll() async {
    final rows = await db.select(db.products).get();
    return rows.map(_migrate).toList();
  }

  Stream<List<ProductRow>> watchAll() {
    return db
        .select(db.products)
        .watch()
        .map((rows) => rows.map(_migrate).toList());
  }

  Future<ProductRow?> getById(String id) async {
    final row = await (db.select(
      db.products,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _migrate(row);
  }

  /// db.js addProduct: returns null on blank/duplicate (case-insensitive) partNo,
  /// otherwise inserts with the trimmed partNo and a fresh newId('p').
  Future<ProductRow?> add(ProductsCompanion data) async {
    final partNo = (data.partNo.present ? data.partNo.value : '').trim();
    if (partNo.isEmpty) return null;

    final existing = await db.select(db.products).get();
    final lower = partNo.toLowerCase();
    final dup = existing.any((x) => x.partNo.toLowerCase() == lower);
    if (dup) return null;

    final row = data.copyWith(id: Value(newId('p')), partNo: Value(partNo)).stamped;
    return db.into(db.products).insertReturning(row);
  }

  /// db.js updateProduct: returns false if the new partNo collides with ANOTHER
  /// product (case-insensitive); otherwise applies the patch and returns true.
  Future<bool> update(String id, ProductsCompanion patch) async {
    if (patch.partNo.present) {
      final newPart = patch.partNo.value.trim().toLowerCase();
      final all = await db.select(db.products).get();
      final collides = all.any(
        (p) => p.id != id && p.partNo.toLowerCase() == newPart,
      );
      if (collides) return false;
    }
    await (db.update(
      db.products,
    )..where((t) => t.id.equals(id))).write(patch.stamped);
    return true;
  }

  Future<void> delete(String id) async {
    await (db.delete(db.products)..where((t) => t.id.equals(id))).go();
  }

  /// db.js adjustStock — MANUAL adjust CLAMPS at 0 (max(0, stock+delta)),
  /// updates the product, then logs a movement. No-op if product not found.
  Future<void> adjustStock(
    String productId,
    int delta,
    String type,
    String? note,
  ) async {
    final p = await (db.select(
      db.products,
    )..where((t) => t.id.equals(productId))).getSingleOrNull();
    if (p == null) return;
    final newStock = (p.stock + delta) < 0 ? 0 : (p.stock + delta);
    await (db.update(db.products)..where((t) => t.id.equals(productId))).write(
      ProductsCompanion(stock: Value(newStock)).stamped,
    );
    await MovementsRepository(db).addMovement(
      productId: productId,
      partNo: p.partNo,
      name: p.name,
      delta: delta,
      type: type,
      note: note,
      stockAfter: newStock,
    );
  }

  /// db.js getCategories: Categories ordered by position; SEED_CATEGORIES if empty.
  Future<List<String>> getCategories() async {
    final rows = await (db.select(
      db.categories,
    )..orderBy([(t) => OrderingTerm.asc(t.position)])).get();
    if (rows.isEmpty) return List<String>.from(seedCategories);
    return rows.map((r) => r.name).toList();
  }

  /// db.js addCategory: trim, ignore blank/duplicate, append with next position.
  Future<void> addCategory(String name) async {
    final t = name.trim();
    if (t.isEmpty) return;
    final rows = await (db.select(
      db.categories,
    )..orderBy([(c) => OrderingTerm.asc(c.position)])).get();
    if (rows.any((c) => c.name == t)) return;
    final nextPos = rows.isEmpty ? 0 : rows.last.position + 1;
    await db
        .into(db.categories)
        .insert(CategoriesCompanion.insert(name: t, position: nextPos));
  }

  /// db.js deleteCategory: drop the matching category row.
  Future<void> deleteCategory(String name) async {
    await (db.delete(db.categories)..where((t) => t.name.equals(name))).go();
  }

  /// Port of db.js getCatColor: CAT_PALETTE[index-in-categories % len]; hash
  /// fallback for categories not in the list.
  Future<String> catColor(String name) async {
    final cats = await getCategories();
    final idx = cats.indexOf(name);
    if (idx >= 0) return catPalette[idx % catPalette.length];
    // Fallback: hash for unknown categories, mirrors db.js getCatColor exactly.
    // JS `& 0xffffffff` coerces to a SIGNED 32-bit int (then Math.abs). Dart ints
    // are 64-bit, so emulate the signed 32-bit wrap with .toSigned(32).
    var h = 0;
    for (var i = 0; i < name.length; i++) {
      h = (h * 31 + name.codeUnitAt(i)).toSigned(32);
    }
    return catPalette[h.abs() % catPalette.length];
  }
}
