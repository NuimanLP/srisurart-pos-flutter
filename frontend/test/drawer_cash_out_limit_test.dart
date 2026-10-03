// Owner decision 2026-10-03 (mob04 screenshot: ฿2,000 drawer, ฿1,000 + ฿1,000
// + ฿500 out → "เงินในลิ้นชักที่ควรมี" ฿-500): a cash-out larger than the
// drawer's expected cash is REFUSED — on the Drift build, the API build's
// offline queue, and the screen; cash-in is never limited. The expected cash
// is ONE rule, `ShiftsRepository.drawerCash`, counted by shift (owner
// 2026-10-03).
//
// The Thai string `เงินในลิ้นชักไม่พอ (มี ฿X)` was ratified by the owner 2026-10-03
// (PR #580, 02_API_SCREENS §8.1).

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/core/utils/dates.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api/api_shifts_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/data/repositories/shifts_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/cash_drawer_screen.dart';

Matcher _insufficient(String message) => isA<PosException>()
    .having((e) => e.code, 'code', 'DRAWER_INSUFFICIENT_CASH')
    .having((e) => e.message, 'message', message);

/// Counts calls — the screen's pre-check must refuse without one.
class _CountingShifts extends ShiftsRepository {
  _CountingShifts(super.db);
  int addCalls = 0;

  @override
  Future<DrawerEntryRow> addDrawerEntry(
    String type,
    double amount,
    String? note,
  ) {
    addCalls++;
    return super.addDrawerEntry(type, amount, note);
  }
}

