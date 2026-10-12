// UI/UX pass 2026-10-11: on a 390 px phone the full LowStockBanner pushed the
// checkout product grid down to y≈790 until dismissed. At phone width it now
// starts as a one-line strip (both counts) with ดูรายการ to open the same full
// list; ✕ ปิด dismisses exactly as before. Wider screens are unchanged.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/presentation/widgets/low_stock_alert.dart';

ProductRow _p(String partNo, int stock, int minStock) => ProductRow(
  id: partNo,
  partNo: partNo,
  name: 'Part $partNo',
  nameTH: 'อะไหล่ $partNo',
  category: 'เบรก',
  brand: 'X',
  price: 100,
  cost: 50,
  stock: stock,
  minStock: minStock,
);

void main() {
  var closed = 0;

  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    closed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              LowStockBanner(
                outOfStock: [_p('A1', 0, 2)],
                lowStock: [_p('B2', 1, 5), _p('C3', 2, 4)],
                onClose: () => closed++,
                onOrder: () {},
              ),
              const Expanded(child: Placeholder(key: Key('grid'))),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('390 px: one-line strip, grid stays near the top', (
    tester,
  ) async {
    await pump(tester, const Size(390, 844));
    expect(tester.takeException(), isNull);
    expect(
      find.text('พบ 1 รายการหมด + 2 รายการต่ำกว่าขั้นต่ำ'),
      findsOneWidget,
    );
    expect(find.text('Part A1'), findsNothing);
    expect(tester.getTopLeft(find.byKey(const Key('grid'))).dy, lessThan(120));
  });

  testWidgets('390 px: ดูรายการ opens the same full list', (tester) async {
    await pump(tester, const Size(390, 844));
    await tester.tap(find.text('ดูรายการ'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Part A1'), findsOneWidget);
    expect(find.text('Part B2'), findsOneWidget);
    expect(find.text('Part C3'), findsOneWidget);
    expect(find.text('ยังมี 3 รายการที่ยังไม่ได้จัดการ'), findsOneWidget);
  });

  testWidgets('390 px: ✕ ปิด on the strip dismisses', (tester) async {
    await pump(tester, const Size(390, 844));
    await tester.tap(find.text('✕ ปิด'));
    expect(closed, 1);
  });

  testWidgets('tablet width: full banner as before', (tester) async {
    await pump(tester, const Size(820, 1180));
    expect(tester.takeException(), isNull);
    expect(find.text('Part A1'), findsOneWidget);
    expect(find.text('ดูรายการ'), findsNothing);
  });
}
