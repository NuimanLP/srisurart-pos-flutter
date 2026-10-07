// Client → server REQUEST contract (ci/server-contract-gates, 2026-10-03).
//
// Why: on 2026-10-03 the till called `POST /quotes/:id/convert` with NO body
// while the server required one — a 400 that no test caught, because each side
// was tested only against its own fake. This file is the client half of the
// cure: it drives every online write the API build makes through the REAL
// `ApiClient` (so the wire encoding is the real one) over a recording
// `MockClient`, and pins what went on the wire — method, path, body, and
// whether an `Idempotency-Key` was sent — as JSON fixtures in
// `docs/Backend_design/fixtures/client-requests/`.
//
// The server half, `server/test/client-request-fixtures.e2e-spec.ts`, replays
// every fixture through the real Nest app (real guards, real parsers, real
// Postgres) and fails on a 400, a 5xx, or a route the server does not have.
//
// The fixtures can never drift from the code: this test fails when what the
// client sends differs from the committed file. Regenerate with
//
//   UPDATE_CLIENT_REQUEST_FIXTURES=1 flutter test test/contract/client_requests_contract_test.dart
//
// and commit the result — the server job then checks the new shape.
//
// Ids are fixed UUIDs (`contractIds`, from `testId('ct-product-1')`, …) that the server spec seeds; ids and
// timestamps the client mints itself are compared by shape, not value.
//
// 🔴 Where a repository takes a free string from its screen (payment method,
// stock-adjust type, refund method), a scenario must pass the value that
// screen really passes — the fixture is only as true as its inputs.
//
// Not covered here: `POST /sync/push` (its own fixtures, `fixtures/sync-push/`)
// and reads (`GET`).

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api/api_returns_repository.dart';
import 'package:srisurart_pos/data/repositories/api/api_sales_repository.dart';
import 'package:srisurart_pos/data/repositories/api/api_shifts_repository.dart';
import 'package:srisurart_pos/data/repositories/api_customers_repository.dart';
import 'package:srisurart_pos/data/repositories/api_mechanics_repository.dart';
import 'package:srisurart_pos/data/repositories/api_products_repository.dart';
import 'package:srisurart_pos/data/repositories/api_purchase_orders_repository.dart';
import 'package:srisurart_pos/data/repositories/api_quotes_repository.dart';
import 'package:srisurart_pos/data/repositories/api_settings_repository.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/repositories/devices_repository.dart';
import 'package:srisurart_pos/data/repositories/offline_pin_repository.dart';
import 'package:srisurart_pos/data/repositories/owner_import_repository.dart';
import 'package:srisurart_pos/data/repositories/returns_repository.dart';
import 'package:srisurart_pos/data/repositories/review_items_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/data/repositories/shifts_repository.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/data/sync/sync_service.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';

import '../support/test_ids.dart';

/// Where the fixtures live, relative to `frontend/` (the `flutter test` cwd).
const _fixturesDir = '../docs/Backend_design/fixtures/client-requests';

// Sentinel ids. The server spec seeds a row under each of these before it
// replays a fixture, so a route that looks its row up first still reaches the
// body parser instead of answering 404.
final _product = contractIds['product']!;
final _customer = contractIds['customer']!;
final _mechanic = contractIds['mechanic']!;
final _quote = contractIds['quote']!;
final _po = contractIds['po']!;
final _sale = contractIds['sale']!;
final _device = contractIds['device']!;
final _review = contractIds['review']!;
final _offlineCustomer = testId('ct-customer-offline');
final _offlineOp = testId('ct-op-1');
const _category = 'ct-category';
const _username = 'ct-owner';
const _password = 'ct-password-1';
const _refreshToken = 'ct-refresh-token';
const _pwChangeToken = 'ct-pwchange-token';
const _deviceToken = 'ct-device-token';

/// One request the client put on the wire.
class _Recorded {
  _Recorded(this.method, this.path, this.idempotencyKey, this.authorization, this.body);
  final String method;
  final String path;
  final bool idempotencyKey;

