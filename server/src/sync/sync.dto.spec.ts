import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { testId } from '../../test/support/test-ids.js';
import {
  parseOpPayload,
  parseSyncDiscard,
  parseSyncPush,
  replayProbeOf,
  SYNC_OP_TYPES,
  targetIdOf,
  type ParsedSyncOp,
  type ReplayProbe,
  type SyncOpType,
} from './sync.dto.js';

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

describe('parseOpPayload (#619)', () => {
  const op = (type: string, payload: Record<string, unknown>) => ({
    opId: testId('op'),
    idempotencyKey: 'k',
    type,
    payload,
  });
  const line = { lineNo: 1, productId: testId('p1'), name: 'Filter', qty: 1, price: '85.00' };
  const valid: Record<SyncOpType, Record<string, unknown>> = {
    'sale.create': {
      id: testId('s1'),
      subtotal: '85.00',
      total: '85.00',
      paymentMethod: 'เงินสด',
      items: [line],
    },
    'return.create': { saleId: testId('s1'), refundMethod: 'เงินสด', items: [line] },
    'shift.open': { id: testId('sh1'), startingCash: '100.00' },
    'drawer.entry': { id: testId('de1'), type: 'in', amount: '5.00' },
    'credit_payment.create': {
      id: testId('cp1'),
      mechanicId: testId('m1'),
      amount: '10.00',
      paymentMethod: 'เงินสด',
    },
    'customer.create': { id: testId('c1'), name: 'ลูกค้า' },
    'customer.update': { id: testId('c1'), phone: '0800000000' },
    'sale.void_offline': { saleId: testId('s1'), reason: ' ขอยกเลิก ' },
  };
  const parse = (type: SyncOpType, extra: Record<string, unknown> = {}) =>
    parseOpPayload(op(type, { ...valid[type], ...extra }));
  const errorOf = (fn: () => unknown) => {
    try {
      fn();
    } catch (err) {
      return (err as { getResponse(): unknown }).getResponse();
    }
    throw new Error('expected a throw');
  };

  it('parses every op of every docs/Backend_design/fixtures/sync-push file', () => {
    const dir = join(
      fileURLToPath(new URL('.', import.meta.url)),
      '../../../docs/Backend_design/fixtures/sync-push',
    );
    const ops = readdirSync(dir)
      // Refused whole (403) before any op is read — its sale has no lines on purpose.
      .filter((f) => f.endsWith('.json') && f !== 'batch.no-active-user-403.json')
      .flatMap((f) => JSON.parse(readFileSync(join(dir, f), 'utf8')).request.body.ops);
    expect(new Set(ops.map((o: { type: string }) => o.type))).toEqual(new Set(SYNC_OP_TYPES));
    for (const o of ops) expect(() => parseOpPayload(o), o.opId).not.toThrow();
  });

  it('returns the typed payload', () => {
    const sale = parse('sale.create');
    expect(sale).toMatchObject({ type: 'sale.create', sale: { id: testId('s1'), totalSatang: 8500 } });
    expect(parse('credit_payment.create', { allowOverpayment: true })).toMatchObject({
      mechanicId: testId('m1'),
      payment: { id: testId('cp1'), amountSatang: 1000, allowOverpayment: false },
    });
    expect(parse('customer.create')).toMatchObject({ customer: { id: testId('c1'), nameTH: 'ลูกค้า' } });
    expect(parse('sale.void_offline')).toMatchObject({ saleId: testId('s1'), reason: 'ขอยกเลิก' });
    expect(parse('drawer.entry', { createdAt: '2026-09-15T01:30:00.000Z' })).toMatchObject({
      deviceDate: new Date('2026-09-15T01:30:00.000Z'),
    });
  });

  it.each([
    ['sale.create', { id: 's_off_001' }, 'payload.id'],
    ['sale.create', { customerId: 'c1' }, 'payload.customerId'],
    ['sale.create', { quoteId: 'q1' }, 'payload.quoteId'],
    ['sale.create', { items: [line, { ...line, lineNo: 2, productId: 'p1' }] }, 'payload.items[1].productId'],
    ['return.create', { saleId: testId('s1').toUpperCase() }, 'payload.saleId'],
    ['return.create', { id: 'r1' }, 'payload.id'],
    ['shift.open', { id: 'sh1' }, 'payload.id'],
    ['drawer.entry', { id: 'de_1' }, 'payload.id'],
    ['credit_payment.create', { mechanicId: 'm1' }, 'payload.mechanicId'],
    ['credit_payment.create', { id: 'cp1' }, 'payload.id'],
    ['customer.create', { id: 'c1' }, 'payload.id'],
    ['customer.update', { id: undefined }, 'payload.id'],
    ['sale.void_offline', { saleId: 's1' }, 'payload.saleId'],
  ] as const)('%s: a bad id is a 400 INVALID_ID (case %#)', (type, extra, field) => {
    expect(errorOf(() => parse(type, extra))).toMatchObject({
      code: 'INVALID_ID',
      message: `${field} must be a lowercase UUID`,
      details: { field },
    });
  });

  it("answers an empty id as the online route does", () => {
    // `parseSaleParty`'s `requiredUuid`.
    expect(errorOf(() => parse('sale.create', { id: '' }))).toMatchObject({ message: 'id is required' });
    // `parseUuid` on the body (shift open, credit payment) or on the URL (`ParseUuidPipe`).
    for (const [type, field] of [
      ['shift.open', 'id'],
      ['credit_payment.create', 'id'],
      ['credit_payment.create', 'mechanicId'],
      ['customer.update', 'id'],
      ['sale.void_offline', 'saleId'],
    ] as const) {
      expect(errorOf(() => parse(type, { [field]: '' })), `${type} ${field}`).toMatchObject({
        code: 'INVALID_ID',
      });
    }
    // `optionalUuid`: no id, the server mints one.
    expect(parse('drawer.entry', { id: '' })).toMatchObject({ entry: { id: null } });
    expect(parse('return.create', { id: '' })).toMatchObject({ ret: { id: null } });
    expect(parse('customer.create', { id: '' })).toMatchObject({ customer: { id: null } });
  });

  it('refuses a void without a reason and an unparseable device date', () => {
    expect(errorOf(() => parse('sale.void_offline', { reason: '  ' }))).toMatchObject({
      message: 'Void reason is required',
    });
    expect(errorOf(() => parse('sale.create', { date: '' }))).toMatchObject({
      message: 'date must be a valid ISO date string',
    });
    expect(errorOf(() => parse('shift.open', { openedAt: 'not-a-date' }))).toMatchObject({
      message: 'openedAt must be a valid ISO date string',
    });
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

describe('replayProbeOf (08 §8.3 step 2, before the parser)', () => {
  const op = (type: string, payload: Record<string, unknown>) => ({
    opId: testId('op'),
    idempotencyKey: 'k',
    type,
    payload,
  });

  it('reads the id and the compared fields of a body the parser refuses, without throwing', () => {
    const raw = op('sale.create', { id: testId('s1'), total: '100.00', customerId: 'C-legacy', receiptNo: 'RC01-2569-09-0001' });
    expect(() => parseOpPayload(raw)).toThrow();
    expect(replayProbeOf(raw)).toEqual({
      type: 'sale.create',
      id: testId('s1'),
      totalSatang: 10000,
      receiptNo: 'RC01-2569-09-0001',
    });
  });

  it('an amount that does not read is null (never equal to a stored amount)', () => {
    expect(replayProbeOf(op('drawer.entry', { id: testId('d1'), type: 'x', amount: 'abc' }))).toEqual({
      type: 'drawer.entry',
      id: testId('d1'),
      entryType: 'x',
      amountSatang: null,
    });
  });

  it('no probe for a non-UUID id, a missing id, or customer.update', () => {
    expect(replayProbeOf(op('sale.create', { id: 'S-legacy', total: '1.00' }))).toBeNull();
    expect(replayProbeOf(op('shift.open', { startingCash: '1.00' }))).toBeNull();
    expect(replayProbeOf(op('customer.update', { id: testId('c1') }))).toBeNull();
  });

  it('agrees with parseOpPayload on the id and every compared field, for every fixture op step 2 replays', () => {
    // Guards a future parser that normalises a field the probe compares raw.
    const dir = join(
      fileURLToPath(new URL('.', import.meta.url)),
      '../../../docs/Backend_design/fixtures/sync-push',
    );
    const ops = readdirSync(dir)
      .filter((f) => f.endsWith('.json') && f !== 'batch.no-active-user-403.json')
      .flatMap((f) => JSON.parse(readFileSync(join(dir, f), 'utf8')).request.body.ops)
      .filter((o: { type: string }) => o.type !== 'customer.update');
    const compared = (p: ReplayProbe) => {
      switch (p.type) {
        case 'sale.create': return { id: p.id, totalSatang: p.totalSatang };
        case 'return.create': return { id: p.id, saleId: p.saleId, items: p.items };
        case 'shift.open': return { id: p.id, startingCashSatang: p.startingCashSatang };
        case 'drawer.entry': return { id: p.id, type: p.entryType, amountSatang: p.amountSatang };
        case 'credit_payment.create':
          return { id: p.id, mechanicId: p.mechanicId, amountSatang: p.amountSatang, paymentMethod: p.paymentMethod };
        case 'customer.create': return { id: p.id };
        case 'sale.void_offline': return { id: p.id, reason: p.reason };
      }
    };
    const fromParsed = (o: ParsedSyncOp) => {
      switch (o.type) {
        case 'sale.create': return { id: o.sale.id, totalSatang: o.sale.totalSatang };
        case 'return.create':
          return {
            id: o.ret.id,
            saleId: o.ret.saleId,
            items: o.ret.items.map((l) => ({ productId: l.productId, qty: l.qty, priceSatang: l.priceSatang })),
          };
        case 'shift.open': return { id: o.shift.id, startingCashSatang: o.shift.startingCashSatang };
        case 'drawer.entry': return { id: o.entry.id, type: o.entry.type, amountSatang: o.entry.amountSatang };
        case 'credit_payment.create':
          return {
            id: o.payment.id,
            mechanicId: o.mechanicId,
            amountSatang: o.payment.amountSatang,
            paymentMethod: o.payment.paymentMethod,
          };
        case 'customer.create': return { id: o.customer.id };
        case 'sale.void_offline': return { id: o.saleId, reason: o.reason };
        case 'customer.update': throw new Error('not replayed by id');
      }
    };
    const types = new Set<string>();
    for (const o of ops) {
      const probe = replayProbeOf(o);
      expect(probe, o.opId).not.toBeNull();
      expect(compared(probe!), o.opId).toEqual(fromParsed(parseOpPayload(o)));
      types.add(o.type);
    }
    expect(types).toEqual(new Set(SYNC_OP_TYPES.filter((t) => t !== 'customer.update')));
  });

  it('a void is found by the bill it names', () => {
    expect(replayProbeOf(op('sale.void_offline', { saleId: testId('s1'), reason: '  x ' }))).toEqual({
      type: 'sale.void_offline',
      id: testId('s1'),
      reason: 'x',
    });
  });
});
