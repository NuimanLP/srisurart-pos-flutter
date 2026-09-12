// The counter's answer to 'ยืนยันขายเครดิต?' must reach the repository.
//
// `SaleInput.overrideCreditLimit` exists because consent cannot be re-derived
// (#56): the server answers `409 CREDIT_LIMIT_EXCEEDED` unless the body carries
// the flag, and the first implementation tried to work out for itself whether a
// human had confirmed by replaying this screen's own
// `creditBalance + total > creditLimit` test against the cached mechanic row.
// That is not the same read — this screen tests the MechanicRow it captured when
// its list loaded, and any later reader sees a row a prior bill has already
// moved — so it could override a limit nobody was shown a dialog for, and the
// server would log an override that never happened.
//
// The wiring is three lines and invisible: nothing fails loudly if a refactor
// drops them, the bills just quietly start being refused (or, worse, the flag
// gets defaulted to true to make them go through). So it is pinned here, by
// driving the real dialog rather than by asserting on the screen's internals.
//
// Harness mirrors quote_to_checkout_test.dart.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/checkout_screen.dart';

/// Records the `SaleInput` the screen built, then refuses the sale.
///
/// Refusing rather than completing is deliberate: what is under test is the
/// input the screen *builds*, and letting the sale succeed sends the screen into
/// the whole post-sale path — settings read, customer re-fetch, receipt dialog —
/// whose async tail outlives the test and surfaces as an unrelated "State no
/// longer has a context" failure. The screen already has a `catch` for this and
/// shows a toast, which is a quiet place to stop.
class _CapturingSales extends SalesRepository {
  _CapturingSales(super.db, {this.refuseFirstOverLimit = false});

  /// Answer the first call the way a server does when THIS screen's cached
  /// mechanic row is out of date — the multi-device case the pre-emptive
  /// dialog structurally cannot see.
  final bool refuseFirstOverLimit;

  final List<SaleInput> inputs = [];
  SaleInput? get captured => inputs.isEmpty ? null : inputs.last;

