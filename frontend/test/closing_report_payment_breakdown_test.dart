// #461 regression: the closing report's "วิธีชำระเงิน" breakdown only grouped
// เงินสด and โอน/QR sales, while `รวมทั้งหมด` (`_totalRevenue`) sums every sale
// including เครดิตช่าง (mechanic credit) ones. A day with a เครดิตช่าง bill made
// the two shown rows sum to less than the total, on both the screen and the
// printed report.
//
// `cashSales`/`qrSales`/`creditSales` (closing_report.dart) are the pure
// grouping functions the widget's `_cashSales`/`_qrSales`/`_creditSales`
// delegate to — extracted to top level (like `computeGrossProfit`) so the
// grouping is unit-testable without a widget pump.

import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/presentation/widgets/closing_report.dart';

SaleLite _sale(String paymentMethod, double total) => SaleLite(
  subtotal: total,
  discount: 0,
  total: total,
  paymentMethod: paymentMethod,
  items: const [],
);

double _sumTotal(List<SaleLite> sales) =>
    sales.fold(0, (s, t) => s + t.total);

void main() {
  test(
    'cash + qr + credit sums to total revenue when a mechanic-credit sale exists',
    () {
      final sales = [
        _sale('เงินสด', 100),
        _sale('โอน/QR', 200),
        _sale('เครดิตช่าง', 300),
      ];
      final totalRevenue = _sumTotal(sales);

      final cash = cashSales(sales);
      final qr = qrSales(sales);
      final credit = creditSales(sales);

      expect(cash, hasLength(1));
      expect(qr, hasLength(1));
      expect(credit, hasLength(1));
      expect(
        _sumTotal(cash) + _sumTotal(qr) + _sumTotal(credit),
        totalRevenue,
        reason:
            'the three payment-method groups must fully account for '
            'รวมทั้งหมด whenever a เครดิตช่าง bill is in the day',
      );
    },
  );

  test('every sale lands in exactly one of the three groups', () {
    final sales = [
      _sale('เงินสด', 50),
      _sale('PromptPay', 60), // legacy โอน/QR spelling
      _sale('โอนเงิน', 70), // legacy โอน/QR spelling
      _sale('เครดิตช่าง', 80),
      _sale('เครดิตช่าง', 90),
    ];

    final cash = cashSales(sales);
    final qr = qrSales(sales);
    final credit = creditSales(sales);

    expect(cash.length + qr.length + credit.length, sales.length);
    expect(_sumTotal(credit), 170);
  });

  test('a sale with no credit bills leaves the credit group empty', () {
    final sales = [_sale('เงินสด', 100), _sale('โอน/QR', 200)];

    expect(creditSales(sales), isEmpty);
    expect(
      _sumTotal(cashSales(sales)) + _sumTotal(qrSales(sales)),
      _sumTotal(sales),
    );
  });
}
