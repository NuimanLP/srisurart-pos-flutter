// A labelled receipt line (โทร / แคชเชียร์) is hidden when its value is null or
// blank, and unchanged when it is set. The shop phone/cashier are optional in Settings.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/presentation/widgets/receipt_view.dart';

ReceiptData _data({String? phone, String? cashier}) => ReceiptData(
      sale: SaleRow(
        id: 's1',
        receiptNo: 'RC01-2569-10-0001',
        subtotal: 100,
        discount: 0,
        total: 100,
        paymentMethod: 'เงินสด',
        pointsGranted: 10,
        date: DateTime(2026, 10, 3, 10, 30),
        voided: false,
        soldOffline: false,
      ),
      items: const [ReceiptLine(name: 'Brake pad', qty: 1, price: 100)],
      settings: SettingsRowData(
        id: 1,
        shopName: 'ร้านศรีสุรัตน์',
        shopNameEN: 'Srisurart Autopart',
        taxRate: 0.07,
        quoteValidDays: 7,
        phone: phone,
        cashierName: cashier,
      ),
      cashReceived: 100,
      change: 0,
    );

Future<void> _pump(WidgetTester t, ReceiptData d) async {
  await t.binding.setSurfaceSize(const Size(900, 1600));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ReceiptView(data: d)))),
  );
}

void main() {
  setUpAll(() => initializeDateFormatting('th'));

  testWidgets('blank phone and cashier print no label line', (t) async {
    await _pump(t, _data(phone: '  ', cashier: null));
    expect(find.textContaining('โทร'), findsNothing);
    expect(find.text('แคชเชียร์'), findsNothing);
    expect(find.text('เลขที่'), findsOneWidget);
  });

  testWidgets('set phone and cashier still print', (t) async {
    await _pump(t, _data(phone: '021234567', cashier: 'สมศรี'));
    expect(find.text('โทร 021234567'), findsOneWidget);
    expect(find.text('แคชเชียร์'), findsOneWidget);
    expect(find.text('สมศรี'), findsOneWidget);
  });
}
