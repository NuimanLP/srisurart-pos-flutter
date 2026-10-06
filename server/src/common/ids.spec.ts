import { BadRequestException } from '@nestjs/common';
import { describe, expect, it } from 'vitest';
import { testId } from '../../test/support/test-ids.js';
import { assertValidTenantId, invalidUuidInput, newUuid, optionalUuid, parseUuid, requiredUuid } from './ids.js';
import { ParseUuidPipe } from './parse-uuid.pipe.js';

const CANONICAL = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

describe('newUuid', () => {
  it('is a canonical lowercase UUIDv7 carrying the current ms', () => {
    const before = Date.now();
    const id = newUuid();
    const after = Date.now();
    expect(id).toMatch(CANONICAL);
    expect(id[14]).toBe('7'); // version
    expect('89ab').toContain(id[19]); // variant 10xx
    const ms = parseInt(id.replaceAll('-', '').slice(0, 12), 16);
    expect(ms).toBeGreaterThanOrEqual(before);
    expect(ms).toBeLessThanOrEqual(after + 1);
  });

  it('1000 calls are unique and strictly increasing, even inside one ms', () => {
    const ids = Array.from({ length: 1000 }, () => newUuid());
    expect(new Set(ids).size).toBe(1000);
    for (let i = 1; i < ids.length; i++) expect(ids[i] > ids[i - 1]).toBe(true);
  });
});

describe('parseUuid', () => {
  const ok = '0192f3a1-7b2c-7d4e-8f00-123456789abc';

  it('accepts the canonical lowercase form of any version', () => {
    expect(parseUuid(ok, 'id')).toBe(ok);
    expect(parseUuid('589fb3a8-4a69-45d2-9251-d3e9f1570292', 'id')).toBe(
      '589fb3a8-4a69-45d2-9251-d3e9f1570292',
    );
  });

  it.each([
    ['uppercase', ok.toUpperCase()],
    ['empty', ''],
    ['short legacy id', 'p1'],
    ['whitespace-padded', ` ${ok} `],
    ['braces', `{${ok}}`],
    ['no dashes', ok.replaceAll('-', '')],
    ['number', 42],
    ['undefined', undefined],
    ['null', null],
  ])('rejects %s with 400 INVALID_ID', (_, value) => {
    let err: unknown;
    try {
      parseUuid(value, 'productId');
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(BadRequestException);
    expect((err as BadRequestException).getResponse()).toEqual({
      code: 'INVALID_ID',
      message: 'productId must be a lowercase UUID',
      details: { field: 'productId' },
    });
  });

  it('optionalUuid maps absent to null and still validates a present value', () => {
    expect(optionalUuid(undefined, 'x')).toBeNull();
    expect(optionalUuid(null, 'x')).toBeNull();
    expect(optionalUuid('', 'x')).toBeNull();
    expect(optionalUuid(ok, 'x')).toBe(ok);
    expect(() => optionalUuid('p1', 'x')).toThrow(BadRequestException);
  });

  it('requiredUuid: missing is "is required", malformed is INVALID_ID', () => {
    expect(requiredUuid(ok, 'saleId')).toBe(ok);
    for (const missing of [undefined, null, '', '   ', 42]) {
      expect(() => requiredUuid(missing, 'saleId')).toThrow('saleId is required');
    }
    let err: unknown;
    try {
      requiredUuid('p1', 'saleId');
    } catch (e) {
      err = e;
    }
    expect((err as BadRequestException).getResponse()).toMatchObject({
      code: 'INVALID_ID',
    });
  });

  it('ParseUuidPipe names the route param in the error', () => {
    const pipe = new ParseUuidPipe();
    expect(pipe.transform(ok, { type: 'param', data: 'id' })).toBe(ok);
    expect(() => pipe.transform('P1', { type: 'param', data: 'saleId' })).toThrow(
      'saleId must be a lowercase UUID',
    );
  });
});

describe('testId', () => {
  // The same values are hard-coded in frontend/test/support/test_ids_test.dart.
  it('is a stable lowercase UUIDv5 per label', () => {
    expect(testId('p1')).toBe(testId('p1'));
    expect(testId('p1')).not.toBe(testId('p2'));
    expect(testId('p1')).toMatch(CANONICAL);
    expect(testId('p1')[14]).toBe('5');
    expect(testId('p1')).toBe('e7ce3922-6095-5e45-bfec-e66674fe7daf');
    expect(testId('ct-product-1')).toBe('a2bba7f5-f859-59f4-8ebd-92cee8c78f1c');
    expect(testId('สินค้า-1')).toBe('4c2ffbc5-5468-5db1-ab4c-0c851829e5a3');
  });
});

describe('invalidUuidInput', () => {
  const pgError = (message: string) => Object.assign(new Error(message), { code: '22P02' });

  it('maps only a uuid 22P02 to 400 INVALID_ID (#616); other 22P02s stay unmapped (500)', () => {
    const uuid = invalidUuidInput(pgError('invalid input syntax for type uuid: "p1"'));
    expect(uuid).toBeInstanceOf(BadRequestException);
    expect(uuid?.getResponse()).toEqual({ code: 'INVALID_ID', message: 'An id must be a lowercase UUID' });
    expect(invalidUuidInput(pgError('invalid input syntax for type integer: "x"'))).toBeNull();
    expect(invalidUuidInput(new Error('invalid input syntax for type uuid: "p1"'))).toBeNull();
    expect(invalidUuidInput(null)).toBeNull();
  });
});

describe('assertValidTenantId', () => {
  it('accepts a lowercase UUID', () => {
    expect(() => assertValidTenantId(newUuid())).not.toThrow();
  });

  it.each(['t1', '', newUuid().toUpperCase()])('refuses %j with 400 INVALID_TENANT_ID', (bad) => {
    try {
      assertValidTenantId(bad);
      expect.unreachable();
    } catch (e) {
      expect(e).toBeInstanceOf(BadRequestException);
      expect((e as BadRequestException).getResponse()).toEqual({
        code: 'INVALID_TENANT_ID',
        message: 'tenantId must be a lowercase UUID',
      });
    }
  });
});