  @override
  Future<SaleRow> saveSale(SaleInput input) async {
    inputs.add(input);
    if (refuseFirstOverLimit && inputs.length == 1) {
      throw const PosException(
        'CREDIT_LIMIT_EXCEEDED',
        'เกินวงเงินเครดิต',
        {
          'creditLimit': '10000.00',
          'creditBalance': '9900.00',
          'newBalance': '10400.00',
        },
      );
    }
    throw Exception('test stops here — the input has been captured');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  /// Drives a whole credit sale to the mechanic seeded with a 5,000 limit, and
  /// hands back the `SaleInput` the screen produced.
  Future<_CapturingSales> runCreditSale(
    WidgetTester tester, {
    required bool overLimit,
    required bool confirmDialog,
    bool serverRefusesOnce = false,
  }) async {
    // Tall enough that the whole checkout column is laid out in one pass, and
    // wide enough that the mechanic card's row does not overflow — a narrower
    // viewport fails on layout before any of this test's assertions run.
    tester.view.physicalSize = const Size(1800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final sales = _CapturingSales(db, refuseFirstOverLimit: serverRefusesOnce);
    final cartCubit = CartCubit();
    final pendingQuoteCubit = PendingQuoteCubit();
    addTearDown(cartCubit.close);
    addTearDown(pendingQuoteCubit.close);

    await tester.runAsync(() async {
      // The limit rather than the balance is moved, and every seeded mechanic
      // is moved the same way, so the case holds whichever one the picker lands
      // on and whatever the seeded products happen to cost. A limit of 0 makes
      // any credit bill at all trip `newBal > creditLimit`; ฿900,000 makes none
      // of them trip while still being a number the credit panel can lay out.
      final mechanics = await db.select(db.mechanics).get();
      final mech = mechanics.first;
      await db.update(db.mechanics).write(
        MechanicsCompanion(
          creditBalance: const Value(0),
          creditLimit: Value(overLimit ? 0 : 900000),
        ),
      );

      final p = (await ProductsRepository(db).getAll()).firstWhere(
        (x) => x.stock >= 1,
      );
      expect(cartCubit.add(p), isNull, reason: 'the seeded product has stock');

      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db),
          child: RepositoryProvider<SalesRepository>.value(
            value: sales,
            child: MultiBlocProvider(
              providers: [
                BlocProvider<PendingQuoteCubit>.value(value: pendingQuoteCubit),
                BlocProvider<CartCubit>.value(value: cartCubit),
              ],
              child: MaterialApp(
                home: Builder(
                  // The bundled Sarabun is not loaded in tests (runtime fetching
                  // is off, as everywhere in this suite) and the fallback face is
                  // wider, which overflows the '🔧 ช่าง (ปรับราคาช่าง)' label by
                  // 42px and fails the test on layout before it asserts
                  // anything. Scaling the text down is a test-environment
                  // correction, not a claim about the real layout.
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: const TextScaler.linear(0.8)),
                    child: const Scaffold(body: CheckoutScreen()),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      // Pick the mechanic: the picker only lists results once searched.
      await tester.enterText(
        find.widgetWithText(TextField, 'ค้นหาช่าง / ชื่อเล่น / เบอร์…'),
        mech.nameTH ?? mech.name,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(mech.nameTH ?? mech.name).last);
      await tester.pumpAndSettle();

      // 'เครดิตช่าง' only appears as a payment method once a mechanic is
      // picked, and the button appends ' ⚠' when the bill would pass his limit —
      // so match the prefix, not the whole label.
      await tester.tap(
        find
            .byWidgetPredicate(
              (w) => w is Text && (w.data ?? '').startsWith('เครดิตช่าง'),
            )
            .last,
      );
      await tester.pumpAndSettle();

      // The pay button is labelled 'ชำระเงิน  ฿N' — match on the prefix so a
      // change to the amount formatting does not silently skip the tap.
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is Text && (w.data ?? '').startsWith('ชำระเงิน  '),
        ),
      );
      await tester.pumpAndSettle();

      if (find.text('ยืนยัน').evaluate().isNotEmpty) {
        await tester.tap(find.text(confirmDialog ? 'ยืนยัน' : 'ยกเลิก'));
        await tester.pumpAndSettle();
      }

      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      if (sales.inputs.isEmpty) throw StateError('saveSale was never called');
    });
    return sales;
  }

  testWidgets('confirming the over-limit dialog carries overrideCreditLimit', (
    tester,
  ) async {
    // A credit limit of 0: any bill at all trips it, so the dialog is shown.
    final input = (await runCreditSale(
      tester,
      overLimit: true,
      confirmDialog: true,
    )).captured!;

    expect(input.paymentMethod, 'เครดิตช่าง');
    expect(
      input.overrideCreditLimit,
      isTrue,
      reason: 'the dialog was confirmed, so the server must be told',
    );
  });

  testWidgets('a bill within the limit never carries it', (tester) async {
    // No dialog is shown at all, so nothing may set the flag.
    final input = (await runCreditSale(
      tester,
      overLimit: false,
      confirmDialog: false,
    )).captured!;

    expect(input.paymentMethod, 'เครดิตช่าง');
    expect(
      input.overrideCreditLimit,
      isFalse,
      reason: 'no human was asked, so the bill must not claim one was',
    );
  });

  testWidgets(
    'a 409 the local cache could not predict is asked again, not a dead end',
    (tester) async {
      // The cached mechanic row says there is room, so the pre-emptive dialog
      // never fires and the bill goes out with the flag false. The server, which
      // reads the row another till has already moved, refuses it. Before this
      // branch existed that refusal repeated on every press with no way through
      // — and selling over a regular mechanic's limit is a daily operation here.
      final sales = await runCreditSale(
        tester,
        overLimit: false,
        confirmDialog: true,
        serverRefusesOnce: true,
      );

      expect(sales.inputs, hasLength(2), reason: 'the bill must be resent');
      expect(
        sales.inputs.first.overrideCreditLimit,
        isFalse,
        reason: 'nothing was shown to a human before the server answered',
      );
      expect(
        sales.inputs.last.overrideCreditLimit,
        isTrue,
        reason: 'the counter confirmed the servers own numbers',
      );
    },
  );

  testWidgets('and refusing that dialog sends nothing more', (tester) async {
    final sales = await runCreditSale(
      tester,
      overLimit: false,
      confirmDialog: false,
      serverRefusesOnce: true,
    );

    expect(sales.inputs, hasLength(1));
    expect(sales.inputs.single.overrideCreditLimit, isFalse);
  });
}
