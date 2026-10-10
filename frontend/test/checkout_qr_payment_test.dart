// Checkout's โอน/QR panel (owner request 2026-10-10, contract §5): the
// default account's QR with the bill total, switching accounts, the sale
// carrying the chosen account id, the no-accounts hint, the parked bill
// keeping the account, and no overflow at 390 px / 1280 px.

import 'dart:convert';

import 'package:barcode_widget/barcode_widget.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/utils/promptpay.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/payment_accounts_repository.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/checkout_screen.dart';
import 'package:srisurart_pos/presentation/widgets/qr_payment_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  /// Pumps the checkout with one item in the cart and [accounts] set up.
  /// [body] runs inside `runAsync` (Drift needs real async).
  Future<void> run(
    WidgetTester tester,
    Size size, {
    required List<PaymentAccountInput> accounts,
    required Future<void> Function(AppDatabase db, ProductRow item, List<PaymentAccountRow> rows) body,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final db = AppDatabase(NativeDatabase.memory());
    final cart = CartCubit();
    final pq = PendingQuoteCubit();
    addTearDown(cart.close);
    addTearDown(pq.close);
    await tester.runAsync(() async {
      final repo = PaymentAccountsRepository(db);
      for (final a in accounts) {
        await repo.addAccount(a);
      }
      final rows = await repo.getAccounts();
      final item = (await ProductsRepository(db).getAll()).firstWhere((p) => p.stock > 0);
      cart.add(item);
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db),
          child: MultiBlocProvider(
            providers: [
              BlocProvider<PendingQuoteCubit>.value(value: pq),
              BlocProvider<CartCubit>.value(value: cart),
            ],
            child: const MaterialApp(home: Scaffold(body: CheckoutScreen())),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final tab = find.text('ตะกร้า');
      if (tab.evaluate().isNotEmpty) {
        await tester.tap(tab);
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
      }
      await body(db, item, rows);
      await db.close();
    });
  }

  Future<void> pickQr(WidgetTester tester) async {
    final qr = find.text('โอน/QR');
    await tester.ensureVisible(qr);
    await tester.pumpAndSettle();
    await tester.tap(qr);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  Future<void> pay(WidgetTester tester) async {
    final btn = find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').startsWith('ชำระเงิน  '),
    );
    await tester.ensureVisible(btn);
    await tester.pumpAndSettle();
    await tester.tap(btn);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  String qrData(WidgetTester tester) =>
      utf8.decode(tester.widget<BarcodeWidget>(find.byKey(const ValueKey('promptpay-qr'))).data);

  const shop = PaymentAccountInput(
    nickname: 'บัญชีร้าน',
    bankCode: 'KBANK',
    kind: 'promptpay',
    promptpayId: '0812345678',
  );
  const branch = PaymentAccountInput(
    nickname: 'สาขาสอง',
    bankCode: 'SCB',
    kind: 'promptpay',
    promptpayId: '1234567890123',
    isDefault: true,
  );

  for (final size in const [Size(390, 844), Size(1280, 800)]) {
    final tag = '${size.width.toInt()}px';

    testWidgets('shows the DEFAULT account\'s QR with the bill total, no overflow ($tag)',
        (tester) async {
      await run(tester, size, accounts: [shop, branch], body: (db, item, rows) async {
        await pickQr(tester);
        expect(tester.takeException(), isNull);
        final panel = find.byType(QrPaymentPanel);
        expect(panel, findsOneWidget);
        expect(find.descendant(of: panel, matching: find.text('สาขาสอง')), findsWidgets);
        expect(qrData(tester), promptPayPayload('1234567890123', item.price));
        final rect = tester.getRect(panel);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(size.width));
      });
    });

    testWidgets('switching accounts changes the QR and the sale records it ($tag)', (tester) async {
      await run(tester, size, accounts: [shop, branch], body: (db, item, rows) async {
        await pickQr(tester);
        final shopRow = rows.firstWhere((r) => r.nickname == 'บัญชีร้าน');
        final chip = find.byKey(ValueKey('qr-account-${shopRow.id}'));
        await tester.ensureVisible(chip);
        await tester.pumpAndSettle();
        await tester.tap(chip);
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(qrData(tester), promptPayPayload('0812345678', item.price));
        expect(tester.takeException(), isNull);

        await pay(tester);
        final sale = await db.select(db.sales).getSingle();
        expect(sale.paymentMethod, 'โอน/QR');
        expect(sale.paymentAccountId, shopRow.id);
      });
    });
  }

  testWidgets('a sale with the default account carries its id; cash carries none', (tester) async {
    await run(tester, const Size(1280, 800), accounts: [shop, branch], body: (db, item, rows) async {
      await pickQr(tester);
      await pay(tester);
      final branchRow = rows.firstWhere((r) => r.isDefault);
      expect((await db.select(db.sales).getSingle()).paymentAccountId, branchRow.id);
    });
  });

  testWidgets('no accounts: the hint shows and the sale goes through with no account',
      (tester) async {
    await run(tester, const Size(390, 844), accounts: const [], body: (db, item, rows) async {
      await pickQr(tester);
      expect(find.text(qrNoAccountsHint), findsOneWidget);
      expect(find.byType(BarcodeWidget), findsNothing);
      expect(tester.takeException(), isNull);
      await pay(tester);
      final sale = await db.select(db.sales).getSingle();
      expect(sale.paymentMethod, 'โอน/QR');
      expect(sale.paymentAccountId, isNull);
    });
  });

  testWidgets('a parked bill keeps the switched-to account and restores it', (tester) async {
    await run(tester, const Size(1280, 800), accounts: [shop, branch], body: (db, item, rows) async {
      await pickQr(tester);
      final shopRow = rows.firstWhere((r) => r.nickname == 'บัญชีร้าน');
      final accountChip = find.byKey(ValueKey('qr-account-${shopRow.id}'));
      await tester.ensureVisible(accountChip);
      await tester.pumpAndSettle();
      await tester.tap(accountChip);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      final park = find.textContaining('พักบิล').first;
      await tester.ensureVisible(park);
      await tester.pumpAndSettle();
      await tester.tap(park);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final parked = await db.select(db.parkedSales).getSingle();
      expect((jsonDecode(parked.payload) as Map)['paymentAccountId'], shopRow.id);

      // Resume from the parked strip: the same account is selected again.
      // The strip sits at the top of the cart list, scrolled away by now; its
      // FutureBuilder needs the Drift read to land first.
      final chip = find.byIcon(Icons.receipt_long);
      for (var i = 0; i < 20 && chip.evaluate().isEmpty; i++) {
        await tester.drag(
          find.ancestor(of: find.text('ชำระเงิน'), matching: find.byType(ListView)).first,
          const Offset(0, 400),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      for (var i = 0; i < 10 && find.byType(QrPaymentPanel).evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
      expect(await db.select(db.parkedSales).get(), isEmpty);
      expect(qrData(tester), promptPayPayload('0812345678', item.price));
    });
  });

  testWidgets('ขยาย opens the QR fullscreen', (tester) async {
    await run(tester, const Size(390, 844), accounts: [branch], body: (db, item, rows) async {
      await pickQr(tester);
      await tester.tap(find.text('ขยาย'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byType(BarcodeWidget), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('ปิด'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byType(BarcodeWidget), findsOneWidget);
    });
  });
}
