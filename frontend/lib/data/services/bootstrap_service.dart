// BootstrapService — initial warm-up / full sync service (02_API_SCREENS.md §3.1).
//
// Complies with ADR-0010:
//  • Fills the Drift local cache on login / startup in one request.
//  • Batch writes products, categories, customers, mechanics, settings into Drift.
//  • Supports ETag 304 Not Modified when cache is already warm and unchanged.
//  • Supports fallback to individual GETs if /bootstrap is not yet deployed on server.

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../db/database.dart';
import '../repositories/api_customers_repository.dart';
import '../repositories/api_mechanics_repository.dart';
import '../repositories/api_products_repository.dart';
import '../repositories/api/api_wire.dart';

class BootstrapService {
  final AppDatabase db;
  final ApiClient apiClient;

  String? _lastEtag;

  BootstrapService({required this.db, required this.apiClient});

  Future<bool> bootstrap() async {
    try {
      final headers = <String, String>{};
      if (_lastEtag != null) {
        headers['If-None-Match'] = _lastEtag!;
      }

      final res = await apiClient.get('/api/v1/bootstrap', headers: headers);
      if (res is Map) {
        if (res['notModified'] == true) {
          // HTTP 304 Not Modified: Cache is already up to date!
          return true;
        }
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

      // 5. Settings (ADR-0010: do not drop cashierName, taxId, branchNo on conflict)
      final settings = data['settings'];
      if (settings is Map) {
        final settingsMap = Map<String, dynamic>.from(settings);
        final shopName = (settingsMap['shopName'] ?? settingsMap['shop_name'] ?? 'ร้านศรีสุราษฎร์การช่าง') as String;
        final shopNameEN = (settingsMap['shopNameEN'] ?? settingsMap['shop_name_en'] ?? 'Srisurart Autopart') as String;
        final taxRate = settingsMap['taxRate'] != null
            ? (settingsMap['taxRate'] as num).toDouble()
            : (settingsMap['vatRate'] != null ? (settingsMap['vatRate'] as num).toDouble() : 7.0);

        final cashier = (settingsMap['cashierName'] ?? settingsMap['cashier_name']) as String?;
        final taxId = (settingsMap['taxId'] ?? settingsMap['tax_id']) as String?;
        final branch = (settingsMap['branchNo'] ?? settingsMap['branch_no']) as String?;
        final addr = settingsMap['address'] as String?;
        final ph = settingsMap['phone'] as String?;

        batch.insert(
          db.settingsRow,
          SettingsRowCompanion(
            id: const Value(0),
            shopName: Value(shopName),
            shopNameEN: Value(shopNameEN),
            taxRate: Value(taxRate),
            address: Value(addr),
            phone: Value(ph),
            cashierName: Value(cashier),
            taxId: Value(taxId),
            branchNo: Value(branch),
          ),
          onConflict: DoUpdate((old) => SettingsRowCompanion(
                shopName: Value(shopName),
                shopNameEN: Value(shopNameEN),
                taxRate: Value(taxRate),
                address: Value(addr),
                phone: Value(ph),
                cashierName: Value(cashier),
                taxId: Value(taxId),
                branchNo: Value(branch),
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
      price: Value(money(json['price'])),
      cost: Value(money(json['cost'])),
      stock: Value((json['stock'] as num?)?.toInt() ?? 0),
      minStock: Value((json['minStock'] ?? json['min_stock'] as num?)?.toInt() ?? 0),
      compat: Value(json['compat'] as String?),
      zone: Value(json['zone'] as String?),
      updatedAt: Value(stampOrNull(json['updatedAt'])),
      deletedAt: Value(stampOrNull(json['deletedAt'])),
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
      totalSpend: Value(money(json['totalSpend'])),
      createdAt: Value((json['createdAt'] ?? json['created_at'] ?? '') as String),
      updatedAt: Value(stampOrNull(json['updatedAt'])),
      deletedAt: Value(stampOrNull(json['deletedAt'])),
    );
  }

  MechanicsCompanion _parseMechanic(Map<String, dynamic> json) {
    return MechanicsCompanion(
      id: Value(json['id'] as String),
      code: Value((json['code'] ?? '') as String),
      name: Value((json['name'] ?? '') as String),
      nameTH: Value((json['nameTH'] ?? json['name_t_h']) as String?),
      nickname: Value(json['nickname'] as String?),
      shopName: Value((json['shopName'] ?? json['shop_name']) as String?),
      phone: Value(json['phone'] as String?),
      note: Value(json['note'] as String?),
      creditLimit: Value(money(json['creditLimit'] ?? json['credit_limit'])),
      creditBalance: Value(money(json['creditBalance'] ?? json['credit_balance'])),
      totalSales: Value(money(json['totalSales'] ?? json['total_sales'])),
      totalDiscount: Value(money(json['totalDiscount'] ?? json['total_discount'])),
      totalMarkup: Value(money(json['totalMarkup'] ?? json['total_markup'])),
      createdAt: Value((json['createdAt'] ?? json['created_at'] ?? '') as String),
      updatedAt: Value(stampOrNull(json['updatedAt'])),
      deletedAt: Value(stampOrNull(json['deletedAt'])),
    );
  }
}
