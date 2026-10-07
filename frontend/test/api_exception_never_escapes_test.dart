// CLAUDE.md binding rule: "An `ApiException` must never reach a screen —
// convert via `rethrowThai` / `rethrowServerRefusal` to a plain Thai-string
// `Exception`/`PosException`."
//
// `presentation_no_api_exception_test.dart` keeps the TYPE out of
// lib/presentation/ at the source level; this file checks the RUNTIME side:
// every public method a screen or cubit can reach through
// `repository_providers.dart` is driven against a server that answers each
// error class (4xx incl. 401, 429, 5xx, a proxy's HTML 502, 503 in-flight).
// What it throws must be one of the types the screens are written for
// (`_allowed`), never an `ApiException`, and a `PosException` must carry the
// exact text that path showed before the conversion moved into the
// repository — pinned as literals in `_replies`, not recomputed:
//  - paths that used to let the raw exception reach the screen showed
//    `ServerErrorResolver.resolveCounterError` (a 5xx → connection sentence);
//  - paths already converted by `rethrowThai` / `rethrowServerRefusal`
//    ([_keepsServerText]) showed `thaiMessage` (a 5xx → the server's text).
// The one intended visible change is on screens that printed the exception
// with `$e` (owner review, the PO screen's `_showError`): they read
// `ApiException(status: …)` and now read the same Thai sentence.
//
// The table is checked against the source: a public `Future` method a listed
// class declares or inherits fails here until it is added to [_cases] or,
// with its reason, to [_noApiCall].

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/errors/pos_exception.dart';
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
import 'package:srisurart_pos/data/services/bootstrap_service.dart';
import 'package:srisurart_pos/data/services/doc_counter_seeder.dart';
import 'package:srisurart_pos/data/storage/token_storage.dart';
import 'package:srisurart_pos/data/sync/sync_service.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';

class _MemoryTokenStorage implements TokenStorage {
  String? accessToken = 'access-1';
  String? refreshToken = 'refresh-1';
  String? deviceToken;
  AuthUser? user;

  @override
  Future<String?> getAccessToken() async => accessToken;
  @override
  Future<void> setAccessToken(String? t) async => accessToken = t;
  @override
  Future<String?> getRefreshToken() async => refreshToken;
  @override
  Future<void> setRefreshToken(String? t) async => refreshToken = t;
  @override
  Future<String?> getDeviceToken() async => deviceToken;
  @override
  Future<void> setDeviceToken(String? t) async => deviceToken = t;
  @override
  Future<AuthUser?> getUser() async => user;
  @override
  Future<void> setUser(AuthUser? u) async => user = u;
  @override
  Future<void> clearAuthTokens() async {
    accessToken = null;
    refreshToken = null;
  }

  @override
  Future<void> clearAll() async => clearAuthTokens();
}

http.Response _envelope(int status, String code, String message,
        {Map<String, String> extraHeaders = const {}}) =>
    http.Response(
      jsonEncode({
        'status': 'error',
        'error': {'code': code, 'message': message},
      }),
      status,
      headers: {'content-type': 'application/json', ...extraHeaders},
    );

const _connection = 'เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์';

typedef _Reply = ({
  int status,
  http.Response Function() response,
  // What a path that used to leak the raw exception showed for this reply.
  String counterText,
  // What a `rethrowThai` / `rethrowServerRefusal` path has always shown.
  String serverText,
});

