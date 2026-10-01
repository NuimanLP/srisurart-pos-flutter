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

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/network/api_exception.dart';
import '../../core/utils/ids.dart';
import '../db/database.dart';
import '../db/product_stamp.dart';
import '../sync/outbox_product_refs.dart';
import 'movements_repository.dart';

/// Why a product in a bulk delete was refused before any write (owner-ratified
/// 2026-10-01, 02 §8.1.1).
const productHasUnsyncedOps =
    'มีรายการขาย/คืนที่ยังไม่ได้ส่งขึ้นเซิร์ฟเวอร์ — ซิงก์ให้เสร็จก่อนลบ';

/// A per-item failure whose cause has no Thai sentence of its own (owner-ratified
/// 2026-10-01).
const productDeleteFailed = 'ลบไม่สำเร็จ กรุณาลองใหม่';

/// Which kind of still-open document a product appears in (bulk delete
/// warning, owner decision 2026-10-01).
enum ProductDocKind { openPo, activeQuote, parkedBill }

/// One still-open document that references a product. [docNo] is the PO /
/// quote number; a parked bill has none and carries [parkedAt] instead.
class ProductDocRef {
  const ProductDocRef(this.kind, {this.docNo, this.parkedAt});
  final ProductDocKind kind;
  final String? docNo;
  final DateTime? parkedAt;
}

/// What [ProductsRepository.deleteMany] did, item by item.
class BulkDeleteResult {
  const BulkDeleteResult(this.deleted, this.failed);

  /// Ids whose delete was accepted, in request order.
  final List<String> deleted;

  /// id → Thai reason, for every id that was NOT deleted.
  final Map<String, String> failed;
}

class ProductsRepository {
  final AppDatabase db;
  ProductsRepository(this.db);

  /// SQLite's `lower()` only case-folds ASCII; Dart's `String.toLowerCase()`
  /// is Unicode-aware (matching db.js's JS `.toLowerCase()`). partNo values
  /// are ASCII manufacturer SKUs in every real case here (see the seed
  /// data), so the targeted `WHERE lower(part_no) = ?` query below is safe
  /// for them — but whenever the value being compared isn't pure ASCII, the
  /// dup/collision check falls back to the old Dart-side full-table scan so
  /// the comparison stays exactly Unicode-aware. (Thai script has no case
  /// distinction at all, so Thai text is unaffected either way — this only
  /// matters for cased non-ASCII scripts, e.g. Cyrillic/Greek/Turkish.)
  static bool _isAsciiOnly(String s) => s.codeUnits.every((c) => c < 128);

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

    final lower = partNo.toLowerCase();
    final bool dup;
    if (_isAsciiOnly(lower)) {
      final rows = await (db.select(
        db.products,
      )..where((t) => t.partNo.lower().equals(lower))).get();
      dup = rows.isNotEmpty;
    } else {
      final existing = await db.select(db.products).get();
      dup = existing.any((x) => x.partNo.toLowerCase() == lower);
    }
    if (dup) return null;

