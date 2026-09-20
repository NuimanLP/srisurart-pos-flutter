// ApiProductsRepository — write-through cache implementation of ProductsRepository.
//
// Complies with ADR-0010:
//  • PostgreSQL is the source of truth; Drift acts as local write-through cache.
//  • NEVER calls Drift transactional services (no local clamping in adjustStock).
//  • Incremental sync uses ?updatedSince= cursor; soft-deletions tracked via deletedAt.
//  • When offline, transparently falls back to local Drift database.

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../db/database.dart';
import 'api/api_wire.dart';
import 'movements_repository.dart';
import 'products_repository.dart';

class ApiProductsRepository extends ProductsRepository {
  final ApiClient apiClient;

  ApiProductsRepository(super.db, this.apiClient);

  /// Converts API JSON representation to a Drift [ProductsCompanion].
  ProductsCompanion _productToCompanion(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final partNo = (json['partNo'] ?? json['part_no'] ?? '') as String;
    final name = (json['name'] ?? '') as String;
    final nameTH = (json['nameTH'] ?? json['name_t_h'] ?? json['nameTh'] ?? '') as String;
    final category = (json['category'] ?? '') as String;
    final brand = (json['brand'] ?? '') as String;
    final price = money(json['price']);
    final cost = money(json['cost']);
    final stock = (json['stock'] as num?)?.toInt() ?? 0;
    final minStock = (json['minStock'] ?? json['min_stock'] as num?)?.toInt() ?? 0;
    final compat = json['compat'] as String?;
    final zone = json['zone'] as String?;

    final updatedAt = stampOrNull(json['updatedAt']);
    final deletedAt = stampOrNull(json['deletedAt']);

    return ProductsCompanion(
      id: Value(id),
      partNo: Value(partNo),
      name: Value(name),
      nameTH: Value(nameTH),
      category: Value(category),
      brand: Value(brand),
      price: Value(price),
      cost: Value(cost),
      stock: Value(stock),
      minStock: Value(minStock),
      compat: Value(compat),
      zone: Value(zone),
      updatedAt: Value(updatedAt),
      deletedAt: Value(deletedAt),
    );
  }

  /// Write-through sync: pulls updates from server and patches Drift.
  /// Uses server `meta.nextCursor` stored in `sync_cursors` with 30s rewind window
  /// and protects local stock of products with pending outbox operations (#212, 08 §15).
  Future<void> syncFromServer({bool forceFull = false}) async {
    try {
      String? updatedSince;
      String? afterId;

      if (!forceFull) {
        final cursorRow = await (db.select(db.syncCursors)
              ..where((t) => t.entity.equals('products')))
            .getSingleOrNull();

        if (cursorRow?.cursor != null && cursorRow!.cursor!.isNotEmpty) {
          final dt = DateTime.parse(cursorRow.cursor!).toUtc();
          // 08 §15: หน้าแรกของรอบ: updatedSince = cursor − 30 วินาที และไม่ส่ง afterId
          updatedSince = dt.subtract(const Duration(seconds: 30)).toIso8601String();
          afterId = null;
        } else {
          updatedSince = '1970-01-01T00:00:00.000Z';
          afterId = null;
        }
      } else {
        updatedSince = '1970-01-01T00:00:00.000Z';
        afterId = null;
      }

      // Collect product IDs associated with active pending ops in outbox_ops.
      // ADR-0010 §D3 / 08 §15: pull must NOT overwrite local stock of products with pending ops.
      final pendingOps = await (db.select(db.outboxOps)
            ..where((t) => t.status.isIn(const ['pending', 'stuck'])))
          .get();
      final pendingProductIds = <String>{};
      for (final op in pendingOps) {
        try {
          final aggs = jsonDecode(op.aggregates);
          if (aggs is List) {
            for (final a in aggs) {
              if (a is String && a.startsWith('product:')) {
                pendingProductIds.add(a.substring('product:'.length));
              }
            }
          }
        } catch (_) {}
        try {
          final payload = jsonDecode(op.payload);
          if (payload is Map && payload['items'] is List) {
            for (final item in payload['items']) {
              if (item is Map && item['productId'] != null) {
                pendingProductIds.add(item['productId'].toString());
              }
            }
          }
        } catch (_) {}
      }

      bool hasMore = true;
      String? latestServerCursor;

      while (hasMore) {
        final queryParams = <String, dynamic>{
          'limit': 100,
          'updatedSince': updatedSince,
        };
        if (afterId != null) queryParams['afterId'] = afterId;

        final res = await apiClient.getPaginated('/api/v1/products', queryParameters: queryParams);
        final items = res.data;

        if (items.isNotEmpty) {
          final companions = <ProductsCompanion>[];
          for (final item in items) {
            if (item is Map) {
              var comp = _productToCompanion(Map<String, dynamic>.from(item));
              final prodId = comp.id.value;
              if (pendingProductIds.contains(prodId)) {
                final localProd = await (db.select(db.products)
                      ..where((t) => t.id.equals(prodId)))
                    .getSingleOrNull();
                if (localProd != null) {
                  // Protect local stock from being overwritten by server.
                  comp = comp.copyWith(stock: Value(localProd.stock));
                }
              }
              companions.add(comp);
            }
          }

          if (companions.isNotEmpty) {
            await db.batch((batch) {
              for (final comp in companions) {
                batch.insert(
                  db.products,
                  comp,
                  onConflict: DoUpdate((old) => comp),
                );
              }
            });
          }
        }

        if (items.isEmpty) {
          hasMore = false;
        } else {
          final next = res.nextCursor;
          if (next != null && next['updatedSince'] != null) {
            latestServerCursor = next['updatedSince'] as String;
            updatedSince = latestServerCursor;
            afterId = next['afterId'] as String?;
          } else {
            hasMore = false;
          }
        }
      }

      if (latestServerCursor != null) {
        await db.into(db.syncCursors).insertOnConflictUpdate(
          SyncCursorsCompanion(
            entity: const Value('products'),
            cursor: Value(latestServerCursor),
            updatedAt: Value(DateTime.now().toUtc()),
          ),
        );
      }
    } catch (_) {
      // Network failure or degraded mode: gracefully ignore and rely on Drift cache
    }
  }