  /// `bearer` (the stored session), `custom` (a token the caller passed, e.g.
  /// the pwchange token), or `none` (`skipAuth`).
  final String authorization;
  final Object? body;

  Map<String, Object?> toJson() => {
        'method': method,
        'path': path,
        'idempotencyKey': idempotencyKey,
        'authorization': authorization,
        'body': body,
      };
}

class _MemTokens implements TokenStorage {
  String? access = 'ct-access-token';
  String? refresh = _refreshToken;
  String? device;
  AuthUser? user;
  @override
  Future<String?> getAccessToken() async => access;
  @override
  Future<void> setAccessToken(String? t) async => access = t;
  @override
  Future<String?> getRefreshToken() async => refresh;
  @override
  Future<void> setRefreshToken(String? t) async => refresh = t;
  @override
  Future<String?> getDeviceToken() async => device;
  @override
  Future<void> setDeviceToken(String? t) async => device = t;
  @override
  Future<AuthUser?> getUser() async => user;
  @override
  Future<void> setUser(AuthUser? u) async => user = u;
  @override
  Future<void> clearAuthTokens() async {
    access = null;
    refresh = null;
    user = null;
  }

  @override
  Future<void> clearAll() async {
    await clearAuthTokens();
    device = null;
  }
}

/// Everything one scenario needs: a fresh in-memory Drift with the sentinel
/// rows, and an `ApiClient` whose transport records instead of sending.
class _World {
  _World(this.db, this.api, this.tokens, this.recorded);
  final AppDatabase db;
  final ApiClient api;
  final _MemTokens tokens;
  final List<_Recorded> recorded;
}

Future<_World> _newWorld() async {
  final db = AppDatabase(NativeDatabase.memory(), seedDemoData: false);
  final recorded = <_Recorded>[];
  final tokens = _MemTokens();
  final client = MockClient((req) async {
    final auth = req.headers['Authorization'] ?? req.headers['authorization'];
    recorded.add(_Recorded(
      req.method,
      req.url.path,
      (req.headers['Idempotency-Key'] ?? req.headers['idempotency-key']) != null,
      auth == null
          ? 'none'
          : auth == 'Bearer ${tokens.access}'
              ? 'bearer'
              : 'custom',
      req.body.isEmpty ? null : jsonDecode(req.body),
    ));
    // A bare success. Most callers then fail to read the reply they expected,
    // which is fine: the request is already recorded, and nothing here tests
    // how a reply is handled.
    return http.Response('{"status":"success","data":{}}', 200,
        headers: {'content-type': 'application/json'});
  });
  final api = ApiClient(baseUrl: 'http://contract.test', httpClient: client, tokenStorage: tokens);
  await _seedDrift(db);
  return _World(db, api, tokens, recorded);
}

