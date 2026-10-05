import { createHash } from 'node:crypto';

/**
 * Fixed namespace for test ids (#616). `frontend/test/support/test_ids.dart` uses the same
 * one, so `testId(label)` is the same string on both sides — never change it.
 */
export const TEST_ID_NAMESPACE = '589fb3a8-4a69-45d2-9251-d3e9f1570292';

/** A stable lowercase UUIDv5 (RFC 9562 §5.5) for a readable test label: `testId('p1')`. */
export function testId(label: string): string {
  const ns = Buffer.from(TEST_ID_NAMESPACE.replaceAll('-', ''), 'hex');
  const b = createHash('sha1').update(ns).update(label, 'utf8').digest().subarray(0, 16);
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = b.toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

/**
 * The client-request contract ids (`client-request-fixtures.e2e-spec.ts`,
 * `client_requests_contract_test.dart`), for the slices that move those tests to UUIDs.
 * `ct-category` is a category *name* (a natural key), not an id, so it is not here.
 */
export const CONTRACT_IDS = {
  product: testId('ct-product-1'),
  customer: testId('ct-customer-1'),
  mechanic: testId('ct-mechanic-1'),
  sale: testId('ct-sale-1'),
  quote: testId('ct-quote-1'),
  po: testId('ct-po-1'),
  review: testId('ct-review-1'),
  device: testId('ct-device-1'),
} as const;