  @override
  Future<List<ProductRow>> getAll() async {
    await syncFromServer();
    final rows = await (db.select(db.products)
          ..where((t) =>
              t.deletedAt.isNull() &
              (t.brand.isNull() | t.brand.equals('import-tombstone').not())))
        .get();
    return rows.map((r) => r.category.isNotEmpty ? r : r.copyWith(category: r.zone ?? 'เครื่องยนต์')).toList();
  }

  @override
  Stream<List<ProductRow>> watchAll() {
    return (db.select(db.products)
          ..where((t) =>
              t.deletedAt.isNull() &
              (t.brand.isNull() | t.brand.equals('import-tombstone').not())))
        .watch()
        .map((rows) => rows
            .map((r) => r.category.isNotEmpty
                ? r
                : r.copyWith(category: r.zone ?? 'เครื่องยนต์'))
            .toList());
  }

  @override
  Future<ProductRow?> getById(String id) async {
    final local = await (db.select(db.products)
          ..where((t) =>
              t.id.equals(id) &
              t.deletedAt.isNull() &
              (t.brand.isNull() | t.brand.equals('import-tombstone').not())))
        .getSingleOrNull();
    if (local != null) return local;

    try {
      final res = await apiClient.get('/api/v1/products/$id');
      if (res is Map) {
        final comp = _productToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.products).insertOnConflictUpdate(comp);
        return await (db.select(db.products)
              ..where((t) =>
                  t.id.equals(id) &
                  t.deletedAt.isNull() &
                  (t.brand.isNull() | t.brand.equals('import-tombstone').not())))
            .getSingleOrNull();
      }
    } catch (_) {}

