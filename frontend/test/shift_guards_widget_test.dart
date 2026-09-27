// The counter-side guards of the owner's 2026-09-13 decisions, driven through
// the real screens.
//
//  A — closing the drawer on the API build sends the outbox first and is
//      refused while anything is still in it (08 §11 — the server stamps
//      `shift_id` on arrival, so a late write lands in the next shift).
//  B — no open shift, no credit payment taken: refused at the dialog, never
//      queued (offline it would only be refused during a later flush).
//  C — the overpayment question counts this mechanic's QUEUED payments: debt
//      1,000, 1,000 already queued, 1,000 more must be asked about.
//
// The repository tests prove the rules; these prove the screens reach them and
// show the counter the Thai sentence. Harness mirrors route_smoke_test.dart.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/utils/dates.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api/api_shifts_repository.dart';
import 'package:srisurart_pos/data/repositories/api_mechanics_repository.dart';
import 'package:srisurart_pos/data/repositories/mechanics_repository.dart';
import 'package:srisurart_pos/data/repositories/shifts_repository.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/cash_drawer_screen.dart';
import 'package:srisurart_pos/presentation/screens/mechanics_screen.dart';

/// Records what the pay-credit dialog asked the repository for.
class _RecordingMechanics extends MechanicsRepository {
  _RecordingMechanics(super.db);

  final List<bool> allowOverpayment = [];

  @override
  Future<CreditPaymentRow> addCreditPayment({
    required String mechanicId,
    required double amount,
    String? note,
    required String paymentMethod,
    bool allowOverpayment = false,
  }) {
    this.allowOverpayment.add(allowOverpayment);
    return super.addCreditPayment(
      mechanicId: mechanicId,
      amount: amount,
      note: note,
      paymentMethod: paymentMethod,
      allowOverpayment: allowOverpayment,
    );
  }
}

const _mechanicName = 'ช่างทดสอบกะ';

Future<void> _seedMechanic(AppDatabase db) => db
    .into(db.mechanics)
    .insert(
      MechanicsCompanion.insert(
        id: 'm_guard',
        code: 'M-GUARD',
        name: 'Guard',
        nameTH: const Value(_mechanicName),
        createdAt: '2026-09-13',
        creditBalance: const Value(1000),
        creditLimit: const Value(5000),
      ),
    );

