// The closing report's โอน/QR row split by account (owner 2026-10-10,
// contract §5): known accounts by nickname, deleted ones as บัญชีที่ลบแล้ว, no
// account as ไม่ระบุบัญชี — and the split always sums to the โอน/QR total.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/payment_accounts_repository.dart';
import 'package:srisurart_pos/data/repositories/sales_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/domain/reports/net_sales.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/widgets/closing_report.dart';

SaleLite _sale(String id, String method, double total, [String? account]) =>
    SaleLite(
      id: id,
      subtotal: total,
      discount: 0,
      total: total,
      paymentMethod: method,
      paymentAccountId: account,
      items: const [],
    );

PaymentAccountRow _acct(String id, String nickname) => PaymentAccountRow(
      id: id,
      nickname: nickname,
      bankCode: 'KBANK',
      kind: 'promptpay',
      promptpayId: '0812345678',
      isDefault: false,
      sortOrder: 0,
    );

void main() {
  group('NetSales.qrByAccount + qrAccountRows', () {
    test('splits by account, refunds off the original bill\'s account, sums to the QR row', () {
      final net = NetSales.of(
        [
          _sale('s1', 'โอน/QR', 300, 'pa1'),
          _sale('s2', 'โอน/QR', 200, 'pa2'),
          _sale('s3', 'โอน/QR', 100, 'pa-deleted'),
          _sale('s4', 'โอน/QR', 50),
          _sale('s5', 'PromptPay', 25), // legacy spelling, no account
          _sale('s6', 'เงินสด', 999, 'pa1'), // cash never counts here
        ],
        const [
          ReturnLite(saleId: 's1', refundTotal: 40, refundMethod: 'โอน', items: [], saleAccountId: 'pa1'),
          // A transfer refund of a cash bill: no account to take it off.
          ReturnLite(saleId: 's6', refundTotal: 10, refundMethod: 'โอน', items: []),
        ],
      );
      expect(net.qr.bills, 5);
      expect(net.qr.net, 300 + 200 + 100 + 50 + 25 - 40 - 10);

      final rows = qrAccountRows(net.qrByAccount, [_acct('pa2', 'สาขา 2'), _acct('pa1', 'บัญชีร้าน')]);
      expect(rows, [
        (label: 'สาขา 2', bills: 1, net: 200.0),
        (label: 'บัญชีร้าน', bills: 1, net: 260.0),
        (label: qrDeletedAccountLabel, bills: 1, net: 100.0),
        (label: qrNoAccountLabel, bills: 2, net: 65.0),
      ]);
      expect(rows.fold<double>(0, (a, r) => a + r.net), net.qr.net);
    });

    test('several deleted accounts merge into one row', () {
      final net = NetSales.of([
        _sale('s1', 'โอน/QR', 100, 'gone-1'),
        _sale('s2', 'โอน/QR', 50, 'gone-2'),
      ], const []);
      expect(qrAccountRows(net.qrByAccount, const []), [
        (label: qrDeletedAccountLabel, bills: 2, net: 150.0),
      ]);
    });

    test('no โอน/QR money: no breakdown rows', () {
      final net = NetSales.of([_sale('s1', 'เงินสด', 100)], const []);
      expect(qrAccountRows(net.qrByAccount, [_acct('pa1', 'บัญชีร้าน')]), isEmpty);
    });
  });

  testWidgets('the closing report lists the โอน/QR bills under each account', (tester) async {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final db = AppDatabase(NativeDatabase.memory());
    Object? caught;
    await tester.runAsync(() async {
      final account = await PaymentAccountsRepository(db).addAccount(const PaymentAccountInput(
        nickname: 'บัญชีร้านหลัก',
        bankCode: 'SCB',
        kind: 'promptpay',
        promptpayId: '0812345678',
      ));
      final p = (await db.select(db.products).get()).first;
      SaleInput sale(String? acct) => SaleInput(
            subtotal: p.price,
            discount: 0,
            total: p.price,
            paymentMethod: 'โอน/QR',
            paymentAccountId: acct,
            items: [SaleLineInput(productId: p.id, name: p.name, qty: 1, price: p.price)],
          );
      await SalesRepository(db).saveSale(sale(account.id));
      await SalesRepository(db).saveSale(sale(null));

      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db, useApiRepositories: false),
          child: const MaterialApp(home: Scaffold(body: ClosingReport())),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      caught = tester.takeException();
    });
    expect(caught, isNull);
    expect(find.textContaining('บัญชีร้านหลัก'), findsOneWidget);
    expect(find.textContaining(qrNoAccountLabel), findsOneWidget);
    await tester.runAsync(db.close);
  });
}