Future<void> _seedDrift(AppDatabase db) async {
  // A fixed date is safe here: these rows only satisfy local preconditions; no RC/CN
  // number or period derived from it reaches a fixture (online writes are server-numbered).
  final now = DateTime.utc(2026, 10, 3, 3);
  await db.into(db.products).insertOnConflictUpdate(ProductsCompanion.insert(
        id: _product,
        partNo: 'CT-001',
        name: 'Contract part',
        nameTH: 'อะไหล่ทดสอบ',
        category: 'อื่นๆ',
        brand: 'TEST',
        price: 100,
        cost: 60,
        stock: 50,
        minStock: 1,
      ));
  await db.into(db.customers).insertOnConflictUpdate(CustomersCompanion.insert(
        id: _customer,
        code: 'CT-C1',
        name: 'Contract customer',
        nameTH: 'ลูกค้าทดสอบ',
        createdAt: now.toIso8601String(),
      ));
  await db.into(db.mechanics).insertOnConflictUpdate(MechanicsCompanion.insert(
        id: _mechanic,
        code: 'CT-M1',
        name: 'Contract mechanic',
        creditLimit: const Value(100000),
        creditBalance: const Value(500),
        createdAt: now.toIso8601String(),
      ));
  await db.into(db.shifts).insertOnConflictUpdate(ShiftsCompanion.insert(
        id: 'ct-shift-1',
        dateStr: '2026-10-03',
        startingCash: 1000,
        openedAt: now,
        isActive: const Value(true),
      ));
  await db.into(db.quotes).insertOnConflictUpdate(QuotesCompanion.insert(
        id: _quote,
        quoteNo: 'QT-CT-1',
        date: now,
        validUntil: now.add(const Duration(days: 30)),
      ));
  await db.into(db.quoteItems).insert(QuoteItemsCompanion.insert(
        quoteId: _quote,
        productId: Value(_product),
        name: 'Contract part',
        qty: 1,
        price: 100,
      ));
  await db.into(db.purchaseOrders).insertOnConflictUpdate(PurchaseOrdersCompanion.insert(
        id: _po,
        poNo: 'PO-CT-1',
        supplier: 'Contract supplier',
        createdAt: now,
      ));
  await db.into(db.poItems).insert(PoItemsCompanion.insert(
        poId: _po,
        partNo: 'CT-001',
        name: 'Contract part',
        qty: 2,
        cost: 60,
      ));
  await db.into(db.sales).insertOnConflictUpdate(SalesCompanion.insert(
        id: _sale,
        receiptNo: 'RC-CT-1',
        subtotal: 200,
        total: 200,
        paymentMethod: 'เงินสด',
        date: now,
        shiftId: const Value('ct-shift-1'),
      ));
  await db.into(db.saleItems).insert(SaleItemsCompanion.insert(
        saleId: _sale,
        productId: _product,
        name: 'Contract part',
        qty: 2,
        price: 100,
      ));
}

ApiSalesRepository _sales(_World w) => ApiSalesRepository(
      api: w.api,
      db: w.db,
      drift: SalesRepository(w.db),
    );

/// One online write, as a caller would make it.
class _Scenario {
  const _Scenario(this.name, this.caller, this.routes, this.run);

  /// Fixture file name (without `.json`).
  final String name;

  /// The method that sends it — for the reader of a failing fixture.
  final String caller;

  /// The route template each recorded request must match, in order — e.g.
  /// `PATCH /api/v1/quotes/:id`. Checked against the recorded path, and used by
  /// the inventory test below to prove every write call site has a scenario.
  final List<String> routes;
  final Future<void> Function(_World w) run;
}

