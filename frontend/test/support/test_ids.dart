// #616: stable lowercase UUIDs for readable test labels — `testId('p1')`.
// Must equal `testId` in `server/test/support/test-ids.ts` (same UUIDv5 namespace),
// so a fixture shared by both sides can name the same row.

import 'package:uuid/uuid.dart';

/// Never change: the server helper uses the same namespace.
const testIdNamespace = '589fb3a8-4a69-45d2-9251-d3e9f1570292';

String testId(String label) => const Uuid().v5(testIdNamespace, label);

/// The client-request contract ids (`client_requests_contract_test.dart`,
/// `client-request-fixtures.e2e-spec.ts`) — same keys as the server's
/// `CONTRACT_IDS`. `ct-category` is a category name, not an id, so it is absent.
final contractIds = {
  'product': testId('ct-product-1'),
  'customer': testId('ct-customer-1'),
  'mechanic': testId('ct-mechanic-1'),
  'sale': testId('ct-sale-1'),
  'quote': testId('ct-quote-1'),
  'po': testId('ct-po-1'),
  'review': testId('ct-review-1'),
  'device': testId('ct-device-1'),
};