/// Every error class a repository can be handed, with the text each kind of
/// path showed for it before the conversion moved into the repositories —
/// literals, so a drift in either conversion fails here.
final Map<String, _Reply> _replies = {
  '400 BAD_REQUEST (English message)': (
    status: 400,
    response: () => _envelope(400, 'BAD_REQUEST', 'name is required'),
    counterText: 'ข้อมูลไม่ถูกต้อง กรุณาตรวจสอบแล้วลองใหม่',
    serverText: 'ข้อมูลไม่ถูกต้อง กรุณาตรวจสอบแล้วลองใหม่',
  ),
  '401 UNAUTHENTICATED': (
    status: 401,
    response: () => _envelope(401, 'UNAUTHENTICATED', 'Unauthorized'),
    counterText: 'กรุณาเข้าสู่ระบบ',
    serverText: 'กรุณาเข้าสู่ระบบ',
  ),
  '409 coded verdict': (
    status: 409,
    response: () =>
        _envelope(409, 'DUPLICATE_PART_NO', 'Part number already exists'),
    counterText: 'รหัสอะไหล่นี้มีอยู่แล้ว',
    serverText: 'รหัสอะไหล่นี้มีอยู่แล้ว',
  ),
  '429 RATE_LIMITED': (
    status: 429,
    response: () => _envelope(429, 'RATE_LIMITED', 'Too many requests',
        extraHeaders: {'retry-after': '1'}),
    counterText: 'ระบบกำลังทำงานหนัก กรุณารอสักครู่',
    serverText: 'ระบบกำลังทำงานหนัก กรุณารอสักครู่',
  ),
  '500 INTERNAL_ERROR': (
    status: 500,
    response: () => _envelope(500, 'INTERNAL_ERROR', 'Internal server error'),
    counterText: _connection,
    serverText: 'Internal server error',
  ),
  '502 proxy HTML': (
    status: 502,
    response: () => http.Response('<html>bad gateway</html>', 502,
        headers: {'content-type': 'text/html'}),
    counterText: _connection,
    serverText: '<html>bad gateway</html>',
  ),
  '503 IDEMPOTENCY_KEY_IN_FLIGHT': (
    status: 503,
    response: () => _envelope(503, 'IDEMPOTENCY_KEY_IN_FLIGHT',
        'A request with this key is in progress'),
    // Owner 2026-10-06: the "wait" sentence on every path, both modes.
    counterText: 'คำขอก่อนหน้ากำลังดำเนินการ กรุณารอสักครู่',
    serverText: 'คำขอก่อนหน้ากำลังดำเนินการ กรุณารอสักครู่',
  ),
};

/// Paths `rethrowThai` / `rethrowServerRefusal` converted before this change:
/// their 5xx text is the server's (`thaiMessage`), kept as it was.
const _keepsServerText = {
  'ApiProductsRepository.delete',
  'ApiSettingsRepository.updateSettings',
  'OfflinePinRepository.setPin',
  'ApiSalesRepository.saveSale',
  'ApiReturnsRepository.createReturn',
  'ApiShiftsRepository.openShift',
  'ApiShiftsRepository.closeShift',
  'ApiShiftsRepository.addDrawerEntry',
};

/// `AuthRepository.loginRefusal`'s own sentence: any 401 at login is the
/// form's generic refusal.
const _loginOverrides = {
  'AuthRepository.login': {401: 'เข้าสู่ระบบไม่สำเร็จ'},
  // A 400 at import is the server's pre-flight verdict on the file; the owner
  // is shown its reason (OwnerImportRepository._refusal).
  'OwnerImportRepository.importBackup': {
    400: '${OwnerImportRepository.rejectedFileMessage}: name is required',
  },
};

/// The only things a screen may be handed. Anything else — above all an
/// `ApiException` — fails. `CreditPaymentQueued` is deliberately absent: every
/// reply here is a server answer, and only a transport failure may queue a
/// payment (08 §5, #452) — a regression back to queueing fails this test.
bool _allowed(Object? thrown) =>
    thrown == null ||
    thrown is PosException ||
    thrown is EnrolCodeRefusedException ||
    // changePassword's 401 (#443 PR3) — the cubit's own branch.
    thrown is PasswordChangeSessionExpiredException;

class _World {
  _World(this.db, this.api, this.tokens);
  final AppDatabase db;
  final ApiClient api;
  final _MemoryTokenStorage tokens;
}

typedef _Call = Future<Object?> Function(_World w);

