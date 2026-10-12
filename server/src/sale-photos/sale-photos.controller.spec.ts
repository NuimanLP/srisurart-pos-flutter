import { describe, expect, it } from 'vitest';
import { parseSortOrder, parseTakenAt } from './sale-photos.controller.js';

const codeOf = (fn: () => unknown): string => {
  try {
    fn();
    return 'no error';
  } catch (e) {
    return (e as { getResponse: () => { code: string } }).getResponse().code;
  }
};

describe('PUT /sales/:saleId/photos/:photoId query (10_SALE_PHOTO_EVIDENCE.md §4.3 row 5)', () => {
  const NOW = Date.parse('2026-10-12T07:00:00.000Z');

  it('takenAt: an ISO-8601 timestamp with a zone, normalised to UTC', () => {
    expect(parseTakenAt('2026-10-12T07:05:11.000Z', NOW)).toBe('2026-10-12T07:05:11.000Z');
    expect(parseTakenAt('2026-10-12T14:05:11+07:00', NOW)).toBe('2026-10-12T07:05:11.000Z');
  });

  it('takenAt: up to 10 minutes ahead of the server is accepted, later is 400 — never clamped', () => {
    expect(parseTakenAt('2026-10-12T07:10:00.000Z', NOW)).toBe('2026-10-12T07:10:00.000Z');
    expect(codeOf(() => parseTakenAt('2026-10-12T07:10:00.001Z', NOW))).toBe('BAD_REQUEST');
  });

  it('takenAt: missing, zone-less, date-only, garbage or repeated is 400 BAD_REQUEST', () => {
    for (const v of [undefined, '', '2026-10-12T07:05:11', '2026-10-12', 'yesterday', '2026-13-45T00:00:00Z', [
      '2026-10-12T07:05:11Z',
    ]]) {
      expect(codeOf(() => parseTakenAt(v, NOW)), String(v)).toBe('BAD_REQUEST');
    }
  });

  it('sortOrder: an integer 0–4, anything else is 400 BAD_REQUEST', () => {
    expect([0, 1, 2, 3, 4].map((n) => parseSortOrder(String(n)))).toEqual([0, 1, 2, 3, 4]);
    for (const v of [undefined, '', '5', '-1', '1.0', '1e0', ' 1', 'x', ['1']]) {
      expect(codeOf(() => parseSortOrder(v)), String(v)).toBe('BAD_REQUEST');
    }
  });
});