final _scenarios = <_Scenario>[
  // ── products / categories ────────────────────────────────────────────────
  _Scenario('products.create', 'ApiProductsRepository.add', ['POST /api/v1/products'], (w) async {
    await ApiProductsRepository(w.db, w.api).add(const ProductsCompanion(
      partNo: Value('CT-NEW-1'),
      name: Value('New part'),
      nameTH: Value('อะไหล่ใหม่'),
      category: Value('อื่นๆ'),
      brand: Value('TEST'),
      price: Value(150),
      cost: Value(90),
      stock: Value(5),
      minStock: Value(1),
    ));
  }),
  _Scenario('products.update', 'ApiProductsRepository.update', ['PATCH /api/v1/products/:id'], (w) async {
    await ApiProductsRepository(w.db, w.api)
        .update(_product, const ProductsCompanion(name: Value('Renamed part'), price: Value(120)));
  }),
  _Scenario('products.delete', 'ApiProductsRepository.delete', ['DELETE /api/v1/products/:id'], (w) async {
    await ApiProductsRepository(w.db, w.api).delete(_product);
  }),
  _Scenario('products.adjust-stock', 'ApiProductsRepository.adjustStock', ['POST /api/v1/products/:id/adjust-stock'],
      (w) async {
    // The type string products_screen.dart `_AdjustStockDialog._save` passes.
    await ApiProductsRepository(w.db, w.api).adjustStock(_product, 3, 'adjustment-in', 'นับสต็อก');
  }),
  _Scenario('categories.create', 'ApiProductsRepository.addCategory', ['POST /api/v1/categories'], (w) async {
    await ApiProductsRepository(w.db, w.api).addCategory('หมวดใหม่');
  }),
  _Scenario('categories.delete', 'ApiProductsRepository.deleteCategory', ['DELETE /api/v1/categories/:name'],
      (w) async {
    await ApiProductsRepository(w.db, w.api).deleteCategory(_category);
  }),

  // ── customers ────────────────────────────────────────────────────────────
  _Scenario('customers.create', 'ApiCustomersRepository.addCustomer', ['POST /api/v1/customers'], (w) async {
    await ApiCustomersRepository(w.db, w.api).addCustomer(const CustomersCompanion(
      name: Value('New customer'),
      nameTH: Value('ลูกค้าใหม่'),
      phone: Value('0800000000'),
    ));
  }),
  _Scenario('customers.update', 'ApiCustomersRepository.updateCustomer', ['PATCH /api/v1/customers/:id'],
      (w) async {
    await ApiCustomersRepository(w.db, w.api)
        .updateCustomer(_customer, const CustomersCompanion(name: Value('Renamed customer'), phone: Value('0811111111')));
  }),
  _Scenario('customers.delete', 'ApiCustomersRepository.deleteCustomer', ['DELETE /api/v1/customers/:id'],
      (w) async {
    await ApiCustomersRepository(w.db, w.api).deleteCustomer(_customer);
  }),

  // ── mechanics ────────────────────────────────────────────────────────────
  _Scenario('mechanics.create', 'ApiMechanicsRepository.addMechanic', ['POST /api/v1/mechanics'], (w) async {
    await ApiMechanicsRepository(w.db, w.api).addMechanic(const MechanicsCompanion(
      name: Value('New mechanic'),
      nickname: Value('ช่างใหม่'),
      phone: Value('0822222222'),
      creditLimit: Value(5000),
    ));
  }),
  _Scenario('mechanics.update', 'ApiMechanicsRepository.updateMechanic', ['PATCH /api/v1/mechanics/:id'],
      (w) async {
    await ApiMechanicsRepository(w.db, w.api)
        .updateMechanic(_mechanic, const MechanicsCompanion(name: Value('Renamed mechanic'), creditLimit: Value(8000)));
  }),
  _Scenario('mechanics.delete', 'ApiMechanicsRepository.deleteMechanic', ['DELETE /api/v1/mechanics/:id'],
      (w) async {
    await ApiMechanicsRepository(w.db, w.api).deleteMechanic(_mechanic);
  }),
  _Scenario('mechanics.credit-payment', 'ApiMechanicsRepository.addCreditPayment',
      ['POST /api/v1/mechanics/:id/credit-payments'], (w) async {
    await ApiMechanicsRepository(w.db, w.api)
        .addCreditPayment(mechanicId: _mechanic, amount: 200, paymentMethod: 'เงินสด', note: 'ชำระบางส่วน');
  }),

  // ── purchase orders ──────────────────────────────────────────────────────
  _Scenario('purchase-orders.create', 'ApiPurchaseOrdersRepository.savePO', ['POST /api/v1/purchase-orders'],
      (w) async {
    await ApiPurchaseOrdersRepository(w.db, w.api).savePO(const PoInput(
      supplier: 'Contract supplier',
      items: [PoLineInput(partNo: 'CT-001', name: 'Contract part', qty: 4, cost: 55)],
    ));
  }),
  _Scenario('purchase-orders.receive', 'ApiPurchaseOrdersRepository.receivePO',
      ['POST /api/v1/purchase-orders/:id/receive'], (w) async {
    await ApiPurchaseOrdersRepository(w.db, w.api).receivePO(_po);
  }),
  _Scenario('purchase-orders.cancel', 'ApiPurchaseOrdersRepository.cancelPO',
      ['POST /api/v1/purchase-orders/:id/cancel'], (w) async {
    await ApiPurchaseOrdersRepository(w.db, w.api).cancelPO(_po);
  }),
  _Scenario('purchase-orders.delete', 'ApiPurchaseOrdersRepository.deletePO', ['DELETE /api/v1/purchase-orders/:id'],
      (w) async {
    await ApiPurchaseOrdersRepository(w.db, w.api).deletePO(_po);
  }),

  // ── quotes ───────────────────────────────────────────────────────────────
  _Scenario('quotes.create', 'ApiQuotesRepository.saveQuote', ['POST /api/v1/quotes'], (w) async {
    await ApiQuotesRepository(w.db, w.api).saveQuote(QuoteInput(
      subtotal: 200,
      discount: 0,
      total: 200,
      customerName: 'ลูกค้าใบเสนอราคา',
      customerPhone: '0833333333',
      notes: 'ทดสอบ',
      validDays: 30,
      items: [QuoteLineInput(productId: _product, name: 'Contract part', qty: 2, price: 100)],
    ));
  }),
  _Scenario('quotes.update', 'ApiQuotesRepository.updateQuote', ['PATCH /api/v1/quotes/:id'], (w) async {
    await ApiQuotesRepository(w.db, w.api).updateQuote(
        _quote, const QuotesCompanion(customerName: Value('ลูกค้าแก้ไข'), notes: Value('แก้หมายเหตุ')));
  }),
  _Scenario('quotes.delete', 'ApiQuotesRepository.deleteQuote', ['DELETE /api/v1/quotes/:id'], (w) async {
    await ApiQuotesRepository(w.db, w.api).deleteQuote(_quote);
  }),
  _Scenario('quotes.duplicate', 'ApiQuotesRepository.duplicateQuote', ['POST /api/v1/quotes/:id/duplicate'],
      (w) async {
    await ApiQuotesRepository(w.db, w.api).duplicateQuote(_quote);
  }),
  _Scenario('quotes.purge', 'ApiQuotesRepository.purgeOldQuotes', ['POST /api/v1/quotes/purge'], (w) async {
    await ApiQuotesRepository(w.db, w.api).purgeOldQuotes(olderThanDays: 90);
  }),

  // ── settings ─────────────────────────────────────────────────────────────
  _Scenario('settings.update', 'ApiSettingsRepository.updateSettings', ['PATCH /api/v1/settings'], (w) async {
    await ApiSettingsRepository(w.db, w.api).updateSettings(const SettingsRowCompanion(
      shopName: Value('ร้านทดสอบสัญญา'),
      phone: Value('021234567'),
      quoteValidDays: Value(15),
    ));
  }),

  // ── sales / returns ──────────────────────────────────────────────────────
  _Scenario('sales.create-cash', 'ApiSalesRepository.saveSale', ['POST /api/v1/sales'], (w) async {
    await _sales(w).saveSale(SaleInput(
      subtotal: 200,
      discount: 0,
      total: 200,
      paymentMethod: 'เงินสด',
      customerId: _customer,
      customerName: 'Contract customer',
      items: [SaleLineInput(productId: _product, name: 'Contract part', qty: 2, price: 100, partNo: 'CT-001')],
    ));
  }),
  _Scenario('sales.create-mechanic-credit', 'ApiSalesRepository.saveSale', ['POST /api/v1/sales'], (w) async {
    await _sales(w).saveSale(SaleInput(
      subtotal: 200,
      discount: 10,
      total: 190,
      paymentMethod: 'เครดิตช่าง',
      mechanicId: _mechanic,
      mechanicName: 'Contract mechanic',
      mechanicDelta: -10,
      overrideCreditLimit: true,
      items: [SaleLineInput(productId: _product, name: 'Contract part', qty: 2, price: 100, partNo: 'CT-001')],
    ));
  }),
  _Scenario('sales.create-from-quote', 'ApiSalesRepository.saveSale', ['POST /api/v1/sales'], (w) async {
    // #27: a quote is converted only by the bill sold from it.
    await _sales(w).saveSale(SaleInput(
      subtotal: 100,
      discount: 0,
      total: 100,
      paymentMethod: 'โอน/QR', // checkout_screen.dart's own label
      quoteId: _quote,
      items: [SaleLineInput(productId: _product, name: 'Contract part', qty: 1, price: 100)],
    ));
  }),
  _Scenario('returns.create', 'ApiReturnsRepository.createReturn', ['POST /api/v1/returns'], (w) async {
    await ApiReturnsRepository(api: w.api, db: w.db, drift: ReturnsRepository(w.db)).createReturn(ReturnInput(
      saleId: _sale,
      refundMethod: 'เงินสด',
      reason: 'ของชำรุด',
      items: [ReturnLineInput(productId: _product, name: 'Contract part', qty: 1, price: 100, originalQty: 2)],
    ));
  }),

  // ── shifts ───────────────────────────────────────────────────────────────
  _Scenario('shifts.open', 'ApiShiftsRepository.openShift', ['POST /api/v1/shifts/open'], (w) async {
    await ApiShiftsRepository(api: w.api, db: w.db, drift: ShiftsRepository(w.db)).openShift(1500);
  }),
  _Scenario('shifts.close', 'ApiShiftsRepository.closeShift', ['POST /api/v1/shifts/close'], (w) async {
    await ApiShiftsRepository(api: w.api, db: w.db, drift: ShiftsRepository(w.db)).closeShift(1234.5);
  }),
  _Scenario('shifts.drawer-entry', 'ApiShiftsRepository.addDrawerEntry', ['POST /api/v1/shifts/current/entries'],
      (w) async {
    await ApiShiftsRepository(api: w.api, db: w.db, drift: ShiftsRepository(w.db))
        .addDrawerEntry('out', 50, 'ค่าน้ำแข็ง');
  }),

  // ── auth / devices / review items ────────────────────────────────────────
  _Scenario('auth.login', 'AuthRepository.login', ['POST /api/v1/auth/token'], (w) async {
    await AuthRepository(apiClient: w.api, tokenStorage: w.tokens).login(username: _username, password: _password);
  }),
  _Scenario('auth.login-enrolled', 'AuthRepository.login', ['POST /api/v1/auth/token'], (w) async {
    // An enrolled till: the stored device token rides in the body (ADR-0004).
    w.tokens.device = _deviceToken;
    await AuthRepository(apiClient: w.api, tokenStorage: w.tokens).login(username: _username, password: _password);
  }),
  _Scenario('auth.offline-pin-verify', 'OfflinePinRepository.setPin', ['POST /api/v1/auth/token'], (w) async {
    await OfflinePinRepository(db: w.db, tokenStorage: w.tokens, apiClient: w.api).setPin(
      password: _password,
      newPin: '4321',
      username: _username,
      deviceId: _device,
      deviceToken: _deviceToken,
    );
  }),
  _Scenario('auth.refresh', 'AuthRepository.refresh', ['POST /api/v1/auth/refresh'], (w) async {
    await AuthRepository(apiClient: w.api, tokenStorage: w.tokens).refresh();
  }),
  _Scenario('auth.change-password', 'AuthRepository.changePassword', ['POST /api/v1/auth/change-password'],
      (w) async {
    await AuthRepository(apiClient: w.api, tokenStorage: w.tokens)
        .changePassword(passwordChangeToken: _pwChangeToken, newPassword: 'ct-new-password-2');
  }),
  _Scenario('auth.enrol-device', 'AuthRepository.enrolDevice', ['POST /api/v1/auth/device'], (w) async {
    await AuthRepository(apiClient: w.api, tokenStorage: w.tokens).enrolDevice('ct0de001');
  }),
  _Scenario('devices.create', 'DevicesRepository.createDevice', ['POST /api/v1/devices'], (w) async {
    await DevicesRepository(w.api).createDevice(label: 'เครื่องหลังร้าน', role: 'backoffice');
  }),
  _Scenario('devices.retire', 'DevicesRepository.retireDevice', ['POST /api/v1/devices/:id/retire'], (w) async {
    await DevicesRepository(w.api).retireDevice(deviceId: _device);
  }),
  _Scenario('devices.retire-with-cash', 'DevicesRepository.retireDevice', ['POST /api/v1/devices/:id/retire'],
      (w) async {
    await DevicesRepository(w.api).retireDevice(deviceId: _device, physicalCash: 1000);
  }),
  _Scenario('review-items.mark-reviewed', 'ReviewItemsRepository.markReviewed',
      ['POST /api/v1/review-items/:id/reviewed'], (w) async {
    await ReviewItemsRepository(w.api).markReviewed(_review);
  }),
  // Settings → กู้คืนข้อมูล: the owner's own import. The server answers 202 (empty
  // shop) or 409 (the contract world already has bills) — both past the parser.
  _Scenario('backup.import', 'OwnerImportRepository.importBackup', ['POST /api/v1/backup/import'],
      (w) async {
    await OwnerImportRepository(w.api, w.db, pollInterval: Duration.zero, maxPolls: 0).importBackup({
      '__meta': {'version': 2, 'schemaVersion': 2},
      'sa_products': [
        {
          'id': _product,
          'partNo': 'CT-001',
          'name': 'Contract part',
          'nameTH': 'อะไหล่ทดสอบ',
          'category': 'อื่นๆ',
          'brand': 'TEST',
          'price': 100,
          'cost': 60,
          'stock': 50,
          'minStock': 1,
        },
      ],
    }, confirmShopName: 'ร้านทดสอบ');
  }),

  // ── sync ─────────────────────────────────────────────────────────────────
  _Scenario('sync.discard', 'SyncService.discard', ['POST /api/v1/sync/discards'], (w) async {
    // A rejected offline customer the owner gives up on.
    await w.db.into(w.db.outboxOps).insert(OutboxOpsCompanion.insert(
          opId: _offlineOp,
          idempotencyKey: 'ct-op-key-1',
          type: 'customer.create',
          payload: jsonEncode({'id': _offlineCustomer, 'name': 'Offline customer', 'nameTH': 'ลูกค้าออฟไลน์'}),
          aggregates: jsonEncode(['customer:$_offlineCustomer']),
          createdAt: DateTime.utc(2026, 10, 3, 2),
          status: 'rejected',
          lastCode: const Value('CONFLICT'),
        ));
    final sync = SyncService(db: w.db, apiClient: w.api, tokenStorage: w.tokens, autoStartHealthProbe: false);
    addTearDown(sync.dispose);
    await sync.discard(_offlineOp, 'ลูกค้าซ้ำ');
  }),
];

