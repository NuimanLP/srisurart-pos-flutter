import { describe, expect, it } from 'vitest';
import { returning } from './sql.js';

describe('returning', () => {
  it('reads a SELECT / INSERT result', () => {
    expect(returning<{ n: number }>([{ n: 5 }])).toEqual([{ n: 5 }]);
  });

  it('reads an UPDATE / DELETE result, which arrives as [rows, affected]', () => {
    expect(returning<{ n: number }>([[{ n: 7 }], 1])).toEqual([{ n: 7 }]);
  });

  it('reports no rows when nothing matched', () => {
    expect(returning([])).toEqual([]);
    expect(returning([[], 0])).toEqual([]);
    expect(returning(undefined)).toEqual([]);
  });
});