    final row = data.copyWith(id: Value(newId('p')), partNo: Value(partNo)).stamped;
    return db.into(db.products).insertReturning(row);
  }

  /// db.js updateProduct: returns false if the new partNo collides with ANOTHER
  /// product (case-insensitive); otherwise applies the patch and returns true.
  Future<bool> update(String id, ProductsCompanion patch) async {
    if (patch.partNo.present) {
      final newPart = patch.partNo.value.trim().toLowerCase();
      final bool collides;
      if (_isAsciiOnly(newPart)) {
        final rows = await (db.select(db.products)..where(
          (t) => t.id.equals(id).not() & t.partNo.lower().equals(newPart),
        )).get();
        collides = rows.isNotEmpty;
      } else {
        final all = await db.select(db.products).get();
        collides = all.any(
          (p) => p.id != id && p.partNo.toLowerCase() == newPart,
        );
      }
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

  /// Products that an unsent outbox op still references — these cannot be
  /// deleted until the op is sent or discarded (08 §15).
  Future<Set<String>> productIdsWithUnsyncedOps() => productIdsInOutbox(db);

  /// For each of [products], the still-open documents that reference it — a
  /// WARNING only (owner decision 2026-10-01): the product stays deletable.
  ///
  /// Read-only, local Drift only, one query per table (no `IN` list, so a
  /// select-all of thousands of products is fine):
  ///  • an `open` PO whose line matches by partNo, case-insensitive (PO lines
  ///    carry no productId — `receivePO` matches the same way);
  ///  • a quote that is neither converted nor expired (same test as
  ///    `QuoteRowStatus.isConverted` / `isExpired`);
  ///  • a parked bill on THIS device (`parked_sales` never leaves it).
  /// On the API build POs/quotes are the copies last pulled into Drift.
  /// Products with no reference are absent from the map.
  Future<Map<String, List<ProductDocRef>>> openDocumentRefs(
    List<ProductRow> products,
  ) async {
    final out = <String, List<ProductDocRef>>{};
    if (products.isEmpty) return out;
    void add(String id, ProductDocRef r) => (out[id] ??= []).add(r);
    final wanted = {for (final p in products) p.id};
    final byPartNo = <String, List<String>>{};
    for (final p in products) {
      (byPartNo[p.partNo.toLowerCase()] ??= []).add(p.id);
    }

    final poLines = await (db.select(db.poItems).join([
      innerJoin(
        db.purchaseOrders,
        db.purchaseOrders.id.equalsExp(db.poItems.poId),
      ),
    ])..where(db.purchaseOrders.status.equals('open'))).get();
    final seenPo = <String>{};
    for (final r in poLines) {
      final po = r.readTable(db.purchaseOrders);
      final line = r.readTable(db.poItems);
      for (final id
          in byPartNo[line.partNo.toLowerCase()] ?? const <String>[]) {
        if (seenPo.add('${po.id}|$id')) {
          add(id, ProductDocRef(ProductDocKind.openPo, docNo: po.poNo));
        }
      }
    }

    final now = DateTime.now();
    final quoteLines =
        await (db.select(db.quoteItems).join([
              innerJoin(
                db.quotes,
                db.quotes.id.equalsExp(db.quoteItems.quoteId),
              ),
            ])..where(
              db.quotes.status.equals('converted').not() &
                  db.quotes.validUntil.isBiggerOrEqualValue(now),
            ))
            .get();
    final seenQuote = <String>{};
    for (final r in quoteLines) {
      final q = r.readTable(db.quotes);
      final id = r.readTable(db.quoteItems).productId;
      // Filtered here, not with SQL `IN`: a select-all can exceed SQLite's
      // bound-variable limit.
      if (id == null || !wanted.contains(id)) continue;
      if (seenQuote.add('${q.id}|$id')) {
        add(id, ProductDocRef(ProductDocKind.activeQuote, docNo: q.quoteNo));
      }
    }

    for (final pk in await db.select(db.parkedSales).get()) {
      final ids = <String>{};
      try {
        final items = (jsonDecode(pk.payload) as Map)['items'];
        if (items is List) {
          for (final it in items) {
            final pid = it is Map ? it['productId'] : null;
            if (pid is String && wanted.contains(pid)) ids.add(pid);
          }
        }
      } catch (_) {
        // An unreadable blob cannot name a product — skip, never block.
      }
      for (final id in ids) {
        add(
          id,
          ProductDocRef(ProductDocKind.parkedBill, parkedAt: pk.parkedAt),
        );
      }
    }
    return out;
  }

  /// Bulk delete: one [delete] per id, in order, each its own write (on the API
  /// build: its own `DELETE /products/:id` + `Idempotency-Key`, a soft delete
  /// the server answers 200 for an already-deleted id, so a retry is safe).
  ///
  /// Not all-or-nothing on purpose — there is no cross-product invariant to
  /// protect, and one refusal must not hide which others went through. Ids an
  /// outbox op references are refused up front with [productHasUnsyncedOps];
  /// every other failure is caught and reported per id, never thrown.
  Future<BulkDeleteResult> deleteMany(List<String> ids) async {
    final Set<String> blocked;
    try {
      blocked = await productIdsWithUnsyncedOps();
    } catch (_) {
      return BulkDeleteResult(const [], {
        for (final id in ids.toSet()) id: productDeleteFailed,
      });
    }
    final deleted = <String>[];
    final failed = <String, String>{};
    for (final id in ids.toSet()) {
      if (blocked.contains(id)) {
        failed[id] = productHasUnsyncedOps;
        continue;
      }
      try {
        await delete(id);
        deleted.add(id);
      } on PosException catch (e) {
        failed[id] = e.message; // the server's own Thai sentence
      } catch (_) {
        // Transport failure, timeout, anything that is not a server reply
        // (a 5xx IS a reply: PosException above) — no Thai sentence of its
        // own. The fate may be unknown, but a retry is a fresh idempotent soft delete,
        // so "try again" is the honest advice. Caught broadly on purpose:
        // this method promises never to throw mid-batch.
        failed[id] = productDeleteFailed;
      }
    }
    return BulkDeleteResult(deleted, failed);
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
