// Regression tests for #402 — ClosingReport's approximate profit must use
// each sale line's `costAtSale` (ADR-0008, `sale_items.cost_at_sale`,
// `tables.dart:142`), never today's product cost, which drifts on every
// weighted-average PO receive.
//
// `computeGrossProfit` (closing_report.dart) is the pure math extracted from
// `_ClosingReportState._grossProfit` specifically so it is unit-testable
// without a widget pump. The fallback chain — costAtSale → current product
// cost → excluded (never silently 0) — mirrors `products_screen.dart`'s
// `_monthly` and `server/src/reports/reports.service.ts`'s `grossProfitCtes`
// (`COALESCE(cost_at_sale, current_cost, 0)` with `estimated_cost_rows` /
// `unknown_cost_rows` tracked for disclosure).

import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/presentation/widgets/closing_report.dart';

SaleLite _saleOf(ItemLite item, {double discount = 0}) {
  final subtotal = item.price * item.qty;
  return SaleLite(
    subtotal: subtotal,
    discount: discount,
    total: subtotal - discount,
    paymentMethod: 'เงินสด',
    items: [item],
  );
}

void main() {
  const taxRate = 7.0;
  const vatDivisor = 1 + taxRate / 100;

  test(
    'uses the recorded costAtSale even after the product cost changes',
    () {
      // Sold at cost 30/unit (ADR-0008 snapshot); the product's current cost
      // later moved to 99/unit via a PO receive — the bill's own profit must
      // not drift with it.
      final item = const ItemLite(
        partNo: 'A1',
        name: 'ผ้าเบรก',
        qty: 2,
        price: 100,
        costAtSale: 30,
        currentCost: 99,
      );
      final result = computeGrossProfit([_saleOf(item)], taxRate);

      final expectedProfit = (100 * 2 / vatDivisor) - (30 * 2);
      expect(result.profit, closeTo(expectedProfit, 0.0001));
      expect(result.estimatedCostLines, 0);
      expect(result.unknownCostLines, 0);
    },
  );

  test(
    'falls back to the current product cost when costAtSale is null (legacy bill)',
    () {
      final item = const ItemLite(
        partNo: 'A2',
        name: 'ไส้กรองอากาศ',
        qty: 3,
        price: 50,
        costAtSale: null,
        currentCost: 20,
      );
      final result = computeGrossProfit([_saleOf(item)], taxRate);

      final expectedProfit = (50 * 3 / vatDivisor) - (20 * 3);
      expect(result.profit, closeTo(expectedProfit, 0.0001));
      expect(result.estimatedCostLines, 1);
      expect(result.unknownCostLines, 0);
    },
  );

  test(
    'never silently costs a line at 0 when neither costAtSale nor the '
    'product exist — the line is excluded and flagged, not free',
    () {
      final item = const ItemLite(
        partNo: 'GONE',
        name: 'สินค้าที่ถูกลบ',
        qty: 1,
        price: 500,
        costAtSale: null,
        currentCost: null,
      );
      final result = computeGrossProfit([_saleOf(item)], taxRate);

      // No cost is subtracted for this line — full revenue reads as profit —
      // but that is flagged via unknownCostLines rather than presented as fact.
      final expectedProfit = 500 / vatDivisor;
      expect(result.profit, closeTo(expectedProfit, 0.0001));
      expect(result.unknownCostLines, 1);
      expect(result.estimatedCostLines, 0);
      expect(costDisclosureLines(result), isNotEmpty);
      expect(
        costDisclosureLines(result).single,
        contains('ไม่มีข้อมูลต้นทุน'),
      );
    },
  );

  test('mixes all three cases across one sale correctly', () {
    final recorded = const ItemLite(
      partNo: 'A1',
      name: 'ผ้าเบรก',
      qty: 1,
      price: 100,
      costAtSale: 40,
      currentCost: 999,
    );
    final legacy = const ItemLite(
      partNo: 'A2',
      name: 'ไส้กรองอากาศ',
      qty: 1,
      price: 100,
      costAtSale: null,
      currentCost: 60,
    );
    final unknown = const ItemLite(
      partNo: 'GONE',
      name: 'สินค้าที่ถูกลบ',
      qty: 1,
      price: 100,
      costAtSale: null,
      currentCost: null,
    );
    final sale = SaleLite(
      subtotal: 300,
      discount: 0,
      total: 300,
      paymentMethod: 'เงินสด',
      items: [recorded, legacy, unknown],
    );
    final result = computeGrossProfit([sale], taxRate);

    final expectedProfit = (300 / vatDivisor) - 40 - 60;
    expect(result.profit, closeTo(expectedProfit, 0.0001));
    expect(result.estimatedCostLines, 1);
    expect(result.unknownCostLines, 1);
    expect(costDisclosureLines(result), hasLength(2));
  });
}