    return null;
  }

  @override
  Future<ProductRow?> add(ProductsCompanion data) async {
    final partNo = (data.partNo.present ? data.partNo.value : '').trim();
    if (partNo.isEmpty) return null;

    final body = {
      'partNo': partNo,
      'name': data.name.present ? data.name.value : '',
      'nameTH': data.nameTH.present ? data.nameTH.value : '',
      'category': data.category.present ? data.category.value : '',
      'brand': data.brand.present ? data.brand.value : '',
      'price': data.price.present ? wireMoney(data.price.value) : '0.00',
      'cost': data.cost.present ? wireMoney(data.cost.value) : '0.00',
      'stock': data.stock.present ? data.stock.value : 0,
      'minStock': data.minStock.present ? data.minStock.value : 0,
      if (data.compat.present && data.compat.value != null) 'compat': data.compat.value,
    };

    final res = await apiClient.post('/api/v1/products', body: body, headers: idempotencyKey());
    if (res is Map) {
      final comp = _productToCompanion(Map<String, dynamic>.from(res));
      await db.into(db.products).insertOnConflictUpdate(comp);
      return await (db.select(db.products)..where((t) => t.id.equals(comp.id.value))).getSingle();
    }
    throw ApiException(
      statusCode: 500,
      code: 'SERVER_ERROR',
      serverMessage: 'ไม่สามารถบันทึกสินค้า',
    );
  }

  @override
  Future<bool> update(String id, ProductsCompanion patch) async {
    final body = <String, dynamic>{};
    if (patch.partNo.present) body['partNo'] = patch.partNo.value.trim();
    if (patch.name.present) body['name'] = patch.name.value;
    if (patch.nameTH.present) body['nameTH'] = patch.nameTH.value;
    if (patch.category.present) body['category'] = patch.category.value;
    if (patch.brand.present) body['brand'] = patch.brand.value;
    if (patch.price.present) body['price'] = wireMoney(patch.price.value);
    if (patch.cost.present) body['cost'] = wireMoney(patch.cost.value);
    if (patch.minStock.present) body['minStock'] = patch.minStock.value;
    if (patch.compat.present) body['compat'] = patch.compat.value;

    final res = await apiClient.patch('/api/v1/products/$id', body: body, headers: idempotencyKey());
    if (res is Map) {
      final comp = _productToCompanion(Map<String, dynamic>.from(res));
      await db.into(db.products).insertOnConflictUpdate(comp);
      return true;
    }
    return true;
  }

  @override
  Future<void> delete(String id) async {
    await apiClient.delete('/api/v1/products/$id', headers: idempotencyKey());
    // ADR-0010: soft-delete locally by setting deletedAt WITHOUT stamping client clock on updatedAt
    await (db.update(db.products)..where((t) => t.id.equals(id))).write(
      ProductsCompanion(
        deletedAt: Value(DateTime.now()),
      ),
    );
  }

  @override
  Future<void> adjustStock(
    String productId,
    int delta,
    String type,
    String? note,
  ) async {
    final p = await (db.select(db.products)..where((t) => t.id.equals(productId))).getSingleOrNull();
    if (p == null) return;

    final body = <String, dynamic>{
      'delta': delta,
      'type': type,
    };
    if (note != null) body['note'] = note;

    final res = await apiClient.post(
      '/api/v1/products/$productId/adjust-stock',
      body: body,
      headers: idempotencyKey(),
    );
    if (res is Map) {
      final resMap = Map<String, dynamic>.from(res);
      final stockAfter = (resMap['stockAfter'] as num?)?.toInt() ?? (p.stock + delta);
      // Patch row directly without client clock stamping on updatedAt (ADR-0010 §5)
      await (db.update(db.products)..where((t) => t.id.equals(productId))).write(
        ProductsCompanion(
          stock: Value(stockAfter),
        ),
      );

      final mv = resMap['movement'];
      if (mv is Map<String, dynamic>) {
        await db.into(db.movements).insertOnConflictUpdate(movementRowFromWire(mv));
      } else {
        await MovementsRepository(db).addMovement(
          productId: productId,
          partNo: p.partNo,
          name: p.name,
          delta: delta,
          type: type,
          note: note,
          stockAfter: stockAfter,
        );
      }
    }
  }

  @override
  Future<List<String>> getCategories() async {
    try {
      final res = await apiClient.get('/api/v1/categories');
      if (res is List) {
        final categoryNames = <String>[];
        for (var i = 0; i < res.length; i++) {
          final item = res[i];
          final name = item is Map ? item['name'] as String? : item.toString();
          if (name != null && name.isNotEmpty) {
            categoryNames.add(name);
            await db.into(db.categories).insert(
                  CategoriesCompanion.insert(name: name, position: i),
                  onConflict: DoUpdate((old) => CategoriesCompanion(position: Value(i))),
                );
          }
        }
        if (categoryNames.isNotEmpty) return categoryNames;
      }
    } catch (_) {}

    return super.getCategories();
  }

  @override
  Future<void> addCategory(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    await apiClient.post('/api/v1/categories', body: {'name': trimmed}, headers: idempotencyKey());
    final count = await (db.select(db.categories)).get().then((l) => l.length);
    await db.into(db.categories).insert(
          CategoriesCompanion.insert(name: trimmed, position: count),
          onConflict: DoUpdate((old) => CategoriesCompanion(position: Value(count))),
        );
  }

  @override
  Future<void> deleteCategory(String name) async {
    await apiClient.delete('/api/v1/categories/$name', headers: idempotencyKey());
    await (db.delete(db.categories)..where((t) => t.name.equals(name))).go();
  }
}