/// Classes a screen or cubit reaches, each with the files that declare its
/// members — its own and, for a subclass, its superclass's — whose public
/// `Future` methods must all appear in [_cases] or [_noApiCall].
const _classes = <String, List<(String, String)>>{
  'ApiProductsRepository': [
    ('lib/data/repositories/api_products_repository.dart', 'ApiProductsRepository'),
    ('lib/data/repositories/products_repository.dart', 'ProductsRepository'),
  ],
  'ApiCustomersRepository': [
    ('lib/data/repositories/api_customers_repository.dart', 'ApiCustomersRepository'),
    ('lib/data/repositories/customers_repository.dart', 'CustomersRepository'),
  ],
  'ApiMechanicsRepository': [
    ('lib/data/repositories/api_mechanics_repository.dart', 'ApiMechanicsRepository'),
    ('lib/data/repositories/mechanics_repository.dart', 'MechanicsRepository'),
  ],
  'ApiPurchaseOrdersRepository': [
    ('lib/data/repositories/api_purchase_orders_repository.dart',
        'ApiPurchaseOrdersRepository'),
    ('lib/data/repositories/purchase_orders_repository.dart',
        'PurchaseOrdersRepository'),
  ],
  'ApiQuotesRepository': [
    ('lib/data/repositories/api_quotes_repository.dart', 'ApiQuotesRepository'),
    ('lib/data/repositories/quotes_repository.dart', 'QuotesRepository'),
  ],
  'ApiSettingsRepository': [
    ('lib/data/repositories/api_settings_repository.dart', 'ApiSettingsRepository'),
    ('lib/data/repositories/settings_repository.dart', 'SettingsRepository'),
  ],
  'DevicesRepository': [
    ('lib/data/repositories/devices_repository.dart', 'DevicesRepository'),
  ],
  'ReviewItemsRepository': [
    ('lib/data/repositories/review_items_repository.dart', 'ReviewItemsRepository'),
  ],
  'OwnerImportRepository': [
    ('lib/data/repositories/owner_import_repository.dart', 'OwnerImportRepository'),
  ],
  'AuthRepository': [
    ('lib/data/repositories/auth_repository.dart', 'AuthRepository'),
  ],
  'OfflinePinRepository': [
    ('lib/data/repositories/offline_pin_repository.dart', 'OfflinePinRepository'),
  ],
  // These `implements` their Drift interface, so every member is declared here.
  'ApiSalesRepository': [
    ('lib/data/repositories/api/api_sales_repository.dart', 'ApiSalesRepository'),
  ],
  'ApiReturnsRepository': [
    ('lib/data/repositories/api/api_returns_repository.dart', 'ApiReturnsRepository'),
  ],
  'ApiShiftsRepository': [
    ('lib/data/repositories/api/api_shifts_repository.dart', 'ApiShiftsRepository'),
  ],
  'SyncService': [('lib/data/sync/sync_service.dart', 'SyncService')],
  'DocCounterSeeder': [
    ('lib/data/services/doc_counter_seeder.dart', 'DocCounterSeeder'),
  ],
  'BootstrapService': [
    ('lib/data/services/bootstrap_service.dart', 'BootstrapService'),
  ],
};

/// Public `Future` methods that never reach `ApiClient`, with the reason.
const _noApiCall = <String, String>{
  'ApiProductsRepository.getById': 'Drift first; its GET is caught and swallowed',
  'ApiProductsRepository.productIdsWithUnsyncedOps': 'inherited, Drift only',
  'ApiProductsRepository.openDocumentRefs': 'inherited, Drift only',
  'ApiMechanicsRepository.getCreditPayments': 'inherited, Drift only',
  'ApiMechanicsRepository.getPendingCreditPayments': 'inherited, Drift only',
  'ApiMechanicsRepository.discardRejectedCreditPayment': 'inherited, Drift only',
  'ApiSettingsRepository.getSettings': 'inherited, Drift only',
  'ApiMechanicsRepository.flushPendingCreditPayments':
      'driven below via its outbox op; listed for its writesToServer=false early exit',
  'AuthRepository.logout': 'token storage only',
  'AuthRepository.forgetDeadDeviceToken': 'token storage only',
  'AuthRepository.clearDeviceEnrolment': 'token storage only',
  'AuthRepository.getCurrentUser': 'token storage only',
  'AuthRepository.getDeviceToken': 'token storage only',
  'AuthRepository.getDeviceRole': 'token storage only',
  'AuthRepository.getDeviceId': 'token storage only',
  'AuthRepository.sessionDeviceId': 'token storage only',
  'AuthRepository.sessionDeviceRole': 'token storage only',
  'AuthRepository.isAuthenticated': 'token storage only',
  'OfflinePinRepository.isPinConfigured': 'Drift only',
  'OfflinePinRepository.isLocked': 'Drift only',
  'OfflinePinRepository.getFailedAttempts': 'Drift only',
  'OfflinePinRepository.getLastLoginIat': 'Drift only',
  'OfflinePinRepository.isExpired': 'Drift only',
  'OfflinePinRepository.getDeviceRole': 'Drift only',
  'OfflinePinRepository.getStoredDeviceId': 'Drift only',
  'OfflinePinRepository.isPinAvailable': 'Drift only',
  'OfflinePinRepository.recordOnlineLogin': 'Drift only',
  'OfflinePinRepository.verifyPin': 'Drift only',
  'OfflinePinRepository.getStoredUser': 'Drift only',
  'OfflinePinRepository.clearPin': 'Drift only',
  'ApiSalesRepository.getSales': 'Drift read',
  'ApiSalesRepository.getSalesByIds': 'Drift read',
  'ApiSalesRepository.getRefundedQty': 'Drift read',
  'ApiSalesRepository.voidSaleOffline': 'queues an outbox op; push is unawaited',
  'ApiReturnsRepository.getReturns': 'Drift read',
  'ApiShiftsRepository.getCashDrawer': 'Drift read',
  'ApiShiftsRepository.getShiftHistory': 'Drift read',
  'ApiShiftsRepository.drawerCash': 'Drift read',
  'ApiShiftsRepository.assertCashOutFits': 'Drift read',
  'SyncService.refreshOutbox': 'Drift read',
  'SyncService.checkHealth': 'raw http.Client, never ApiClient',
  'SyncService.push': 'raw http.Client, never ApiClient; failures stay in the outbox',
  'SyncService.pull': 'runs onPull, whose pulls swallow their errors',
  'SyncService.resend': 'Drift write + unawaited push',
  'SyncService.writeAtomic': 'Drift transaction only',
  'SyncService.enqueueOp': 'Drift write only',
};