Future<void> _queue(
  AppDatabase db, {
  String id = 'cp-queued',
  String mechanicId = 'm_guard',
  String amount = '1000.00',
  String method = 'เงินสด',
}) => db
    .into(db.pendingCreditPayments)
    .insert(
      PendingCreditPaymentsCompanion.insert(
        id: id,
        idempotencyKey: 'idem-$id',
        mechanicId: mechanicId,
        amount: amount,
        paymentMethod: method,
        createdAt: DateTime(2026, 9, 13, 9),
      ),
    );

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  void sizeView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    AppDatabase db,
    Widget screen, {
    MechanicsRepository? mechanics,
    ShiftsRepository? shifts,
  }) async {
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          ...repositoryProviders(db),
          if (mechanics != null)
            RepositoryProvider<MechanicsRepository>.value(value: mechanics),
          if (shifts != null)
            RepositoryProvider<ShiftsRepository>.value(value: shifts),
        ],
        child: MaterialApp(home: Scaffold(body: screen)),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  /// Selects the seeded mechanic and opens his pay-credit dialog.
  Future<void> openPayDialog(WidgetTester tester) async {
    await tester.tap(
      find.textContaining(_mechanicName, findRichText: true).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('รับชำระ'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  Future<void> typeAmountAndSave(WidgetTester tester, String amount) async {
    await tester.enterText(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          )
          .first,
      amount,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('✓ บันทึกการรับเงิน'));
    await tester.pumpAndSettle();
  }

  group('C — the overpayment check counts queued payments', () {
    testWidgets('1,000 owed, 1,000 queued: taking 1,000 more is asked about', (
      tester,
    ) async {
      sizeView(tester);
      final db = AppDatabase(NativeDatabase.memory());
      final repo = _RecordingMechanics(db);
      await tester.runAsync(() async {
        await _seedMechanic(db);
        await _queue(db);
        // Another mechanic's queued payment must not count against this one.
        await _queue(db, id: 'cp-other', mechanicId: 'someone-else');
        await pumpScreen(tester, db, const MechanicsScreen(), mechanics: repo);

        await openPayDialog(tester);
        // Prefilled with what is still owed once the queue lands: nothing.
        final amountField = tester.widget<TextField>(
          find
              .descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(TextField),
              )
              .first,
        );
        expect(amountField.controller!.text, '0');

        await typeAmountAndSave(tester, '1000');

        expect(
          find.text('ยืนยันรับเงิน'),
          findsOneWidget,
          reason: 'the queued 1,000 already settles the tab',
        );
        expect(repo.allowOverpayment, isEmpty, reason: 'nothing sent yet');
        await tester.tap(find.text('ตกลง'));
        await tester.pumpAndSettle();

        expect(repo.allowOverpayment, [true]);
        await db.close();
      });
    });

    testWidgets('with nothing queued, paying the balance exactly asks nothing', (
      tester,
    ) async {
      sizeView(tester);
      final db = AppDatabase(NativeDatabase.memory());
      final repo = _RecordingMechanics(db);
      await tester.runAsync(() async {
        await _seedMechanic(db);
        await pumpScreen(tester, db, const MechanicsScreen(), mechanics: repo);

        await openPayDialog(tester);
        await typeAmountAndSave(tester, '1000');

        expect(find.text('ยืนยันรับเงิน'), findsNothing);
        expect(repo.allowOverpayment, [false]);
        await db.close();
      });
    });
  });

  testWidgets(
    'B — API build, no open shift: the dialog refuses and nothing is queued',
    (tester) async {
      sizeView(tester);
      final db = AppDatabase(NativeDatabase.memory());
      var requests = 0;
      final repo = ApiMechanicsRepository(
        db,
        ApiClient(
          httpClient: MockClient((_) async {
            requests++;
            throw http.ClientException('Offline');
          }),
        ),
      );
      await tester.runAsync(() async {
        await _seedMechanic(db);
        await pumpScreen(tester, db, const MechanicsScreen(), mechanics: repo);
        final requestsBefore = requests; // the screen's own reads

        await openPayDialog(tester);
        await typeAmountAndSave(tester, '500');

        expect(find.text('กรุณาเปิดกะก่อนรับชำระ'), findsOneWidget);
        expect(
          find.byType(AlertDialog),
          findsOneWidget,
          reason: 'not closed as queued — nothing was taken',
        );
        expect(await db.select(db.pendingCreditPayments).get(), isEmpty);
        expect(requests, requestsBefore);
        await db.close();
      });
    },
  );

  testWidgets(
    'A — API build: closing with a payment still unsent is refused',
    (tester) async {
      sizeView(tester);
      final db = AppDatabase(NativeDatabase.memory());
      var closes = 0;
      final shifts = ApiShiftsRepository(
        api: ApiClient(
          httpClient: MockClient((_) async {
            closes++;
            return http.Response('{}', 500);
          }),
        ),
        db: db,
        drift: ShiftsRepository(db),
        // Nothing reaches a server from here, as offline: the row stays queued.
        mechanics: MechanicsRepository(db),
      );
      await tester.runAsync(() async {
        await db
            .into(db.shifts)
            .insert(
              ShiftsCompanion.insert(
                id: 'sh-today',
                dateStr: todayKey(),
                startingCash: 1000,
                openedAt: DateTime.now(),
                isActive: const Value(true),
              ),
            );
        await _queue(db, amount: '300.00');
        await pumpScreen(tester, db, const CashDrawerScreen(), shifts: shifts);

        await tester.tap(find.text('🔒 ปิดลิ้นชัก'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '1000');
        await tester.pumpAndSettle();
        await tester.tap(find.text('🔒 ยืนยันปิดลิ้นชัก'));
        await tester.pumpAndSettle();

        expect(
          find.text(
            'ยังมี 1 รายการติดปัญหา / ค้างส่ง '
            '— ต้องส่งเข้าระบบให้หมดก่อนปิดกะ',
          ),
          findsOneWidget,
        );
        expect(closes, 0, reason: 'the close must never be sent');
        final shift = await db.select(db.shifts).getSingle();
        expect(shift.closedAt, isNull);
        await db.close();
      });
    },
  );
}
