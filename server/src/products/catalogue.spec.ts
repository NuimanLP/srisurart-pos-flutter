import { BadRequestException } from '@nestjs/common';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import * as requestContext from '../common/request-context.js';
import {
  parseProductCreate,
  parseProductPatch,
  parseStockAdjustment,
} from './catalogue.dto.js';
import {
  CAT_PALETTE,
  CategoriesService,
  catColor,
} from './categories.service.js';
import { SuppliersService } from './suppliers.service.js';

describe('catColor (db.js getCatColor)', () => {
  const seed = ['เครื่องยนต์', 'ไฟฟ้า', 'น้ำมัน', 'เบรก', 'ตัวถัง'];

  it('is the palette entry at the category index', () => {
    expect(catColor('เครื่องยนต์', seed)).toBe('#1E4A80');
    expect(catColor('ไฟฟ้า', seed)).toBe('#C04E10');
    const eleven = Array.from({ length: 11 }, (_, i) => `c${i}`);
    expect(catColor('c10', eleven)).toBe(CAT_PALETTE[0]);
  });

  it('falls back to the signed 32-bit hash for a name not in the list', () => {
    // Reference: the db.js loop, `h = (h * 31 + c) & 0xffffffff`, run in plain JS
    // numbers — `& 0xffffffff` is ToInt32, which is what `| 0` and Dart's
    // `toSigned(32)` both produce.
    const reference = (name: string) => {
      let h = 0;
      for (let i = 0; i < name.length; i++) {
        h = (h * 31 + name.charCodeAt(i)) & 0xffffffff;
      }
      return CAT_PALETTE[Math.abs(h) % CAT_PALETTE.length];
    };
    for (const name of [
      'ไม่รู้จัก',
      'ช่วงล่าง',
      'x',
      'a much longer category name',
    ]) {
      expect(catColor(name, seed)).toBe(reference(name));
      expect(catColor(name, seed)).toBe(catColor(name, seed));
    }
  });
});

// runTx itself is covered by tenant.service.spec.ts; here the context is mocked, so the
// door just runs the work (tx.2, #151).
const joinedTenants = { runTx: (fn: () => Promise<unknown>) => fn() } as never;

describe('CategoriesService.list', () => {
  let query: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    query = vi.fn();
    vi.spyOn(requestContext, 'currentRequestContext').mockReturnValue({
      tenantId: '00000000-0000-4000-8000-000000000001',
      manager: { query },
    } as never);
  });

  it('answers every colour from ONE query, not one per category', async () => {
    query.mockResolvedValueOnce(
      Array.from({ length: 12 }, (_, i) => ({ name: `c${i}` })),
    );
    const out = await new CategoriesService({} as never, joinedTenants).list();
    expect(query).toHaveBeenCalledTimes(1);
    expect(out).toHaveLength(12);
    expect(out[11]).toEqual({ name: 'c11', color: CAT_PALETTE[1] });
  });

  it('stands the five seed categories in when the table is empty', async () => {
    query.mockResolvedValueOnce([]);
    const out = await new CategoriesService({} as never, joinedTenants).list();
    expect(out.map((c) => c.name)).toEqual([
      'เครื่องยนต์',
      'ไฟฟ้า',
      'น้ำมัน',
      'เบรก',
      'ตัวถัง',
    ]);
  });
});

describe('SuppliersService.list (GET /suppliers)', () => {
  let query: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    query = vi.fn();
    vi.spyOn(requestContext, 'currentRequestContext').mockReturnValue({
      tenantId: '00000000-0000-4000-8000-000000000001',
      manager: { query },
    } as never);
  });

  it("answers every live product's suppliers from ONE query, money as 2-dp strings", async () => {
    query.mockResolvedValueOnce([
      {
        id: 's1',
        product_id: 'p1',
        name: 'A',
        unit_cost: '100',
        freight: '0.5',
      },
      {
        id: 's2',
        product_id: 'p2',
        name: 'B',
        unit_cost: '85.25',
        freight: '0',
      },
    ]);
    const out = await new SuppliersService(joinedTenants).list();
    expect(query).toHaveBeenCalledTimes(1);
    const [sql, params] = query.mock.calls[0] as [string, unknown[]];
    expect(sql).toMatch(/p\.deleted_at IS NULL/);
    expect(params).toEqual(['00000000-0000-4000-8000-000000000001']);
    expect(out).toEqual([
      {
        id: 's1',
        productId: 'p1',
        name: 'A',
        unitCost: '100.00',
        freight: '0.50',
      },
      {
        id: 's2',
        productId: 'p2',
        name: 'B',
        unitCost: '85.25',
        freight: '0.00',
      },
    ]);
  });
});

describe('catalogue DTOs', () => {
  it('trims partNo and refuses a blank one', () => {
    expect(
      parseProductCreate({ partNo: '  PAD-001  ', name: 'Pad' }).partNo,
    ).toBe('PAD-001');
    expect(() => parseProductCreate({ partNo: '   ', name: 'Blank' })).toThrow(
      BadRequestException,
    );
  });

  it('never reads stock from a product patch', () => {
    expect(parseProductPatch({ name: 'x', stock: 999 })).toEqual({ name: 'x' });
  });

  it('refuses a negative opening stock and a non-integer', () => {
    expect(() =>
      parseProductCreate({ partNo: 'A', name: 'A', stock: -1 }),
    ).toThrow(BadRequestException);
    expect(() =>
      parseProductCreate({ partNo: 'A', name: 'A', stock: 1.5 }),
    ).toThrow(BadRequestException);
  });

  it('validates an adjustment before anything is clamped', () => {
    expect(
      parseStockAdjustment({ delta: -10, type: 'adjustment-out' }),
    ).toEqual({ delta: -10, type: 'adjustment-out', note: null });
    expect(
      parseStockAdjustment({ delta: 0, type: 'adjustment-out' }).delta,
    ).toBe(0);
    for (const bad of [
      {},
      { delta: '5', type: 'adjustment-in' },
      { delta: 1.5, type: 'adjustment-in' },
      { delta: 5, type: 'adjust' },
      { delta: 5, type: 'receive' },
      { delta: 5, type: 'adjustment-out' },
      { delta: -5, type: 'adjustment-in' },
      { delta: 3_000_000_000, type: 'adjustment-in' },
      { delta: 5, type: 'adjustment-in', note: 7 },
    ]) {
      expect(() => parseStockAdjustment(bad)).toThrow(BadRequestException);
    }
  });
});
