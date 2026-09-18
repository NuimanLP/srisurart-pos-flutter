import { describe, expect, it } from 'vitest';
import { parseSyncPush } from './sync.dto.js';

describe('parseSyncPush DTO validation', () => {
  const validOp = {
    opId: 'op_1',
    idempotencyKey: 'k_1',
    type: 'sale.create',
    payload: { id: 's1', total: '100.00' },
  };

  it('accepts valid sync push payload', () => {
    const parsed = parseSyncPush({
      outboxRemaining: 5,
      ops: [validOp],
    });
    expect(parsed.outboxRemaining).toBe(5);
    expect(parsed.ops).toHaveLength(1);
    expect(parsed.ops[0].opId).toBe('op_1');
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
      opId: `op_${i}`,
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
    ).toThrow(/opId must be a non-empty string/);

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
});