SaleInput _sale() => const SaleInput(
      subtotal: 100,
      discount: 0,
      total: 100,
      paymentMethod: 'เงินสด',
      items: [
        SaleLineInput(
          productId: 'tp1',
          name: 'Brake Pad',
          qty: 1,
          price: 100,
          partNo: 'TP-1',
          nameTH: 'ผ้าเบรก',
        ),
      ],
    );

ApiShiftsRepository _shifts(_World w) => ApiShiftsRepository(
      api: w.api,
      db: w.db,
      drift: ShiftsRepository(w.db),
    );

ApiMechanicsRepository _mechanics(_World w) =>
    ApiMechanicsRepository(w.db, w.api, writesToServer: true);

/// One entry per public method that can reach `ApiClient`.
final Map<String, _Call> _cases = {
  // ── Products ──
  'ApiProductsRepository.syncFromServer': (w) =>
      ApiProductsRepository(w.db, w.api).syncFromServer(),
  'ApiProductsRepository.getAll': (w) => ApiProductsRepository(w.db, w.api).getAll(),
  'ApiProductsRepository.getCategories': (w) =>
      ApiProductsRepository(w.db, w.api).getCategories(),
  'ApiProductsRepository.add': (w) => ApiProductsRepository(w.db, w.api)
      .add(const ProductsCompanion(partNo: Value('NEW-1'), name: Value('x'))),
  'ApiProductsRepository.update': (w) => ApiProductsRepository(w.db, w.api)
      .update('tp1', const ProductsCompanion(name: Value('y'))),
  'ApiProductsRepository.delete': (w) => ApiProductsRepository(w.db, w.api).delete('tp1'),
  'ApiProductsRepository.adjustStock': (w) =>
      ApiProductsRepository(w.db, w.api).adjustStock('tp1', 1, 'adjust', null),
  // Inherited from ProductsRepository; both reach ApiClient through overrides.
  'ApiProductsRepository.deleteMany': (w) =>
      ApiProductsRepository(w.db, w.api).deleteMany(['tp1']),
  'ApiProductsRepository.catColor': (w) =>
      ApiProductsRepository(w.db, w.api).catColor('เบรก'),
  'ApiProductsRepository.addCategory': (w) =>
      ApiProductsRepository(w.db, w.api).addCategory('ใหม่'),
  'ApiProductsRepository.deleteCategory': (w) =>
      ApiProductsRepository(w.db, w.api).deleteCategory('เบรก'),
  // ── Customers ──
  'ApiCustomersRepository.syncFromServer': (w) =>
      ApiCustomersRepository(w.db, w.api).syncFromServer(),
  'ApiCustomersRepository.getCustomers': (w) =>
      ApiCustomersRepository(w.db, w.api).getCustomers(),
  'ApiCustomersRepository.addCustomer': (w) => ApiCustomersRepository(w.db, w.api)
      .addCustomer(const CustomersCompanion(name: Value('ใหม่'))),
  'ApiCustomersRepository.updateCustomer': (w) => ApiCustomersRepository(w.db, w.api)
      .updateCustomer('tc1', const CustomersCompanion(name: Value('ใหม่'))),
  'ApiCustomersRepository.deleteCustomer': (w) =>
      ApiCustomersRepository(w.db, w.api).deleteCustomer('tc1'),
  // ── Mechanics ──
  'ApiMechanicsRepository.syncFromServer': (w) => _mechanics(w).syncFromServer(),
  'ApiMechanicsRepository.getMechanics': (w) => _mechanics(w).getMechanics(),
  'ApiMechanicsRepository.addMechanic': (w) =>
      _mechanics(w).addMechanic(const MechanicsCompanion(name: Value('ช่างใหม่'))),
  'ApiMechanicsRepository.updateMechanic': (w) => _mechanics(w)
      .updateMechanic('tm1', const MechanicsCompanion(name: Value('ช่างบี'))),
  'ApiMechanicsRepository.deleteMechanic': (w) => _mechanics(w).deleteMechanic('tm1'),
  'ApiMechanicsRepository.addCreditPayment': (w) =>
      _mechanics(w).addCreditPayment(mechanicId: 'tm1', amount: 10, paymentMethod: 'เงินสด'),
  'ApiMechanicsRepository.flushPendingCreditPayments#queued': (w) async {
    await w.db.into(w.db.outboxOps).insert(OutboxOpsCompanion.insert(
          opId: 'cp-op-1',
          idempotencyKey: 'idem-cp-1',
          type: 'credit_payment.create',
          payload: jsonEncode({'id': 'cp1', 'mechanicId': 'tm1', 'amount': '10.00'}),
          aggregates: jsonEncode(['mechanic:tm1']),
          createdAt: DateTime(2026, 10, 6),
          status: 'pending',
        ));
    return _mechanics(w).flushPendingCreditPayments();
  },
  // Inherited from MechanicsRepository; ends in the overridden flush.
  'ApiMechanicsRepository.resendRejectedAllowingOverpayment': (w) async {
    await w.db.into(w.db.outboxOps).insert(OutboxOpsCompanion.insert(
          opId: 'cp-op-2',
          idempotencyKey: 'idem-cp-2',
          type: 'credit_payment.create',
          payload: jsonEncode({'id': 'cp2', 'mechanicId': 'tm1', 'amount': '10.00'}),
          aggregates: jsonEncode(['mechanic:tm1']),
          createdAt: DateTime(2026, 10, 6),
          status: 'rejected',
        ));
    return _mechanics(w).resendRejectedAllowingOverpayment('cp-op-2');
  },
  // ── Purchase orders ──
  'ApiPurchaseOrdersRepository.syncFromServer': (w) =>
      ApiPurchaseOrdersRepository(w.db, w.api).syncFromServer(),
  'ApiPurchaseOrdersRepository.getPOs': (w) =>
      ApiPurchaseOrdersRepository(w.db, w.api).getPOs(),
  'ApiPurchaseOrdersRepository.savePO': (w) =>
      ApiPurchaseOrdersRepository(w.db, w.api).savePO(const PoInput(
        supplier: 'S',
        items: [PoLineInput(partNo: 'TP-1', name: 'Brake Pad', qty: 1, cost: 50)],
      )),
  'ApiPurchaseOrdersRepository.receivePO': (w) =>
      ApiPurchaseOrdersRepository(w.db, w.api).receivePO('po1'),
  'ApiPurchaseOrdersRepository.cancelPO': (w) =>
      ApiPurchaseOrdersRepository(w.db, w.api).cancelPO('po1'),
  'ApiPurchaseOrdersRepository.deletePO': (w) =>
      ApiPurchaseOrdersRepository(w.db, w.api).deletePO('po1'),
  // ── Quotes ──
  'ApiQuotesRepository.syncFromServer': (w) =>
      ApiQuotesRepository(w.db, w.api).syncFromServer(),
  'ApiQuotesRepository.getQuotes': (w) => ApiQuotesRepository(w.db, w.api).getQuotes(),
  'ApiQuotesRepository.saveQuote': (w) =>
      ApiQuotesRepository(w.db, w.api).saveQuote(const QuoteInput(
        items: [QuoteLineInput(productId: 'tp1', name: 'Brake Pad', qty: 1, price: 100)],
      )),
  'ApiQuotesRepository.deleteQuote': (w) => ApiQuotesRepository(w.db, w.api).deleteQuote('q1'),
  'ApiQuotesRepository.updateQuote': (w) => ApiQuotesRepository(w.db, w.api)
      .updateQuote('q1', const QuotesCompanion(customerName: Value('x'))),
  'ApiQuotesRepository.duplicateQuote': (w) =>
      ApiQuotesRepository(w.db, w.api).duplicateQuote('q1'),
  'ApiQuotesRepository.purgeOldQuotes': (w) =>
      ApiQuotesRepository(w.db, w.api).purgeOldQuotes(),
  // ── Settings ──
  'ApiSettingsRepository.pullFromServer': (w) =>
      ApiSettingsRepository(w.db, w.api).pullFromServer(),
  'ApiSettingsRepository.updateSettings': (w) => ApiSettingsRepository(w.db, w.api)
      .updateSettings(const SettingsRowCompanion(shopName: Value('ร้าน'))),
  // ── Devices / review items ──
  'DevicesRepository.listDevices': (w) => DevicesRepository(w.api).listDevices(),
  'DevicesRepository.createDevice': (w) =>
      DevicesRepository(w.api).createDevice(label: 'POS', role: 'pos'),
  'DevicesRepository.retireDevice': (w) =>
      DevicesRepository(w.api).retireDevice(deviceId: 'd1'),
  'ReviewItemsRepository.listPending': (w) => ReviewItemsRepository(w.api).listPending(),
  'OwnerImportRepository.importBackup': (w) =>
      OwnerImportRepository(w.api, pollInterval: Duration.zero)
          .importBackup(const {'__meta': {'version': 2}}),
  'ReviewItemsRepository.markReviewed': (w) =>
      ReviewItemsRepository(w.api).markReviewed('r1'),
  // ── Auth / offline PIN ──
  'AuthRepository.login': (w) => AuthRepository(apiClient: w.api, tokenStorage: w.tokens)
      .login(username: 'owner', password: 'pw'),
  'AuthRepository.changePassword': (w) =>
      AuthRepository(apiClient: w.api, tokenStorage: w.tokens)
          .changePassword(passwordChangeToken: 'pwc', newPassword: 'new-password-123'),
  'AuthRepository.enrolDevice': (w) =>
      AuthRepository(apiClient: w.api, tokenStorage: w.tokens).enrolDevice('abcd1234'),
  'AuthRepository.refresh': (w) =>
      AuthRepository(apiClient: w.api, tokenStorage: w.tokens).refresh(),
  'OfflinePinRepository.setPin': (w) =>
      OfflinePinRepository(db: w.db, tokenStorage: w.tokens, apiClient: w.api)
          .setPin(password: 'account-pw', newPin: '1234', username: 'shop', deviceId: 'd1'),
  // ── Sales / returns / shifts ──
  'ApiSalesRepository.saveSale': (w) => ApiSalesRepository(
        api: w.api,
        db: w.db,
        drift: SalesRepository(w.db),
      ).saveSale(_sale()),
  'ApiReturnsRepository.createReturn': (w) async {
    final sale = await SalesRepository(w.db).saveSale(_sale());
    return ApiReturnsRepository(api: w.api, db: w.db, drift: ReturnsRepository(w.db))
        .createReturn(ReturnInput(
      saleId: sale.id,
      items: const [ReturnLineInput(productId: 'tp1', name: 'Brake Pad', qty: 1, price: 100)],
      refundMethod: 'เงินสด',
    ));
  },
  'ApiShiftsRepository.openShift': (w) => _shifts(w).openShift(500),
  'ApiShiftsRepository.closeShift': (w) => _shifts(w).closeShift(500),
  'ApiShiftsRepository.addDrawerEntry': (w) => _shifts(w).addDrawerEntry('in', 50, null),
  // ── Sync / services ──
  'SyncService.discard': (w) async {
    await w.db.into(w.db.outboxOps).insert(OutboxOpsCompanion.insert(
          opId: 'op-1',
          idempotencyKey: 'idem-op-1',
          type: 'customer.create',
          payload: jsonEncode({'id': 'c-offline-1', 'name': 'x'}),
          aggregates: jsonEncode(['customer:c-offline-1']),
          createdAt: DateTime(2026, 10, 6),
          status: 'rejected',
        ));
    final sync = SyncService(
      db: w.db,
      apiClient: w.api,
      tokenStorage: w.tokens,
      autoStartHealthProbe: false,
    );
    return sync.discard('op-1', 'owner note');
  },
  'DocCounterSeeder.seed': (w) => DocCounterSeeder(db: w.db, apiClient: w.api).seed(),
  'BootstrapService.bootstrap': (w) => BootstrapService(db: w.db, apiClient: w.api).bootstrap(),
};