void main() {
  late AppDatabase db;
  late ShiftsRepository shifts;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    shifts = ShiftsRepository(db);
  });

  tearDown(() => db.close());

  Future<int> entryCount() async =>
      (await db.select(db.drawerEntries).get()).length;

  group('the message (owner-ratified 2026-10-03)', () {
    test('with and without the amount', () {
      expect(drawerInsufficientCashMessage(), 'เงินในลิ้นชักไม่พอ');
      expect(drawerInsufficientCashMessage(0), 'เงินในลิ้นชักไม่พอ (มี ฿0)');
      expect(
        drawerInsufficientCashMessage(1105.5),
        'เงินในลิ้นชักไม่พอ (มี ฿1,105.5)',
      );
    });

    test('exceedsDrawer compares whole satang', () {
      expect(exceedsDrawer(100, 100), isFalse);
      expect(exceedsDrawer(100.01, 100), isTrue);
      expect(exceedsDrawer(0.1 + 0.2, 0.3), isFalse);
    });
  });

  group('ShiftsRepository.addDrawerEntry (Drift build)', () {
    test(
      'the owner’s screenshot: 2,000 − 1,000 − 1,000, then 500 is refused',
      () async {
        await shifts.openShift(2000);
        await shifts.addDrawerEntry('out', 1000, null);
        await shifts.addDrawerEntry('out', 1000, null);

        await expectLater(
          shifts.addDrawerEntry('out', 500, null),
          throwsA(_insufficient('เงินในลิ้นชักไม่พอ (มี ฿0)')),
        );
        expect(await entryCount(), 2);
      },
    );

    test('accepted at exactly the expected cash, refused at +0.01', () async {
      await shifts.openShift(1000);
      await shifts.addDrawerEntry('in', 20.5, null);
      final expected = (await shifts.drawerCash(
        (await shifts.getCashDrawer())!,
      )).expected;
      expect(expected, 1020.5);

      await expectLater(
        shifts.addDrawerEntry('out', 1020.51, null),
        throwsA(_insufficient('เงินในลิ้นชักไม่พอ (มี ฿1,020.5)')),
      );
      await shifts.addDrawerEntry('out', 1020.5, null);
      expect(await entryCount(), 2);
    });

    test('cash-in is never limited', () async {
      await shifts.openShift(100);
      await shifts.addDrawerEntry('out', 100, null);
      await shifts.addDrawerEntry('in', 5000, null);
      expect(await entryCount(), 2);
    });

    test('a second shift counts only its own money (by shift)', () async {
      final now = DateTime.now();
      final day = dayBounds(now);
      // Shift 1 from midnight with a ฿999 cash bill; shift 2 opened since.
      await db
          .into(db.shifts)
          .insert(
            ShiftsCompanion.insert(
              id: 'sh1',
              dateStr: todayKey(),
              startingCash: 300,
              openedAt: day.from,
              closedAt: Value(day.from.add(const Duration(seconds: 5))),
              isActive: const Value(false),
            ),
          );
      await db
          .into(db.sales)
          .insert(
            SalesCompanion.insert(
              id: 'early',
              receiptNo: 'RC-EARLY',
              subtotal: 999,
              total: 999,
              paymentMethod: 'เงินสด',
              date: day.from.add(const Duration(seconds: 1)),
            ),
          );
      await db
          .into(db.shifts)
          .insert(
            ShiftsCompanion.insert(
              id: 'sh2',
              dateStr: todayKey(),
              startingCash: 500,
              openedAt: now.subtract(const Duration(seconds: 2)),
              isActive: const Value(true),
            ),
          );

      await expectLater(
        shifts.addDrawerEntry('out', 500.01, null),
        throwsA(_insufficient('เงินในลิ้นชักไม่พอ (มี ฿500)')),
      );
      await shifts.addDrawerEntry('out', 500, null);
    });

    test(
      'drawerCash counts cash sales and cash credit payments, never transfers — '
      'the same pieces the screen shows',
      () async {
        await db
            .into(db.products)
            .insert(
              ProductsCompanion.insert(
                id: 'drw-p1',
                partNo: 'P-1',
                name: 'Widget',
                nameTH: 'วิดเจ็ต',
                category: 'general',
                brand: 'X',
                price: 150,
                cost: 80,
                stock: 50,
                minStock: 0,
              ),
            );
        await shifts.openShift(1000);
        Future<SaleRow> sell(String method) => SalesRepository(db).saveSale(
          SaleInput(
            subtotal: 150,
            discount: 0,
            total: 150,
            paymentMethod: method,
            items: const [
              SaleLineInput(
                productId: 'drw-p1',
                partNo: 'P-1',
                name: 'Widget',
                qty: 1,
                price: 150,
              ),
            ],
          ),
        );
        await sell('เงินสด');
        await sell('โอน/QR'); // not cash
        await db
            .into(db.mechanics)
            .insert(
              MechanicsCompanion.insert(
                id: 'drw-m1',
                code: 'M001',
                name: 'ช่าง',
                createdAt: DateTime.now().toIso8601String(),
              ),
            );
        for (final (id, note, amount) in [
          ('cp1', 'เงินสด', 40.0),
          ('cp2', 'โอน/QR · x', 70.0),
        ]) {
          await db
              .into(db.creditPayments)
              .insert(
                CreditPaymentsCompanion.insert(
                  id: id,
                  receiptNo: 'CP-$id',
                  mechanicId: 'drw-m1',
                  amount: amount,
                  note: Value(note),
                  date: DateTime.now(),
                ),
              );
        }
        await shifts.addDrawerEntry('out', 10, null);

        final cash = await shifts.drawerCash((await shifts.getCashDrawer())!);
        expect(cash.cashSales, 150);
        expect(cash.cashCreditPayments, 40);
        expect(cash.totalOut, 10);
        expect(cash.expected, 1000 + 150 + 40 - 10);
      },
    );
  });

  group('agrees with the server on the shared by-shift fixture '
      '(docs/Backend_design/fixtures/drawer-cash/agreement.json)', () {
    var file = File('../docs/Backend_design/fixtures/drawer-cash/agreement.json');
    if (!file.existsSync()) {
      file = File('docs/Backend_design/fixtures/drawer-cash/agreement.json');
    }
    final f = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    double money(Object? v) => double.parse(v as String);
    DateTime at(Object? v) => DateTime.parse(v as String);
    List<Map<String, dynamic>> rows(String k) =>
        (f[k] as List).cast<Map<String, dynamic>>();

    // API build: Sales.shiftId stamped. Drift build: never stamped - the sale
    // is then attributed by its date in the shift's interval.
    for (final stampSaleShift in [true, false]) {
      test(stampSaleShift ? 'sales carry shiftId' : 'sales carry no shiftId', () async {
        for (final sh in rows('shifts')) {
          await db
              .into(db.shifts)
              .insert(
                ShiftsCompanion.insert(
                  id: sh['id'] as String,
                  dateStr: (sh['openedAt'] as String).substring(0, 10),
                  startingCash: money(sh['startingCash']),
                  openedAt: at(sh['openedAt']),
                  closedAt: Value(at(sh['closedAt'])),
                  isActive: const Value(false),
                ),
              );
        }
        for (final s in rows('sales')) {
          await db
              .into(db.sales)
              .insert(
                SalesCompanion.insert(
                  id: s['id'] as String,
                  receiptNo: 'RC-${s['id']}',
                  subtotal: money(s['total']),
                  total: money(s['total']),
                  paymentMethod: s['paymentMethod'] as String,
                  date: at(s['at']),
                  voided: Value(s['voided'] as bool),
                  shiftId: Value(stampSaleShift ? s['shift'] as String : null),
                ),
              );
        }
        for (final r in rows('returns')) {
          await db
              .into(db.returns)
              .insert(
                ReturnsCompanion.insert(
                  id: r['id'] as String,
                  cnNo: 'CN-${r['id']}',
                  saleId: r['saleId'] as String,
                  receiptNo: 'RC-${r['saleId']}',
                  refundSubtotal: money(r['refundTotal']),
                  refundDiscount: 0,
                  refundTotal: money(r['refundTotal']),
                  refundMethod: r['refundMethod'] as String,
                  date: at(r['at']),
                ),
              );
        }
        await db
            .into(db.mechanics)
            .insert(
              MechanicsCompanion.insert(
                id: 'm-fx',
                code: 'M901',
                name: 'ช่างทดสอบ',
                createdAt: DateTime.now().toIso8601String(),
              ),
            );
        for (final cp in rows('creditPayments')) {
          await db
              .into(db.creditPayments)
              .insert(
                CreditPaymentsCompanion.insert(
                  id: cp['id'] as String,
                  receiptNo: 'CP-${cp['id']}',
                  mechanicId: 'm-fx',
                  amount: money(cp['amount']),
                  // The Drift table keeps the method as the note's lead segment.
                  note: Value(cp['method'] as String),
                  date: at(cp['at']),
                ),
              );
        }
        for (final e in rows('entries')) {
          await db
              .into(db.drawerEntries)
              .insert(
                DrawerEntryRow(
                  id: e['id'] as String,
                  shiftId: e['shift'] as String,
                  type: e['type'] as String,
                  amount: money(e['amount']),
                  note: '',
                  createdAt: at(e['at']),
                ),
              );
        }

        final got = <String, String>{};
        for (final drawer in await shifts.getShiftHistory()) {
          got[drawer.shift.id] = (await shifts.drawerCash(
            drawer,
          )).expected.toStringAsFixed(2);
        }
        expect(got, (f['expectedCash'] as Map).cast<String, String>());
      });
    }
  });

  group('ApiShiftsRepository', () {
    ApiShiftsRepository repoWith(MockClient client) => ApiShiftsRepository(
      api: ApiClient(baseUrl: 'http://example.com', httpClient: client),
      db: db,
      drift: shifts,
    );

    test('a server 409 DRAWER_INSUFFICIENT_CASH reaches the caller as a Thai '
        'PosException, never an ApiException', () async {
      final repo = repoWith(
        MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'status': 'error',
                'error': {
                  'code': 'DRAWER_INSUFFICIENT_CASH',
                  'message':
                      'Cash out exceeds the cash the drawer should hold.',
                  'details': {'expectedCash': '0.00'},
                },
              }),
            ),
            409,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      await expectLater(
        repo.addDrawerEntry('out', 500, null),
        throwsA(
          isA<PosException>()
              .having((e) => e.code, 'code', 'DRAWER_INSUFFICIENT_CASH')
              .having((e) => e.message, 'message', 'เงินในลิ้นชักไม่พอ')
              .having((e) => e.details, 'details', {'expectedCash': '0.00'}),
        ),
      );
    });

    test('drawerCash is the Drift number (one rule on both builds)', () async {
      await shifts.openShift(750);
      final repo = repoWith(MockClient((_) async => fail('no network')));
      final drawer = (await shifts.getCashDrawer())!;
      expect(
        (await repo.drawerCash(drawer)).expected,
        (await shifts.drawerCash(drawer)).expected,
      );
    });
  });

  group('CashDrawerScreen pre-check', () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      GoogleFonts.config.allowRuntimeFetching = false;
      await initializeDateFormatting('th', null);
    });

    testWidgets('refuses an over-limit cash-out without calling the repo', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await db
          .into(db.shifts)
          .insert(
            ShiftsCompanion.insert(
              id: 'sh-open',
              dateStr: todayKey(),
              startingCash: 300,
              openedAt: DateTime.now(),
              isActive: const Value(true),
            ),
          );
      final repo = _CountingShifts(db);

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: [
              ...repositoryProviders(db),
              RepositoryProvider<ShiftsRepository>.value(value: repo),
            ],
            child: const MaterialApp(home: Scaffold(body: CashDrawerScreen())),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 200));

        await tester.enterText(
          find.widgetWithText(TextField, 'จำนวนเงิน'),
          '300.01',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('+ เพิ่ม'));
        await tester.pumpAndSettle();

        expect(find.text('เงินในลิ้นชักไม่พอ (มี ฿300)'), findsOneWidget);
        expect(repo.addCalls, 0);
      });
    });
  });
}
