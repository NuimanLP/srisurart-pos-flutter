import { describe, expect, it } from 'vitest';
import { testId } from '../../test/support/test-ids.js';
import { assertOpIds, parseSyncDiscard, parseSyncPush, targetIdOf } from './sync.dto.js';

describe('parseSyncPush DTO validation', () => {
  const validOp = {
    opId: testId('op_1'),
    idempotencyKey: 'k_1',
    type: 'sale.create',
    payload: { id: testId('s1'), total: '100.00' },
  };

  it('accepts valid sync push payload', () => {
    const parsed = parseSyncPush({
      outboxRemaining: 5,
      ops: [validOp],
    });
    expect(parsed.outboxRemaining).toBe(5);
    expect(parsed.ops).toHaveLength(1);
    expect(parsed.ops[0].opId).toBe(testId('op_1'));
    expect(parsed.ops[0].type).toBe('sale.create');
  });

  it('rejects missing or non-array ops', () => {
    expect(() => parseSyncPush({ outboxRemaining: 0 })).toThrow(/ops must be an array/);
    expect(() => parseSyncPush({ outboxRemaining: 0, ops: 'not-an-array' })).toThrow(
      /ops must be an array/,
    );
  });

  it('rejects empty ops array', () => {
    expect(() => parseSyncPush({ outboxRemaining: 0, ops: [] })).toThrow(
      /ops array must not be empty/,
    );
  });

  it('rejects batch size exceeding 50 ops (08 §8.2 C11)', () => {
    const ops = Array.from({ length: 51 }, (_, i) => ({
      ...validOp,
      opId: testId(`op_${i}`),
    }));
    expect(() => parseSyncPush({ outboxRemaining: 0, ops })).toThrow(/OP_BATCH_TOO_LARGE/);
  });

  it('rejects negative outboxRemaining', () => {
    expect(() => parseSyncPush({ outboxRemaining: -1, ops: [validOp] })).toThrow(
      /outboxRemaining must be an integer >= 0/,
    );
  });

  it('rejects missing op required fields', () => {
    expect(() =>
      parseSyncPush({
        outboxRemaining: 0,
        ops: [{ ...validOp, opId: '' }],
      }),
    ).toThrow(/opId must be a lowercase UUID/);

    expect(() =>
      parseSyncPush({
        outboxRemaining: 0,
        ops: [{ ...validOp, idempotencyKey: ' ' }],
      }),
    ).toThrow(/idempotencyKey must be a non-empty string/);

    expect(() =>
      parseSyncPush({
        outboxRemaining: 0,
        ops: [{ ...validOp, payload: null }],
      }),
    ).toThrow(/payload must be an object/);
  });

  it('rejects unknown op types', () => {
    expect(() =>
      parseSyncPush({
        outboxRemaining: 0,
        ops: [{ ...validOp, type: 'unknown.action' }],
      }),
    ).toThrow(/Unknown operation type: unknown.action/);
  });

  it('refuses an uppercase opId rather than lower-casing it (#616)', () => {
    expect(() =>
      parseSyncPush({
        outboxRemaining: 0,
        ops: [{ ...validOp, opId: testId('op_1').toUpperCase() }],
      }),
    ).toThrow(/ops\[0\]\.opId must be a lowercase UUID/);
  });
});

describe('assertOpIds (#616)', () => {
  const op = (type: string, payload: Record<string, unknown>) => ({
    opId: testId('op'),
    idempotencyKey: 'k',
    type,
    payload,
  });
  const line = { productId: testId('p1') };

  it('passes every id of a well-formed op, and absent optional ids', () => {
    expect(() =>
      assertOpIds(op('sale.create', { id: testId('s1'), items: [line] })),
    ).not.toThrow();
    expect(() =>
      assertOpIds(op('return.create', { saleId: testId('s1'), items: [line] })),
    ).not.toThrow();
    expect(() => assertOpIds(op('shift.open', {}))).not.toThrow();
  });

  it.each([
    ['sale.create', { id: 's_off_001', items: [line] }, 'payload.id'],
    ['sale.create', { id: testId('s1'), customerId: 'c1', items: [line] }, 'payload.customerId'],
    ['sale.create', { id: testId('s1'), items: [line, { productId: 'p1' }] }, 'payload.items[1].productId'],
    ['return.create', { saleId: testId('s1').toUpperCase(), items: [line] }, 'payload.saleId'],
    ['credit_payment.create', { mechanicId: 'm1' }, 'payload.mechanicId'],
    ['customer.update', {}, 'payload.id'],
    ['sale.void_offline', { saleId: 's1' }, 'payload.saleId'],
    ['drawer.entry', { id: 'de_1' }, 'payload.id'],
  ])('%s: a bad id is a 400 INVALID_ID (case %#)', (type, payload, field) => {
    try {
      assertOpIds(op(type, payload));
      expect.unreachable();
    } catch (err) {
      expect((err as { getResponse(): unknown }).getResponse()).toMatchObject({
        code: 'INVALID_ID',
        details: { field },
      });
    }
  });
});

describe('discard target (#616)', () => {
  const discard = (extra: Record<string, unknown>) =>
    parseSyncDiscard({ opId: testId('op'), type: 'sale.create', note: 'n', ...extra });

  it('looks up a UUID target, and treats a malformed one as no row instead of refusing', () => {
    expect(targetIdOf(discard({ clientId: testId('s1') }))).toBe(testId('s1'));
    expect(targetIdOf(discard({ clientId: 's_off_001' }))).toBeUndefined();
    expect(
      targetIdOf(
        parseSyncDiscard({
          opId: testId('op'),
          type: 'sale.void_offline',
          note: 'n',
          payload: { saleId: testId('s1') },
        }),
      ),
    ).toBe(testId('s1'));
  });

  it('still refuses a malformed opId', () => {
    expect(() => discard({ opId: 'op_1' })).toThrow(/opId must be a lowercase UUID/);
  });
});