Future<Object?> _caught(Future<Object?> Function() run) async {
  try {
    await run();
    return null;
  } catch (e) {
    return e;
  }
}

final _stringStart = RegExp('r?(\'\'\'|"""|\'|")');

/// [source] with every comment and string literal blanked to spaces, so braces
/// can be counted (a `'{'` in a string or a URL's `//` cannot confuse it).
/// Interpolations are blanked with their string — they hold no declarations.
String _maskCommentsAndStrings(String source) {
  final out = StringBuffer();
  var i = 0;
  void blankTo(int end) {
    for (; i < end && i < source.length; i++) {
      out.write(source[i] == '\n' ? '\n' : ' ');
    }
  }

  while (i < source.length) {
    if (source.startsWith('//', i)) {
      final nl = source.indexOf('\n', i);
      blankTo(nl < 0 ? source.length : nl);
      continue;
    }
    if (source.startsWith('/*', i)) {
      final end = source.indexOf('*/', i + 2);
      blankTo(end < 0 ? source.length : end + 2);
      continue;
    }
    // A string starts at a quote, or at `r` + quote when the `r` is not the
    // end of an identifier (`bar'` is not a raw string).
    final afterWord = i > 0 && RegExp(r'\w').hasMatch(source[i - 1]);
    final m = afterWord && source[i] == 'r'
        ? null
        : _stringStart.matchAsPrefix(source, i);
    if (m != null) {
      final raw = m.group(0)!.startsWith('r');
      final quote = m.group(1)!;
      var j = m.end;
      while (j < source.length && !source.startsWith(quote, j)) {
        if (!raw && source[j] == r'\') j++;
        j++;
      }
      blankTo(j + quote.length);
      continue;
    }
    out.write(source[i]);
    i++;
  }
  return out.toString();
}

final _futureMethod = RegExp(r'\bFuture<[^;{}]*?>\??\s+([a-z]\w*)\s*[(<]');

/// Public `Future` methods [className] declares in [path]: member declarations
/// (brace depth 1 of the class body), whatever their indentation, one line or
/// several, block or `=>` bodied.
Set<String> _publicFutureMethods(String path, String className) {
  final src = _maskCommentsAndStrings(
      File(p.joinAll(p.posix.split(path))).readAsStringSync());
  final at = RegExp('\\bclass\\s+$className\\b').firstMatch(src);
  expect(at, isNotNull, reason: '$className not found in $path');
  final open = src.indexOf('{', at!.end);
  // Only depth-1 characters survive: member signatures, not bodies.
  final members = StringBuffer();
  var depth = 0;
  var parens = 0;
  for (var i = open; i < src.length; i++) {
    final c = src[i];
    // A brace that opens/closes a member body (outside any parentheses —
    // not a record type's or named parameters') is kept, so a declaration
    // match can never run on from one member into the next.
    if (depth == 1 && c == '(') parens++;
    if (depth == 1 && c == ')') parens--;
    if (c == '{') {
      depth++;
      members.write(depth == 2 && parens == 0 ? '{' : ' ');
      continue;
    }
    if (c == '}') {
      depth--;
      if (depth == 0) break;
      members.write(depth == 1 && parens == 0 ? '}' : ' ');
      continue;
    }
    members.write(depth == 1 || c == '\n' ? c : ' ');
  }
  return {
    for (final m in _futureMethod.allMatches(members.toString())) m.group(1)!,
  };
}

void main() {
  test('every public Future method is driven below or listed in _noApiCall', () {
    final covered = {
      ..._cases.keys.map((k) => k.split('#').first),
      ..._noApiCall.keys,
    };
    final missing = <String>[];
    for (final e in _classes.entries) {
      final methods = {
        for (final (path, declaring) in e.value)
          ..._publicFutureMethods(path, declaring),
      };
      for (final m in methods) {
        if (!covered.contains('${e.key}.$m')) missing.add('${e.key}.$m');
      }
    }
    expect(missing, isEmpty,
        reason: 'Add each new method to `_cases` (it reaches ApiClient) or, '
            'with a reason, to `_noApiCall`:\n${missing.join('\n')}');
  });

  test('the method scan sees through indentation, comments and strings', () {
    final dir = Directory.systemTemp.createTempSync('scan');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File(p.join(dir.path, 'x.dart'))
      ..writeAsStringSync('''
class X {
// Future<void> commented() async {}
Future<void> noIndent() async { final s = '{'; }
    Future<List<String>>
        multiLine(int a) => Future.value([]);
  Future<({int a, String b})> record({required int x}) async => (a: 1, b: '');
  /* Future<void> blockComment() async {} */
  final u = 'http://x/{'; Future<void> afterUrl() async {}
  Future<void> _private() async {}
  Future<void> get notAMethod => Future.value();
  void inner() { Future<void> local() async {} }
}
class Y { Future<void> other() async {} }
''');
    expect(_publicFutureMethods(f.path, 'X'),
        {'noIndent', 'multiLine', 'record', 'afterUrl'});
  });

  for (final reply in _replies.entries) {
    group(reply.key, () {
      late AppDatabase db;
      late _World world;
      late int sent;

      setUp(() async {
        db = AppDatabase(NativeDatabase.memory());
        sent = 0;
        final tokens = _MemoryTokenStorage();
        final api = ApiClient(
          baseUrl: 'http://server.test',
          tokenStorage: tokens,
          httpClient: MockClient((_) async {
            sent++;
            return reply.value.response();
          }),
        );
        world = _World(db, api, tokens);

        await db.into(db.products).insert(ProductsCompanion.insert(
              id: 'tp1',
              partNo: 'TP-1',
              name: 'Brake Pad',
              nameTH: 'ผ้าเบรก',
              category: 'เบรก',
              brand: 'X',
              price: 100,
              cost: 60,
              stock: 10,
              minStock: 1,
            ));
        await db.into(db.customers).insert(CustomersCompanion.insert(
              id: 'tc1',
              code: 'C-1',
              name: 'Somchai',
              nameTH: 'สมชาย',
              createdAt: '2026-01-01',
            ));
        await db.into(db.mechanics).insert(MechanicsCompanion.insert(
              id: 'tm1',
              code: 'M-1',
              name: 'Chang',
              createdAt: '2026-01-01',
              creditLimit: const Value(5000),
              creditBalance: const Value(100),
            ));
        await db.into(db.shifts).insert(ShiftsCompanion.insert(
              id: 'tsh-open',
              dateStr: '2026-10-06',
              startingCash: 500,
              openedAt: DateTime(2026, 10, 6, 8),
              isActive: const Value(true),
            ));
      });

      tearDown(() async => db.close());

      for (final c in _cases.entries) {
        test(c.key, () async {
          final thrown = await _caught(() => c.value(world));

          expect(sent, greaterThan(0),
              reason: 'the case must actually reach the server');
          expect(_allowed(thrown), isTrue,
              reason: '${c.key} threw a type no screen is written for: '
                  '${thrown.runtimeType}: $thrown');
          final method = c.key.split('#').first;
          final want = _loginOverrides[method]?[reply.value.status] ??
              (_keepsServerText.contains(method)
                  ? reply.value.serverText
                  : reply.value.counterText);
          if (thrown is PosException) {
            expect(thrown.message, want,
                reason: 'the sentence this path showed before must not change');
          }
          if (thrown is EnrolCodeRefusedException) {
            expect(thrown.refusal.message, want);
          }
        });
      }
    });
  }
}
