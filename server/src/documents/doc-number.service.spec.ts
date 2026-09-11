import { describe, expect, it } from 'vitest';
import { formatDocNumber, MAX_DOC_NO } from './doc-number.service.js';

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
