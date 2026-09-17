// Widget tests verifying that connection failures (ClientException,
// ApiTimeoutException, TimeoutException) render the canonical Thai connection
// sentence on all counter-facing screens without exposing URLs or raw English,
// while PosException verdicts preserve their message verbatim (#199).

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/core/utils/dates.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/mechanics_repository.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/repositories/returns_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/data/repositories/shifts_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/cash_drawer_screen.dart';
import 'package:srisurart_pos/presentation/screens/checkout_screen.dart';
import 'package:srisurart_pos/presentation/screens/mechanics_screen.dart';
import 'package:srisurart_pos/presentation/screens/returns_screen.dart';

class _StubSalesRepo extends SalesRepository {
  _StubSalesRepo(super.db);
  Object? errorToThrow;

  @override
  Future<SaleRow> saveSale(SaleInput input) async {
    if (errorToThrow != null) throw errorToThrow!;
    return super.saveSale(input);
  }
}

class _StubReturnsRepo extends ReturnsRepository {
  _StubReturnsRepo(super.db);
  Object? errorToThrow;

  @override
  Future<ReturnRow> createReturn(ReturnInput input) async {
    if (errorToThrow != null) throw errorToThrow!;
    return super.createReturn(input);
  }
}

class _StubShiftsRepo extends ShiftsRepository {
  _StubShiftsRepo(super.db);
  Object? errorToThrow;

  @override
  Future<ShiftRow> openShift(double startingCash) async {
    if (errorToThrow != null) throw errorToThrow!;
    return super.openShift(startingCash);
  }

  @override
  Future<DrawerEntryRow> addDrawerEntry(String type, double amount, [String? note]) async {
    if (errorToThrow != null) throw errorToThrow!;
    return super.addDrawerEntry(type, amount, note);
  }
}

class _StubMechanicsRepo extends MechanicsRepository {
  _StubMechanicsRepo(super.db);
  Object? errorToThrow;
  Future<CreditPaymentRow> Function({required bool allowOverpayment})? onAddCreditPayment;

  @override
  Future<CreditPaymentRow> addCreditPayment({
    required String mechanicId,
    required double amount,
    String? note,
    required String paymentMethod,
    bool allowOverpayment = false,
  }) async {
    if (onAddCreditPayment != null) {
      return onAddCreditPayment!(allowOverpayment: allowOverpayment);
    }
    if (errorToThrow != null) throw errorToThrow!;
    return super.addCreditPayment(
      mechanicId: mechanicId,
      amount: amount,
      note: note,
      paymentMethod: paymentMethod,
      allowOverpayment: allowOverpayment,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
    await initializeDateFormatting('th', null);
  });

  void setWideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  group('CheckoutScreen error rendering (#199)', () {
    testWidgets('shows canonical Thai sentence and hides URL on ApiTimeoutException', (tester) async {
      setWideViewport(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final sales = _StubSalesRepo(db);
      sales.errorToThrow = ApiTimeoutException(
        const Duration(seconds: 40),
        Uri.parse('http://192.168.1.50:3000/api/v1/sales'),
      );

      final cartCubit = CartCubit();
      final pendingQuoteCubit = PendingQuoteCubit();
      addTearDown(cartCubit.close);
      addTearDown(pendingQuoteCubit.close);

      await tester.runAsync(() async {
        final p = (await ProductsRepository(db).getAll()).firstWhere((x) => x.stock >= 1);
        cartCubit.add(p);

        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: [
              ...repositoryProviders(db),
              RepositoryProvider<SalesRepository>.value(value: sales),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<PendingQuoteCubit>.value(value: pendingQuoteCubit),
                BlocProvider<CartCubit>.value(value: cartCubit),
              ],
              child: MaterialApp(
                home: Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(0.8)),
                    child: const Scaffold(body: CheckoutScreen()),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 200));

        // Switch to QR transfer so cash entry is not needed
        await tester.tap(find.text('โอน/QR'));
        await tester.pumpAndSettle();

        // Tap checkout button
        await tester.tap(
          find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('ชำระเงิน  ')),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          find.text('ขายไม่สำเร็จ: เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์'),
          findsOneWidget,
        );
        expect(find.textContaining('http://'), findsNothing);
        expect(find.textContaining('192.168.1.50'), findsNothing);
        expect(find.textContaining('ClientException'), findsNothing);
        expect(find.textContaining('40000 ms'), findsNothing);
      });
    });

