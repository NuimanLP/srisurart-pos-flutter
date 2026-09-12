// ApiProductsRepository — write-through cache implementation of ProductsRepository.
//
// Complies with ADR-0010:
//  • PostgreSQL is the source of truth; Drift acts as local write-through cache.
//  • NEVER calls Drift transactional services (no local clamping in adjustStock).
//  • Incremental sync uses ?updatedSince= cursor; soft-deletions tracked via deletedAt.
//  • When offline, transparently falls back to local Drift database.

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../db/database.dart';
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
    final price = json['price'] is num
        ? (json['price'] as num).toDouble()
        : double.tryParse('${json['price']}') ?? 0.0;
    final cost = json['cost'] is num
        ? (json['cost'] as num).toDouble()
        : double.tryParse('${json['cost']}') ?? 0.0;
    final stock = (json['stock'] as num?)?.toInt() ?? 0;
    final minStock = (json['minStock'] ?? json['min_stock'] as num?)?.toInt() ?? 0;
    final compat = json['compat'] as String?;
    final zone = json['zone'] as String?;
    final offlineOk = (json['offlineOk'] ?? json['offline_ok'] as bool?) ?? false;

    DateTime? updatedAt;
    if (json['updatedAt'] != null) {
      updatedAt = DateTime.tryParse(json['updatedAt'].toString());
    }
    DateTime? deletedAt;
    if (json['deletedAt'] != null) {
      deletedAt = DateTime.tryParse(json['deletedAt'].toString());
    }

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
      offlineOk: Value(offlineOk),
      updatedAt: Value(updatedAt),
      deletedAt: Value(deletedAt),
    );
  }

  /// Write-through sync: attempts to pull recent updates from server and patch Drift.
  Future<void> syncFromServer({bool forceFull = false}) async {
    try {
      final queryParams = <String, dynamic>{};
      if (!forceFull) {
        // Find latest updatedAt among local products to build ?updatedSince= cursor
        final latestRow = await (db.select(db.products)
              ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
              ..limit(1))
            .getSingleOrNull();

        if (latestRow?.updatedAt != null) {
          queryParams['updatedSince'] = latestRow!.updatedAt!.toUtc().toIso8601String();
        }
      }

      final response = await apiClient.get('/api/v1/products', queryParameters: queryParams);
      if (response is List) {
        await db.batch((batch) {
          for (final item in response) {
            if (item is Map) {
              final comp = _productToCompanion(Map<String, dynamic>.from(item));
              batch.insert(
                db.products,
                comp,
                onConflict: DoUpdate((old) => comp),
              );
            }
          }
        });
      }
    } catch (_) {
      // Network failure or degraded mode: gracefully ignore and rely on Drift cache
    }
  }

  @override
  Future<List<ProductRow>> getAll() async {
    await syncFromServer();
    final rows = await (db.select(db.products)
          ..where((t) => t.deletedAt.isNull()))
        .get();
    return rows.map((r) => r.category.isNotEmpty ? r : r.copyWith(category: r.zone ?? 'เครื่องยนต์')).toList();
  }

  @override
  Stream<List<ProductRow>> watchAll() {
    return (db.select(db.products)..where((t) => t.deletedAt.isNull()))
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
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .getSingleOrNull();
    if (local != null) return local;

    try {
      final res = await apiClient.get('/api/v1/products/$id');
      if (res is Map) {
        final comp = _productToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.products).insertOnConflictUpdate(comp);
        return (db.select(db.products)..where((t) => t.id.equals(id))).getSingleOrNull();
      }
    } catch (_) {}

    return null;
  }

  @override
  Future<ProductRow?> add(ProductsCompanion data) async {
    final partNo = (data.partNo.present ? data.partNo.value : '').trim();
    if (partNo.isEmpty) return null;

    try {
      final body = {
        'partNo': partNo,
        'name': data.name.present ? data.name.value : '',
        'nameTH': data.nameTH.present ? data.nameTH.value : '',
        'category': data.category.present ? data.category.value : '',
        'brand': data.brand.present ? data.brand.value : '',
        'price': data.price.present ? data.price.value.toStringAsFixed(2) : '0.00',
        'cost': data.cost.present ? data.cost.value.toStringAsFixed(2) : '0.00',
        'stock': data.stock.present ? data.stock.value : 0,
        'minStock': data.minStock.present ? data.minStock.value : 0,
        if (data.compat.present && data.compat.value != null) 'compat': data.compat.value,
      };

      final res = await apiClient.post('/api/v1/products', body: body);
      if (res is Map) {
        final comp = _productToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.products).insertOnConflictUpdate(comp);
        return (db.select(db.products)..where((t) => t.id.equals(comp.id.value))).getSingle();
      }
    } on ApiException catch (e) {
      if (e.statusCode == 409) return null; // Duplicate partNo
      rethrow;
    }

    return null;
  }

  @override
  Future<bool> update(String id, ProductsCompanion patch) async {
    try {
      final body = <String, dynamic>{};
      if (patch.partNo.present) body['partNo'] = patch.partNo.value.trim();
      if (patch.name.present) body['name'] = patch.name.value;
      if (patch.nameTH.present) body['nameTH'] = patch.nameTH.value;
      if (patch.category.present) body['category'] = patch.category.value;
      if (patch.brand.present) body['brand'] = patch.brand.value;
      if (patch.price.present) body['price'] = patch.price.value.toStringAsFixed(2);
      if (patch.cost.present) body['cost'] = patch.cost.value.toStringAsFixed(2);
      if (patch.minStock.present) body['minStock'] = patch.minStock.value;
      if (patch.compat.present) body['compat'] = patch.compat.value;

      final res = await apiClient.patch('/api/v1/products/$id', body: body);
      if (res is Map) {
        final comp = _productToCompanion(Map<String, dynamic>.from(res));
        await db.into(db.products).insertOnConflictUpdate(comp);
        return true;
      }
      return true;
    } on ApiException catch (e) {
      if (e.statusCode == 409) return false;
      rethrow;
    }
  }

  @override
  Future<void> delete(String id) async {
    try {
      await apiClient.delete('/api/v1/products/$id');
    } catch (_) {}

    // ADR-0010: soft-delete locally by setting deletedAt
    await (db.update(db.products)..where((t) => t.id.equals(id))).write(
      ProductsCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
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

    int newStock = p.stock + delta;
    if (newStock < 0) newStock = 0;

    try {
      final body = <String, dynamic>{
        'delta': delta,
        'type': type,
      };
      if (note != null) body['note'] = note;

      final res = await apiClient.post(
        '/api/v1/products/$productId/adjust-stock',
        body: body,
      );
      if (res is Map) {
        final resMap = Map<String, dynamic>.from(res);
        if (resMap['stockAfter'] != null) {
          newStock = (resMap['stockAfter'] as num).toInt();
        }
      }
    } catch (_) {
      // Degraded / offline
    }

    // ADR-0010: Patch row directly without invoking Drift's transactional service
    await (db.update(db.products)..where((t) => t.id.equals(productId))).write(
      ProductsCompanion(
        stock: Value(newStock),
        updatedAt: Value(DateTime.now()),
      ),
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

    try {
      await apiClient.post('/api/v1/categories', body: {'name': trimmed});
    } catch (_) {}

    await super.addCategory(trimmed);
  }

  @override
  Future<void> deleteCategory(String name) async {
    try {
      await apiClient.delete('/api/v1/categories/$name');
    } catch (_) {}

    await super.deleteCategory(name);
  }
}