// ── normalisation: what may differ between two runs ─────────────────────────

final _mintedId = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
final _isoDateTime = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z?$');

Object? _normalise(Object? v) {
  if (v is String) {
    if (_mintedId.hasMatch(v)) return '<minted-id>';
    if (_isoDateTime.hasMatch(v)) return '<timestamp>';
    return v;
  }
  if (v is List) return [for (final e in v) _normalise(e)];
  if (v is Map) return {for (final e in v.entries) e.key as String: _normalise(e.value)};
  return v;
}

bool _deepEquals(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

bool _matchesRoute(String route, String method, String path) {
  final parts = route.split(' ');
  if (parts[0] != method) return false;
  final pattern = RegExp('^${parts[1].replaceAllMapped(RegExp(r':[A-Za-z]+'), (_) => '[^/]+')}\$');
  return pattern.hasMatch(path);
}

Map<String, Object?> _fixtureOf(_Scenario s, List<_Recorded> recorded) => {
      'name': s.name,
      'caller': s.caller,
      'requests': [
        for (var i = 0; i < recorded.length; i++) {'route': s.routes[i], ...recorded[i].toJson()},
      ],
    };

const _encoder = JsonEncoder.withIndent('  ');

void main() {
  final update = Platform.environment['UPDATE_CLIENT_REQUEST_FIXTURES'] == '1';
  final dir = Directory(_fixturesDir);

  group('client request fixtures', () {
    for (final s in _scenarios) {
      test(s.name, () async {
        final w = await _newWorld();
        addTearDown(w.db.close);
        try {
          await s.run(w);
        } catch (_) {
          // The bare `{}` reply usually makes the caller throw AFTER sending;
          // what matters is what was sent (checked below).
        }
        expect(w.recorded, hasLength(s.routes.length),
            reason: '${s.caller} must send exactly ${s.routes.length} request(s) — '
                'a local precondition probably stopped it before the network');
        for (var i = 0; i < s.routes.length; i++) {
          expect(_matchesRoute(s.routes[i], w.recorded[i].method, w.recorded[i].path), isTrue,
              reason: '${w.recorded[i].method} ${w.recorded[i].path} is not ${s.routes[i]}');
        }

        final fixture = _fixtureOf(s, w.recorded);
        final file = File('${dir.path}/${s.name}.json');
        if (update) {
          // Unchanged but for minted ids/timestamps: keep the committed file (no diff noise).
          if (file.existsSync() &&
              _deepEquals(_normalise(fixture), _normalise(jsonDecode(file.readAsStringSync())))) {
            return;
          }
          dir.createSync(recursive: true);
          file.writeAsStringSync('${_encoder.convert(fixture)}\n');
          return;
        }
        expect(file.existsSync(), isTrue,
            reason: 'missing ${file.path} — run with UPDATE_CLIENT_REQUEST_FIXTURES=1 and commit it');
        final committed = jsonDecode(file.readAsStringSync());
        expect(_normalise(fixture), equals(_normalise(committed)),
            reason: 'what ${s.caller} sends no longer matches ${file.path}. If the change is intended, '
                'regenerate with UPDATE_CLIENT_REQUEST_FIXTURES=1 and commit it — the server job '
                '(client-request-fixtures.e2e-spec.ts) then proves the server still accepts it.');
      });
    }

    test('no stale fixture files (every file belongs to a scenario)', () {
      if (update || !dir.existsSync()) return;
      final names = {for (final s in _scenarios) '${s.name}.json'};
      final onDisk = dir.listSync().whereType<File>().map((f) => f.uri.pathSegments.last).toSet();
      expect(onDisk.difference(names), isEmpty, reason: 'delete fixtures no scenario produces');
    });

    // The inventory: every write call site in lib/ with a literal path must be
    // exercised by some scenario, so a new write cannot ship without a fixture.
    // (A path held in a variable — `ApiShiftsRepository._send(path)` — is
    // covered by the shifts scenarios by hand.)
    test('every literal write call site in lib/ has a scenario', () {
      final call = RegExp(
        r'''\.(post|patch|put|delete)\(\s*'(/api/v1/[^']*)'|\.(post|patch|put|delete)\(\s*"(/api/v1/[^"]*)"''',
        multiLine: true,
      );
      final routes = {for (final s in _scenarios) ...s.routes};
      final missing = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        // The refresh inside ApiClient itself is the same request as AuthRepository.refresh.
        if (f.path.replaceAll('\\', '/').endsWith('core/network/api_client.dart')) continue;
        for (final m in call.allMatches(f.readAsStringSync())) {
          final method = (m.group(1) ?? m.group(3))!.toUpperCase();
          final path = (m.group(2) ?? m.group(4))!
              .replaceAll(RegExp(r'\$\{[^}]+\}'), ':p')
              .replaceAll(RegExp(r'\$[A-Za-z_]+'), ':p');
          final covered = routes.any((r) =>
              r.split(' ')[0] == method &&
              r.split(' ')[1].replaceAll(RegExp(r':[A-Za-z]+'), ':p') == path);
          if (!covered) missing.add('$method $path  (${f.path})');
        }
      }
      expect(missing, isEmpty, reason: 'add a _Scenario for each of these write calls');
    });
  });
}