    testWidgets('preserves PosException verdict verbatim', (tester) async {
      setWideViewport(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final sales = _StubSalesRepo(db);
      sales.errorToThrow = const PosException('INSUFFICIENT_STOCK', 'สต็อกไม่พอ');

      final cartCubit = CartCubit();
      final pendingQuoteCubit = PendingQuoteCubit();
      addTearDown(cartCubit.close);
      addTearDown(pendingQuoteCubit.close);

      await tester.runAsync(() async {
        final p = (await ProductsRepository(db).getAll()).firstWhere((x) => x.stock >= 1);
        cartCubit.add(p);

        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: [
              ...repositoryProviders(db),
              RepositoryProvider<SalesRepository>.value(value: sales),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<PendingQuoteCubit>.value(value: pendingQuoteCubit),
                BlocProvider<CartCubit>.value(value: cartCubit),
              ],
              child: MaterialApp(
                home: Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(0.8)),
                    child: const Scaffold(body: CheckoutScreen()),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 200));

        await tester.tap(find.text('โอน/QR'));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('ชำระเงิน  ')),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('ขายไม่สำเร็จ: สต็อกไม่พอ'), findsOneWidget);
      });
    });

    testWidgets('shows canonical Thai sentence on TimeoutException', (tester) async {
      setWideViewport(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final sales = _StubSalesRepo(db);
      sales.errorToThrow = TimeoutException('Timeout expired after 40000 ms');

      final cartCubit = CartCubit();
      final pendingQuoteCubit = PendingQuoteCubit();
      addTearDown(cartCubit.close);
      addTearDown(pendingQuoteCubit.close);

      await tester.runAsync(() async {
        final p = (await ProductsRepository(db).getAll()).firstWhere((x) => x.stock >= 1);
        cartCubit.add(p);

        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: [
              ...repositoryProviders(db),
              RepositoryProvider<SalesRepository>.value(value: sales),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<PendingQuoteCubit>.value(value: pendingQuoteCubit),
                BlocProvider<CartCubit>.value(value: cartCubit),
              ],
              child: MaterialApp(
                home: Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(0.8)),
                    child: const Scaffold(body: CheckoutScreen()),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 200));

        await tester.tap(find.text('โอน/QR'));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('ชำระเงิน  ')),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          find.text('ขายไม่สำเร็จ: เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์'),
          findsOneWidget,
        );
        expect(find.textContaining('TimeoutException'), findsNothing);
      });
    });

    testWidgets('shows canonical Thai sentence on raw http.ClientException', (tester) async {
      setWideViewport(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final sales = _StubSalesRepo(db);
      sales.errorToThrow = http.ClientException(
        'Connection closed before full header was received',
        Uri.parse('http://192.168.1.50:3000/api/v1/sales'),
      );

      final cartCubit = CartCubit();
      final pendingQuoteCubit = PendingQuoteCubit();
      addTearDown(cartCubit.close);
      addTearDown(pendingQuoteCubit.close);

      await tester.runAsync(() async {
        final p = (await ProductsRepository(db).getAll()).firstWhere((x) => x.stock >= 1);
        cartCubit.add(p);

        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: [
              ...repositoryProviders(db),
              RepositoryProvider<SalesRepository>.value(value: sales),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<PendingQuoteCubit>.value(value: pendingQuoteCubit),
                BlocProvider<CartCubit>.value(value: cartCubit),
              ],
              child: MaterialApp(
                home: Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(0.8)),
                    child: const Scaffold(body: CheckoutScreen()),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 200));

        await tester.tap(find.text('โอน/QR'));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('ชำระเงิน  ')),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          find.text('ขายไม่สำเร็จ: เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์'),
          findsOneWidget,
        );
        expect(find.textContaining('http://'), findsNothing);
        expect(find.textContaining('ClientException'), findsNothing);
      });
    });
  });

  group('ReturnsScreen error rendering (#199)', () {
    testWidgets('shows canonical Thai sentence and hides URL on ApiTimeoutException', (tester) async {
      setWideViewport(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final saleId = 's-ret-test';
      await db.into(db.sales).insert(
        SalesCompanion.insert(
          id: saleId,
          receiptNo: 'RC-001',
          date: DateTime.now(),
          subtotal: 100,
          total: 100,
          paymentMethod: 'เงินสด',
        ),
      );
      await db.into(db.saleItems).insert(
        SaleItemsCompanion.insert(
          saleId: saleId,
          productId: 'p-001',
          name: 'Test Part',
          qty: 1,
          price: 100,
        ),
      );

      final returnsRepo = _StubReturnsRepo(db);
      returnsRepo.errorToThrow = ApiTimeoutException(
        const Duration(seconds: 40),
        Uri.parse('http://192.168.1.50:3000/api/v1/returns'),
      );

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: [
              ...repositoryProviders(db),
              RepositoryProvider<ReturnsRepository>.value(value: returnsRepo),
            ],
            child: const MaterialApp(home: Scaffold(body: ReturnsScreen())),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 200));

        // Select the bill
        await tester.tap(find.text('RC-001'));
        await tester.pumpAndSettle();

        // Tap void whole bill
        await tester.tap(find.text('✕ ยกเลิกบิลทั้งบิล').first);
        await tester.pumpAndSettle();

        // Confirm dialog
        expect(find.textContaining('ยกเลิกบิล RC-001 ทั้งบิล?'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'ตกลง'));
        await tester.pumpAndSettle();

        expect(
          find.text('เกิดข้อผิดพลาด: เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์'),
          findsOneWidget,
        );
        expect(find.textContaining('http://'), findsNothing);
        expect(find.textContaining('192.168.1.50'), findsNothing);
        expect(find.textContaining('ClientException'), findsNothing);
        expect(find.textContaining('40000 ms'), findsNothing);
      });
    });

    testWidgets('preserves PosException verdict verbatim', (tester) async {
      setWideViewport(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final saleId = 's-ret-test-2';
      await db.into(db.sales).insert(
        SalesCompanion.insert(
          id: saleId,
          receiptNo: 'RC-002',
          date: DateTime.now(),
          subtotal: 100,
          total: 100,
          paymentMethod: 'เงินสด',
        ),
      );
      await db.into(db.saleItems).insert(
        SaleItemsCompanion.insert(
          saleId: saleId,
          productId: 'p-002',
          name: 'Test Part 2',
          qty: 1,
          price: 100,
        ),
      );

      final returnsRepo = _StubReturnsRepo(db);
      returnsRepo.errorToThrow = const PosException('OVER_REFUND', 'คืนเกินจำนวนที่ขาย');

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: [
              ...repositoryProviders(db),
              RepositoryProvider<ReturnsRepository>.value(value: returnsRepo),
            ],
            child: const MaterialApp(home: Scaffold(body: ReturnsScreen())),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 200));

        await tester.tap(find.text('RC-002'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('✕ ยกเลิกบิลทั้งบิล').first);
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(FilledButton, 'ตกลง'));
        await tester.pumpAndSettle();

        expect(find.text('เกิดข้อผิดพลาด: คืนเกินจำนวนที่ขาย'), findsOneWidget);
      });
    });
  });

  group('CashDrawerScreen error rendering (#199)', () {
    testWidgets('shows canonical Thai sentence and hides URL on ApiTimeoutException', (tester) async {
      setWideViewport(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final shiftsRepo = _StubShiftsRepo(db);
      shiftsRepo.errorToThrow = ApiTimeoutException(
        const Duration(seconds: 40),
        Uri.parse('http://192.168.1.50:3000/api/v1/shifts/open'),
      );

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: [
              ...repositoryProviders(db),
              RepositoryProvider<ShiftsRepository>.value(value: shiftsRepo),
            ],
            child: const MaterialApp(home: Scaffold(body: CashDrawerScreen())),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 200));

        // Tap quick amount chip '฿1,000'
        await tester.tap(find.text('฿1,000'));
        await tester.pumpAndSettle();

        // Tap open drawer button ('เปิดร้าน')
        await tester.tap(find.text('เปิดร้าน'));
        await tester.pumpAndSettle();

        expect(find.text('เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์'), findsOneWidget);
        expect(find.textContaining('http://'), findsNothing);
        expect(find.textContaining('192.168.1.50'), findsNothing);
        expect(find.textContaining('ClientException'), findsNothing);
        expect(find.textContaining('40000 ms'), findsNothing);
      });
    });

    testWidgets('preserves PosException verdict verbatim on addDrawerEntry', (tester) async {
      setWideViewport(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      // Seed an active shift
      await db.into(db.shifts).insert(
        ShiftsCompanion.insert(
          id: 'sh-open',
          dateStr: todayKey(),
          startingCash: 1000,
          openedAt: DateTime.now(),
          isActive: const Value(true),
        ),
      );

      final shiftsRepo = _StubShiftsRepo(db);
      shiftsRepo.errorToThrow = const PosException(
        'DRAWER_CLOSED',
        'ลิ้นชักปิดแล้ว ไม่สามารถบันทึกรายการเงินเพิ่มได้',
      );

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: [
              ...repositoryProviders(db),
              RepositoryProvider<ShiftsRepository>.value(value: shiftsRepo),
            ],
            child: const MaterialApp(home: Scaffold(body: CashDrawerScreen())),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 200));

        // Enter entry amount
        await tester.enterText(
          find.widgetWithText(TextField, 'จำนวนเงิน'),
          '200',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('+ เพิ่ม'));
        await tester.pumpAndSettle();

        expect(
          find.text('ลิ้นชักปิดแล้ว ไม่สามารถบันทึกรายการเงินเพิ่มได้'),
          findsOneWidget,
        );
      });
    });
  });

  group('MechanicsScreen credit payment error rendering (#199)', () {
    testWidgets('shows canonical Thai sentence and hides URL on ApiTimeoutException', (tester) async {
      setWideViewport(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      // Seed mechanic
      await db.into(db.mechanics).insert(
        MechanicsCompanion.insert(
          id: 'm-err-test',
          code: 'M-ERR',
          name: 'ErrMechanic',
          nameTH: const Value('ช่างผิดพลาด'),
          createdAt: '2026-09-15',
          creditBalance: const Value(1000),
          creditLimit: const Value(5000),
        ),
      );

      final mechRepo = _StubMechanicsRepo(db);
      mechRepo.errorToThrow = ApiTimeoutException(
        const Duration(seconds: 40),
        Uri.parse('http://192.168.1.50:3000/api/v1/mechanics/m-err-test/credit-payments'),
      );

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: [
              ...repositoryProviders(db),
              RepositoryProvider<MechanicsRepository>.value(value: mechRepo),
            ],
            child: const MaterialApp(home: Scaffold(body: MechanicsScreen())),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 200));

        // Select mechanic
        await tester.tap(find.textContaining('ช่างผิดพลาด', findRichText: true).first);
        await tester.pumpAndSettle();

        // Tap receive payment
        await tester.tap(find.text('รับชำระ'));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsOneWidget);

        // Enter amount and save
        await tester.enterText(
          find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)).first,
          '500',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('✓ บันทึกการรับเงิน'));
        await tester.pumpAndSettle();

        expect(find.text('เกิดข้อผิดพลาดในการเชื่อมต่อกับเซิร์ฟเวอร์'), findsOneWidget);
        expect(find.textContaining('http://'), findsNothing);
        expect(find.textContaining('192.168.1.50'), findsNothing);
        expect(find.textContaining('ClientException'), findsNothing);
        expect(find.textContaining('40000 ms'), findsNothing);
      });
    });

    testWidgets('preserves PosException verdict verbatim on credit payment', (tester) async {
      setWideViewport(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await db.into(db.mechanics).insert(
        MechanicsCompanion.insert(
          id: 'm-err-test-2',
          code: 'M-ERR2',
          name: 'ErrMechanic2',
          nameTH: const Value('ช่างผิดพลาดสอง'),
          createdAt: '2026-09-15',
          creditBalance: const Value(1000),
          creditLimit: const Value(5000),
        ),
      );

      final mechRepo = _StubMechanicsRepo(db);
      mechRepo.errorToThrow = const PosException('NO_OPEN_SHIFT', 'กรุณาเปิดกะก่อน');

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: [
              ...repositoryProviders(db),
              RepositoryProvider<MechanicsRepository>.value(value: mechRepo),
            ],
            child: const MaterialApp(home: Scaffold(body: MechanicsScreen())),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 200));

        await tester.tap(find.textContaining('ช่างผิดพลาดสอง', findRichText: true).first);
        await tester.pumpAndSettle();

        await tester.tap(find.text('รับชำระ'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)).first,
          '500',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('✓ บันทึกการรับเงิน'));
        await tester.pumpAndSettle();

        expect(find.text('กรุณาเปิดกะก่อน'), findsOneWidget);
      });
    });

    testWidgets('prompts overpayment confirmation on OVERPAYMENT_NOT_ALLOWED (#221)', (tester) async {
      setWideViewport(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await db.into(db.mechanics).insert(
        MechanicsCompanion.insert(
          id: 'm-err-test-3',
          code: 'M-ERR3',
          name: 'ErrMechanic3',
          nameTH: const Value('ช่างชำระเกิน'),
          createdAt: '2026-09-15',
          creditBalance: const Value(1000),
          creditLimit: const Value(5000),
        ),
      );

      final mechRepo = _StubMechanicsRepo(db);
      var receivedAllow = false;
      mechRepo.onAddCreditPayment = ({required allowOverpayment}) async {
        if (!allowOverpayment) {
          throw const PosException(
            'OVERPAYMENT_NOT_ALLOWED',
            'ยอดชำระเกินยอดหนี้คงเหลือ',
            {'creditBalance': 500.0, 'amount': 800.0},
          );
        }
        receivedAllow = true;
        return CreditPaymentRow(
          id: 'cp-ok',
          receiptNo: 'RCP-001',
          mechanicId: 'm-err-test-3',
          amount: 800.0,
          date: DateTime.now(),
        );
      };

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: [
              ...repositoryProviders(db),
              RepositoryProvider<MechanicsRepository>.value(value: mechRepo),
            ],
            child: const MaterialApp(home: Scaffold(body: MechanicsScreen())),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 200));

        await tester.tap(find.textContaining('ช่างชำระเกิน', findRichText: true).first);
        await tester.pumpAndSettle();

        await tester.tap(find.text('รับชำระ'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)).first,
          '800',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('✓ บันทึกการรับเงิน'));
        await tester.pumpAndSettle();

        // Confirmation dialog must appear with updated numbers
        expect(find.text('ยืนยันรับเงิน'), findsOneWidget);
        expect(find.textContaining('เกินยอดค้าง ฿500'), findsOneWidget);

        // Tap confirm 'ตกลง'
        await tester.tap(find.text('ตกลง'));
        await tester.pumpAndSettle();

        expect(receivedAllow, isTrue, reason: 'Must resend with allowOverpayment = true');
      });
    });
  });
}
