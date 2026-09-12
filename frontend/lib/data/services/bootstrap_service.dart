// BootstrapService — initial warm-up / full sync service (02_API_SCREENS.md §3.1).
//
// Complies with ADR-0010:
//  • Fills the Drift local cache on login / startup in one request.
//  • Batch writes products, categories, customers, mechanics, settings into Drift.
//  • Supports fallback to individual GETs if /bootstrap is not yet deployed on server.

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../db/database.dart';
import '../repositories/api_customers_repository.dart';
import '../repositories/api_mechanics_repository.dart';
import '../repositories/api_products_repository.dart';

class BootstrapService {
  final AppDatabase db;
  final ApiClient apiClient;

  BootstrapService({required this.db, required this.apiClient});

  Future<bool> bootstrap() async {
    try {
      final res = await apiClient.get('/api/v1/bootstrap');
      if (res is Map) {
        await _applyBootstrapPayload(Map<String, dynamic>.from(res));
        return true;
      }
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        // If /bootstrap endpoint is not ready, fall back to individual syncs
        try {
          final productsRepo = ApiProductsRepository(db, apiClient);
          final customersRepo = ApiCustomersRepository(db, apiClient);
          final mechanicsRepo = ApiMechanicsRepository(db, apiClient);

          await Future.wait([
            productsRepo.syncFromServer(forceFull: true),
            productsRepo.getCategories(),
            customersRepo.syncFromServer(),
            mechanicsRepo.syncFromServer(),
          ]);
          return true;
        } catch (_) {}
      }
    } catch (_) {
      // Complete network failure
    }

