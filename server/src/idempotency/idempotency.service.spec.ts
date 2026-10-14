import { describe, expect, it } from 'vitest';
import { IdempotencyService } from './idempotency.service.js';

const hash = IdempotencyService.requestHash;

// The rest of the module is the primary key, RLS and a transaction — mocking those
// would test the mock. It is proved against the real database in
// test/idempotency.e2e-spec.ts; what is unit-testable here is the fingerprint.
describe('IdempotencyService.requestHash', () => {
  it('is stable across calls, so a retry of the same body replays', () => {
    const body = { total: 1250, items: [{ id: 'p1', qty: 2 }] };
    expect(hash(body)).toBe(hash({ total: 1250, items: [{ id: 'p1', qty: 2 }] }));
  });

  it('changes when any value changes — this is what turns a reused key into a 409', () => {
    expect(hash({ total: 1250 })).not.toBe(hash({ total: 1251 }));
    expect(hash({ qty: 1 })).not.toBe(hash({ qty: '1' }));
  });

  it('treats an absent body and an explicit null alike', () => {
    expect(hash(undefined)).toBe(hash(null));
  });

  it('distinguishes an empty body from an empty object', () => {
    expect(hash(null)).not.toBe(hash({}));
  });

  it('is a sha256 hex digest', () => {
    expect(hash({ a: 1 })).toMatch(/^[0-9a-f]{64}$/);
  });

  // `PUT /products/:id/image` sends raw bytes: the fingerprint must cover every one of them.
  it('fingerprints a raw body by its bytes', () => {
    const a = Buffer.from([1, 2, 3, 4]);
    expect(hash(a)).toBe(hash(Buffer.from([1, 2, 3, 4])));
    expect(hash(a)).not.toBe(hash(Buffer.from([1, 2, 3, 5])));
    expect(hash(a)).toMatch(/^[0-9a-f]{64}$/);
    // Never the JSON digest of the same Buffer.
    expect(hash(a)).not.toBe(hash(a.toJSON()));
  });
});
