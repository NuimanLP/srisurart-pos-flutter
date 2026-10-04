// A Thai-only product name must be enough to save (live test 2026-10-04):
// `products.name` is NOT NULL and the server refuses a blank one, so the form
// falls back to the Thai name; both blank is still refused.
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/presentation/screens/products_screen.dart';

void main() {
  test('Thai-only name is used for both columns', () {
    expect(productNameOrThai('', ' สินค้าทดสอบ UX '), 'สินค้าทดสอบ UX');
    expect(productNameOrThai('   ', 'สินค้าทดสอบ UX'), 'สินค้าทดสอบ UX');
  });

  test('EN name wins when present', () {
    expect(productNameOrThai(' Pad ', 'ผ้าเบรก'), 'Pad');
    expect(productNameOrThai('Pad', ''), 'Pad');
  });

  test('both blank stays empty so the form refuses', () {
    expect(productNameOrThai('', ''), isEmpty);
    expect(productNameOrThai('  ', '  '), isEmpty);
  });
}