    return false;
  }

  Future<void> _applyBootstrapPayload(Map<String, dynamic> data) async {
    await db.batch((batch) {
      // 1. Categories
      final categories = data['categories'];
      if (categories is List) {
        for (var i = 0; i < categories.length; i++) {
          final item = categories[i];
          final name = item is Map ? item['name'] as String? : item.toString();
          if (name != null && name.isNotEmpty) {
            batch.insert(
              db.categories,
              CategoriesCompanion.insert(name: name, position: i),
              onConflict: DoUpdate((old) => CategoriesCompanion(position: Value(i))),
            );
          }
        }
      }

      // 2. Products
      final products = data['products'];
      if (products is List) {
        for (final item in products) {
          if (item is Map) {
            final comp = _parseProduct(Map<String, dynamic>.from(item));
            batch.insert(
              db.products,
              comp,
              onConflict: DoUpdate((old) => comp),
            );
          }
        }
      }

      // 3. Customers
      final customers = data['customers'];
      if (customers is List) {
        for (final item in customers) {
          if (item is Map) {
            final comp = _parseCustomer(Map<String, dynamic>.from(item));
            batch.insert(
              db.customers,
              comp,
              onConflict: DoUpdate((old) => comp),
            );
          }
        }
      }

      // 4. Mechanics
      final mechanics = data['mechanics'];
      if (mechanics is List) {
        for (final item in mechanics) {
          if (item is Map) {
            final comp = _parseMechanic(Map<String, dynamic>.from(item));
            batch.insert(
              db.mechanics,
              comp,
              onConflict: DoUpdate((old) => comp),
            );
          }
        }
      }

      // 5. Settings
      final settings = data['settings'];
      if (settings is Map) {
        final settingsMap = Map<String, dynamic>.from(settings);
        final shopName = (settingsMap['shopName'] ?? settingsMap['shop_name'] ?? 'ร้านศรีสุราษฎร์การช่าง') as String;
        final shopNameEN = (settingsMap['shopNameEN'] ?? settingsMap['shop_name_en'] ?? 'Srisurart Autopart') as String;
        final taxRate = settingsMap['taxRate'] != null
            ? (settingsMap['taxRate'] as num).toDouble()
            : (settingsMap['vatRate'] != null ? (settingsMap['vatRate'] as num).toDouble() : 7.0);

        batch.insert(
          db.settingsRow,
          SettingsRowCompanion(
            id: const Value(0),
            shopName: Value(shopName),
            shopNameEN: Value(shopNameEN),
            taxRate: Value(taxRate),
            address: Value(settingsMap['address'] as String?),
            phone: Value(settingsMap['phone'] as String?),
            cashierName: Value((settingsMap['cashierName'] ?? settingsMap['cashier_name']) as String?),
            taxId: Value((settingsMap['taxId'] ?? settingsMap['tax_id']) as String?),
            branchNo: Value((settingsMap['branchNo'] ?? settingsMap['branch_no']) as String?),
          ),
          onConflict: DoUpdate((old) => SettingsRowCompanion(
                shopName: Value(shopName),
                shopNameEN: Value(shopNameEN),
                taxRate: Value(taxRate),
                address: Value(settingsMap['address'] as String?),
                phone: Value(settingsMap['phone'] as String?),
              )),
        );
      }
    });
  }

  ProductsCompanion _parseProduct(Map<String, dynamic> json) {
    return ProductsCompanion(
      id: Value(json['id'] as String),
      partNo: Value((json['partNo'] ?? json['part_no'] ?? '') as String),
      name: Value((json['name'] ?? '') as String),
      nameTH: Value((json['nameTH'] ?? json['name_t_h'] ?? json['nameTh'] ?? '') as String),
      category: Value((json['category'] ?? '') as String),
      brand: Value((json['brand'] ?? '') as String),
      price: Value(json['price'] is num ? (json['price'] as num).toDouble() : double.tryParse('${json['price']}') ?? 0.0),
      cost: Value(json['cost'] is num ? (json['cost'] as num).toDouble() : double.tryParse('${json['cost']}') ?? 0.0),
      stock: Value((json['stock'] as num?)?.toInt() ?? 0),
      minStock: Value((json['minStock'] ?? json['min_stock'] as num?)?.toInt() ?? 0),
      compat: Value(json['compat'] as String?),
      zone: Value(json['zone'] as String?),
      offlineOk: Value((json['offlineOk'] ?? json['offline_ok'] as bool?) ?? false),
      updatedAt: Value(json['updatedAt'] != null ? DateTime.tryParse(json['updatedAt'].toString()) : null),
      deletedAt: Value(json['deletedAt'] != null ? DateTime.tryParse(json['deletedAt'].toString()) : null),
    );
  }

  CustomersCompanion _parseCustomer(Map<String, dynamic> json) {
    return CustomersCompanion(
      id: Value(json['id'] as String),
      code: Value((json['code'] ?? '') as String),
      name: Value((json['name'] ?? '') as String),
      nameTH: Value((json['nameTH'] ?? json['name_t_h'] ?? json['nameTh'] ?? '') as String),
      phone: Value(json['phone'] as String?),
      address: Value(json['address'] as String?),
      points: Value((json['points'] as num?)?.toInt() ?? 0),
      totalSpend: Value(json['totalSpend'] is num ? (json['totalSpend'] as num).toDouble() : double.tryParse('${json['totalSpend']}') ?? 0.0),
      createdAt: Value((json['createdAt'] ?? json['created_at'] ?? '') as String),
      updatedAt: Value(json['updatedAt'] != null ? DateTime.tryParse(json['updatedAt'].toString()) : null),
      deletedAt: Value(json['deletedAt'] != null ? DateTime.tryParse(json['deletedAt'].toString()) : null),
    );
  }

  MechanicsCompanion _parseMechanic(Map<String, dynamic> json) {
    double parseNum(dynamic val) {
      if (val is num) return val.toDouble();
      if (val is String) return double.tryParse(val) ?? 0.0;
      return 0.0;
    }

    return MechanicsCompanion(
      id: Value(json['id'] as String),
      code: Value((json['code'] ?? '') as String),
      name: Value((json['name'] ?? '') as String),
      nameTH: Value((json['nameTH'] ?? json['name_t_h']) as String?),
      nickname: Value(json['nickname'] as String?),
      shopName: Value((json['shopName'] ?? json['shop_name']) as String?),
      phone: Value(json['phone'] as String?),
      note: Value(json['note'] as String?),
      creditLimit: Value(parseNum(json['creditLimit'] ?? json['credit_limit'])),
      creditBalance: Value(parseNum(json['creditBalance'] ?? json['credit_balance'])),
      totalSales: Value(parseNum(json['totalSales'] ?? json['total_sales'])),
      totalCredit: Value(parseNum(json['totalCredit'] ?? json['total_credit'])),
      totalDiscount: Value(parseNum(json['totalDiscount'] ?? json['total_discount'])),
      totalMarkup: Value(parseNum(json['totalMarkup'] ?? json['total_markup'])),
      createdAt: Value((json['createdAt'] ?? json['created_at'] ?? '') as String),
      updatedAt: Value(json['updatedAt'] != null ? DateTime.tryParse(json['updatedAt'].toString()) : null),
      deletedAt: Value(json['deletedAt'] != null ? DateTime.tryParse(json['deletedAt'].toString()) : null),
    );
  }
}
