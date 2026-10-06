// CLAUDE.md binding rule: "An `ApiException` must never reach a screen —
// convert via `rethrowThai` / `rethrowServerRefusal` to a plain Thai-string
// `Exception`/`PosException`."
//
// `presentation_no_api_exception_test.dart` keeps the TYPE out of
// lib/presentation/ at the source level; this file checks the RUNTIME side:
// every public method a screen or cubit can reach through
// `repository_providers.dart` is driven against a server that answers each
// error class (4xx, 429, 5xx, a proxy's HTML 502, 503 in-flight), and nothing
// it throws may be an `ApiException`. A `PosException` must carry exactly the
// sentence `ServerErrorResolver.resolveCounterError` gives the `ApiException`
// the client raised for that same reply — the text a screen showed when the
// raw exception still reached it — so the conversion changes nothing on screen.
//
// The table is checked against the source: a new public `Future` method in one
// of the files below fails here until it is added to [_cases] or, with its
// reason, to [_noApiCall].

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/core/network/server_error_resolver.dart';
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

/// Every error class a repository can be handed. 401 is left out on purpose:
/// it drives `ApiClient`'s refresh/expiry path, and login's own 401 sentences
/// are pinned by `auth_repository_test.dart`.
final Map<String, http.Response Function()> _replies = {
  '400 BAD_REQUEST (English message)': () =>
      _envelope(400, 'BAD_REQUEST', 'name is required'),
  '409 coded verdict': () =>
      _envelope(409, 'DUPLICATE_PART_NO', 'Part number already exists'),
  '429 RATE_LIMITED': () => _envelope(429, 'RATE_LIMITED', 'Too many requests',
      extraHeaders: {'retry-after': '1'}),
  '500 INTERNAL_ERROR': () =>
      _envelope(500, 'INTERNAL_ERROR', 'Internal server error'),
  '502 proxy HTML': () => http.Response('<html>bad gateway</html>', 502,
      headers: {'content-type': 'text/html'}),
  '503 IDEMPOTENCY_KEY_IN_FLIGHT': () => _envelope(
      503, 'IDEMPOTENCY_KEY_IN_FLIGHT', 'A request with this key is in progress'),
};

class _World {
  _World(this.db, this.api, this.tokens);
  final AppDatabase db;
  final ApiClient api;
  final _MemoryTokenStorage tokens;
}

typedef _Call = Future<Object?> Function(_World w);

/// Repository/service files a screen or cubit reaches, and the class in each
/// whose public `Future` methods must all appear in [_cases] or [_noApiCall].
const _files = {
  'lib/data/repositories/api_products_repository.dart': 'ApiProductsRepository',
  'lib/data/repositories/api_customers_repository.dart': 'ApiCustomersRepository',
  'lib/data/repositories/api_mechanics_repository.dart': 'ApiMechanicsRepository',
  'lib/data/repositories/api_purchase_orders_repository.dart':
      'ApiPurchaseOrdersRepository',
  'lib/data/repositories/api_quotes_repository.dart': 'ApiQuotesRepository',
  'lib/data/repositories/api_settings_repository.dart': 'ApiSettingsRepository',
  'lib/data/repositories/devices_repository.dart': 'DevicesRepository',
  'lib/data/repositories/review_items_repository.dart': 'ReviewItemsRepository',
  'lib/data/repositories/auth_repository.dart': 'AuthRepository',
  'lib/data/repositories/offline_pin_repository.dart': 'OfflinePinRepository',
  'lib/data/repositories/api/api_sales_repository.dart': 'ApiSalesRepository',
  'lib/data/repositories/api/api_returns_repository.dart': 'ApiReturnsRepository',
  'lib/data/repositories/api/api_shifts_repository.dart': 'ApiShiftsRepository',
  'lib/data/sync/sync_service.dart': 'SyncService',
  'lib/data/services/doc_counter_seeder.dart': 'DocCounterSeeder',
  'lib/data/services/bootstrap_service.dart': 'BootstrapService',
};

/// Public `Future` methods that never reach `ApiClient`, with the reason.
const _noApiCall = <String, String>{
  'ApiProductsRepository.getById': 'Drift first; its GET is caught and swallowed',
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

/// Public `Future` methods declared by [className] in [path].
Set<String> _publicFutureMethods(String path, String className) {
  final src = File(p.joinAll(path.split('/'))).readAsStringSync();
  final start = src.indexOf(RegExp('class $className\\b'));
  expect(start, isNonNegative, reason: '$className not found in $path');
  // Up to the next top-level declaration (a line starting with `class `).
  final rest = src.substring(start + 1);
  final next = rest.indexOf(RegExp(r'^class ', multiLine: true));
  final body = next < 0 ? rest : rest.substring(0, next);
  final decl = RegExp(
    r'^  (?:static\s+)?Future<[^\n]*?>\??\s+([a-z]\w*)\s*[(<]',
    multiLine: true,
  );
  return {for (final m in decl.allMatches(body)) '$className.${m.group(1)}'};
}

void main() {
  test('every public Future method is driven below or listed in noApiCall', () {
    final covered = {
      ..._cases.keys.map((k) => k.split('#').first),
      ..._noApiCall.keys,
    };
    final missing = <String>[];
    for (final e in _files.entries) {
      missing.addAll(_publicFutureMethods(e.key, e.value).difference(covered));
    }
    expect(missing, isEmpty,
        reason: 'Add each new method to `_cases` (it reaches ApiClient) or, '
            'with a reason, to `_noApiCall`:\n${missing.join('\n')}');
  });

  for (final reply in _replies.entries) {
    group(reply.key, () {
      late AppDatabase db;
      late _World world;
      late int sent;
      late String expected;

      setUp(() async {
        db = AppDatabase(NativeDatabase.memory());
        sent = 0;
        final tokens = _MemoryTokenStorage();
        final api = ApiClient(
          baseUrl: 'http://server.test',
          tokenStorage: tokens,
          httpClient: MockClient((_) async {
            sent++;
            return reply.value();
          }),
        );
        world = _World(db, api, tokens);
        // The ApiException the client raises for this very reply, and the
        // sentence a screen rendered for it via resolveCounterError.
        final probe = await _caught(() => api.get('/api/v1/probe'));
        expect(probe, isA<ApiException>());
        expected = ServerErrorResolver.resolveCounterError(probe!);
        sent = 0;

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
          expect(thrown, isNot(isA<ApiException>()),
              reason: '${c.key} let an ApiException out: $thrown');
          if (thrown is PosException) {
            expect(thrown.message, expected,
                reason: 'the converted sentence must be the one the screen '
                    'showed for the raw ApiException');
          }
          if (thrown is EnrolCodeRefusedException) {
            expect(thrown.refusal.message, expected);
          }
        });
      }
    });
  }
}
