// 'ถ่ายรูปหลักฐานสินค้า' on the receipt dialog (10_SALE_PHOTO_EVIDENCE.md §2.1):
// absent on the Drift build, disabled with a reason while Degraded or while this
// bill's sale.create is still in the outbox, otherwise it opens the sheet.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/fake_sale_photos_repository.dart';
import 'package:srisurart_pos/data/repositories/sale_photos_repository.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import 'package:srisurart_pos/presentation/widgets/receipt_view.dart';

import 'support/fake_sync_facade.dart';

final _data = ReceiptData(
  sale: SaleRow(
    id: '0199d4a2-6b0d-7f2e-8a1b-2c3d4e5f6a7b',
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
  ),
  cashReceived: 100,
  change: 0,
);

void main() {
  setUpAll(() => initializeDateFormatting('th'));

  final button = find.byKey(const Key('receipt-photo-evidence'));
  final reason = find.byKey(const Key('receipt-photo-reason'));

  Future<void> pump(
    WidgetTester t, {
    SalePhotosRepository? repo,
    SyncStatus status = SyncStatus.online,
  }) async {
    await t.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<SalePhotosRepository?>.value(value: repo),
          RepositoryProvider<SyncFacade>.value(
            value: FakeSyncFacade(initialStatus: status),
          ),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => showReceiptDialog(context, _data),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
  }

  bool enabled(WidgetTester t) =>
      t.widget<OutlinedButton>(button).onPressed != null;

  testWidgets('Drift build (no repository): no button, receipt unchanged', (
    t,
  ) async {
    await pump(t);
    expect(button, findsNothing);
    expect(find.text('ขายสำเร็จ'), findsOneWidget);
    expect(find.text('พิมพ์ใบเสร็จ'), findsOneWidget);
  });

  testWidgets('online: enabled, no reason; opens the sheet', (t) async {
    await pump(t, repo: FakeSalePhotosRepository());
    expect(find.text('ถ่ายรูปหลักฐานสินค้า'), findsOneWidget);
    expect(enabled(t), isTrue);
    expect(reason, findsNothing);
    await t.tap(button);
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('รูปหลักฐานสินค้า'), findsOneWidget);
  });

  testWidgets('Degraded: disabled, says why', (t) async {
    await pump(
      t,
      repo: FakeSalePhotosRepository(),
      status: SyncStatus.degraded,
    );
    expect(enabled(t), isFalse);
    expect(
      t.widget<Text>(reason).data,
      'ต้องเชื่อมต่ออินเทอร์เน็ตจึงจะถ่ายรูปหลักฐานได้',
    );
  });

  testWidgets('sale.create still in the outbox: disabled, says why', (t) async {
    await pump(t, repo: FakeSalePhotosRepository(pendingSaleCreate: true));
    expect(enabled(t), isFalse);
    expect(
      t.widget<Text>(reason).data,
      'บิลนี้ยังไม่ถึงเซิร์ฟเวอร์ — ถ่ายรูปหลักฐานไม่ได้',
    );
  });
}
