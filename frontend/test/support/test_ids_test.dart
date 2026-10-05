import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/core/utils/ids.dart';

import 'test_ids.dart';

final _canonical =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

void main() {
  test('newUuid is a canonical lowercase UUIDv7', () {
    final id = newUuid();
    expect(id, matches(_canonical));
    expect(id[14], '7');
    expect('89ab', contains(id[19]));
    expect(newUuid(), isNot(id));
  });

  // Hard-coded from the server helper (`server/test/support/test-ids.ts`,
  // pinned in `server/src/common/ids.spec.ts`) — both sides must agree.
  test('testId matches the server helper', () {
    expect(testId('p1'), 'e7ce3922-6095-5e45-bfec-e66674fe7daf');
    expect(testId('ct-product-1'), 'a2bba7f5-f859-59f4-8ebd-92cee8c78f1c');
    expect(testId('สินค้า-1'), '4c2ffbc5-5468-5db1-ab4c-0c851829e5a3');
  });
}
