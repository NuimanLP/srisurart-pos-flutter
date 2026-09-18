import { describe, expect, it } from 'vitest';
import { DocNumberService, formatDocNumber, MAX_DOC_NO } from './doc-number.service.js';

describe('formatDocNumber', () => {
  it('renders the ADR-0007 example exactly', () => {
    expect(formatDocNumber('receipt', 1, '2569-08', 42)).toBe('RC01-2569-08-0042');
  });

  it('pads device_no to two digits so machine 1 and machine 12 cannot be confused', () => {
    expect(formatDocNumber('receipt', 1, '2569-08', 1)).toBe('RC01-2569-08-0001');
    expect(formatDocNumber('receipt', 12, '2569-08', 1)).toBe('RC12-2569-08-0001');
  });

  it('uses the prefix of each series', () => {
    expect(formatDocNumber('cn', 3, '2569-09', 7)).toBe('CN03-2569-09-0007');
    expect(formatDocNumber('po', 3, '2569-09', 7)).toBe('PO03-2569-09-0007');
    expect(formatDocNumber('quote', 3, '2569-09', 7)).toBe('QT03-2569-09-0007');
    expect(formatDocNumber('cp', 3, '2569-09', 7)).toBe('CP03-2569-09-0007');
  });

  it('keeps four digits at the top of the range', () => {
    expect(formatDocNumber('receipt', 99, '2569-12', MAX_DOC_NO)).toBe(
      'RC99-2569-12-9999',
    );
  });

  it('does not match the legacy random format, so imported numbers cannot collide', () => {
    expect(formatDocNumber('receipt', 1, '2569-08', 42)).not.toBe('RC12345678ABCD');
    expect(/^RC\d{2}-\d{4}-\d{2}-\d{4}$/.test(formatDocNumber('receipt', 1, '2569-08', 42))).toBe(true);
    expect(/^RC\d{2}-\d{4}-\d{2}-\d{4}$/.test('RC12345678ABCD')).toBe(false);
  });
});

describe('DocNumberService.validateDocNumber', () => {
  const service = new DocNumberService();

  it('validates a correct receipt number and extracts period and seq', () => {
    expect(service.validateDocNumber('receipt', 1, 'RC01-2569-08-0042')).toEqual({
      period: '2569-08',
      seq: 42,
    });
  });

  it('validates a correct CN number', () => {
    expect(service.validateDocNumber('cn', 3, 'CN03-2569-09-0007')).toEqual({
      period: '2569-09',
      seq: 7,
    });
  });

  it('does NOT validate period against clock (clock is client authority per C2)', () => {
    expect(service.validateDocNumber('receipt', 1, 'RC01-2575-12-0001')).toEqual({
      period: '2575-12',
      seq: 1,
    });
    expect(service.validateDocNumber('receipt', 1, 'RC01-2560-01-9999')).toEqual({
      period: '2560-01',
      seq: 9999,
    });
  });

  it('rejects prefix mismatch with 400 DOC_NUMBER_INVALID', () => {
    expect(() => service.validateDocNumber('receipt', 1, 'CN01-2569-08-0042')).toThrowError(
      expect.objectContaining({
        response: expect.objectContaining({ code: 'DOC_NUMBER_INVALID' }),
      }),
    );
    expect(() => service.validateDocNumber('cn', 1, 'RC01-2569-08-0042')).toThrowError(
      expect.objectContaining({
        response: expect.objectContaining({ code: 'DOC_NUMBER_INVALID' }),
      }),
    );
  });

  it('rejects device mismatch with 400 DOC_NUMBER_INVALID', () => {
    expect(() => service.validateDocNumber('receipt', 1, 'RC02-2569-08-0042')).toThrowError(
      expect.objectContaining({
        response: expect.objectContaining({ code: 'DOC_NUMBER_INVALID' }),
      }),
    );
  });

  it('rejects seq 0000 with 400 DOC_NUMBER_INVALID', () => {
    expect(() => service.validateDocNumber('receipt', 1, 'RC01-2569-08-0000')).toThrowError(
      expect.objectContaining({
        response: expect.objectContaining({ code: 'DOC_NUMBER_INVALID' }),
      }),
    );
  });

  it('rejects malformed numbers with 400 DOC_NUMBER_INVALID', () => {
    const invalid = [
      'RC12345678ABCD',
      'RC1-2569-08-0001',
      'RC01-2569-8-0001',
      'RC01-2569-08-01',
      'RC01-2569-08-10000',
      'random-string',
      '',
    ];
    for (const no of invalid) {
      expect(() => service.validateDocNumber('receipt', 1, no)).toThrowError(
        expect.objectContaining({
          response: expect.objectContaining({ code: 'DOC_NUMBER_INVALID' }),
        }),
      );
    }
  });
});

