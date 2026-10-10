import { existsSync } from 'node:fs';
import { mkdtemp, rm, utimes } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { imageFilePath, writeImageFiles } from '../product-images/image-store.js';
import { ProductsService } from './products.service.js';
import { TenantCache } from '../infra/tenant-cache.service.js';
import * as requestContext from '../common/request-context.js';

describe('ProductsService Caching & Reads', () => {
  let service: ProductsService;
  let redisMock: any;
  let managerMock: any;

  beforeEach(() => {
    // A tiny in-memory Redis: enough for `TenantCache`'s GET / SET [EX] [NX].
    const store = new Map<string, string>();
    redisMock = {
      store,
      get: vi.fn(async (k: string) => store.get(k) ?? null),
      set: vi.fn(async (k: string, v: string, ...args: unknown[]) => {
        if (args.includes('NX') && store.has(k)) return null;
        store.set(k, v);
        return 'OK';
      }),
      keys: vi.fn(),
      eval: vi.fn(async (_script: string, _n: number, k: string, token: string) => {
        if (store.get(k) !== token) return 0;
        store.delete(k);
        return 1;
      }),
    };
    managerMock = {
      query: vi.fn(),
    };

    vi.spyOn(requestContext, 'currentRequestContext').mockReturnValue({
      tenantId: '00000000-0000-4000-8000-000000000001',
      manager: managerMock,
    } as any);
    // `list` / `byId` read the tenant before any transaction since #173.
    vi.spyOn(requestContext, 'authorisedTenantId').mockReturnValue(
      '00000000-0000-4000-8000-000000000001',
    );

    service = new ProductsService(new TenantCache(redisMock, { warn: vi.fn() } as any), { log: vi.fn() } as any, { runTx: (fn: () => Promise<unknown>) => fn() } as any);
  });

  it('returns cached products when cache hits (fromCache: true)', async () => {
    const cachedData = {
      items: [
        {
          id: 'p1',
          partNo: 'BP-1',
          name: 'Brake Pad',
          nameTH: 'ผ้าเบรก',
          category: 'เบรก',
          brand: 'TEST',
          price: '500.00',
          cost: '300.00',
          stock: 10,
          minStock: 2,
          compat: null,
          updatedAt: '2026-09-13T00:00:00.000Z',
          deletedAt: null,
        },
      ],
      total: 1,
    };
    // Populate through a miss first, then prove the second read never queries.
    managerMock.query.mockResolvedValueOnce([{ n: 0 }]).mockResolvedValueOnce([]);
    await service.list({ page: 1, limit: 10 });
    const listKey = [...redisMock.store.keys()].find(
      (k: string) => k.includes(':list:') && !k.endsWith(':lock'),
    )!;
    redisMock.store.set(listKey, JSON.stringify(cachedData));
    managerMock.query.mockClear();

    const result = await service.list({ page: 1, limit: 10 });

    expect(result.fromCache).toBe(true);
    expect(result.items).toHaveLength(1);
    expect(result.items[0].id).toBe('p1');
    expect(managerMock.query).not.toHaveBeenCalled();
  });

  it('queries database and populates Redis cache on cache miss (fromCache: false)', async () => {
    managerMock.query
      .mockResolvedValueOnce([{ n: 1 }]) // totals
      .mockResolvedValueOnce([
        {
          id: 'p12',
          part_no: 'OIL-1',
          name: 'Engine Oil',
          name_th: 'น้ำมันเครื่อง',
          category: 'น้ำมัน',
          brand: 'TEST',
          price: '800.00',
          cost: '500.00',
          stock: 50,
          min_stock: 5,
          compat: null,
          updated_at: new Date('2026-09-13T00:00:00.000Z'),
          deleted_at: null,
        },
      ]); // rows

    const result = await service.list({ page: 1, limit: 10 });

    expect(result.fromCache).toBe(false);
    expect(result.items).toHaveLength(1);
    expect(result.items[0].id).toBe('p12');
    expect(result.items[0].price).toBe('800.00');
    expect(result.items[0].cost).toBe('500.00');
    const call = redisMock.set.mock.calls.find((c: unknown[]) =>
      String(c[0]).includes(':list:') && !String(c[0]).endsWith(':lock'),
    );
    expect(call[0]).toMatch(
      /^t:00000000-0000-4000-8000-000000000001:products:g:[0-9a-f]{16}:list:/,
    );
    expect(call[2]).toBe('EX');
    // 02_API_SCREENS.md §5: 300s ± 60s.
    expect(call[3]).toBeGreaterThanOrEqual(240);
    expect(call[3]).toBeLessThanOrEqual(360);
  });

  it('invalidates by replacing the generation, never with KEYS (#32)', async () => {
    managerMock.query.mockResolvedValueOnce([{ n: 0 }]).mockResolvedValueOnce([]);
    await service.list({ page: 1, limit: 10 });
    expect((await service.list({ page: 1, limit: 10 })).fromCache).toBe(true);

    await new TenantCache(redisMock, { warn: vi.fn() } as any).invalidate(
      '00000000-0000-4000-8000-000000000001',
      'products',
    );

    managerMock.query.mockResolvedValueOnce([{ n: 0 }]).mockResolvedValueOnce([]);
    expect((await service.list({ page: 1, limit: 10 })).fromCache).toBe(false);
    expect(redisMock.keys).not.toHaveBeenCalled();
  });

  it('a reader that read before a commit cannot cache over the invalidation (read-populate race)', async () => {
    const cache = new TenantCache(redisMock, { warn: vi.fn() } as any);
    const tid = '00000000-0000-4000-8000-000000000001';
    const row = (stock: number) => ({
      id: 'p1', part_no: 'BP-1', name: 'n', name_th: 'n', category: 'c', brand: 'b',
      price: '1.00', cost: '1.00', stock, min_stock: 0, compat: null,
      updated_at: new Date('2026-09-13T00:00:00.000Z'), deleted_at: null,
    });
    // The slow reader: it misses, reads stock 10, and while its query is "running" a
    // writer commits stock 9 and invalidates.
    managerMock.query
      .mockImplementationOnce(async () => {
        await cache.invalidate(tid, 'products');
        return [{ n: 1 }];
      })
      .mockResolvedValueOnce([row(10)]);
    expect((await service.list({ page: 1, limit: 10 })).items[0].stock).toBe(10);

    // The next reader must not be handed the slow reader's stale page.
    managerMock.query.mockResolvedValueOnce([{ n: 1 }]).mockResolvedValueOnce([row(9)]);
    const next = await service.list({ page: 1, limit: 10 });
    expect(next.fromCache).toBe(false);
    expect(next.items[0].stock).toBe(9);
  });

  it('a loader whose query throws frees its stampede lock at once (#124)', async () => {
    managerMock.query.mockRejectedValueOnce(new Error('connection reset'));
    await expect(service.list({ page: 1, limit: 10 })).rejects.toThrow('connection reset');
    const locks = [...redisMock.store.keys()].filter((k: string) => k.endsWith(':lock'));
    expect(locks).toEqual([]);

    // The next miss becomes the loader straight away instead of waiting on a dead lock.
    managerMock.query.mockResolvedValueOnce([{ n: 0 }]).mockResolvedValueOnce([]);
    expect((await service.list({ page: 1, limit: 10 })).fromCache).toBe(false);
  });
});

describe('ProductsService.removeImageIfUnreferenced (orphan grace period)', () => {
  const TENANT = '00000000-0000-4000-8000-000000000001';
  const KEY = 'aaaaaaaabbbbbbbbccccccccdddddddd';
  const prev = process.env.PRODUCT_IMAGES_DIR;
  let root: string;
  let referenced: boolean;
  let service: ProductsService;
  const present = () => [imageFilePath(TENANT, KEY, 't'), imageFilePath(TENANT, KEY, 'p')].map((f) => existsSync(f));
  const write = () => writeImageFiles(TENANT, KEY, { thumb: Buffer.from('t'), preview: Buffer.from('p') });
  const backdate = async () => {
    const old = new Date('2020-01-01T00:00:00Z');
    for (const v of ['t', 'p'] as const) await utimes(imageFilePath(TENANT, KEY, v), old, old);
  };

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), 'products-img-'));
    process.env.PRODUCT_IMAGES_DIR = root;
    referenced = false;
    const manager = { query: vi.fn(async () => (referenced ? [{ '?column?': 1 }] : [])) };
    vi.spyOn(requestContext, 'currentRequestContext').mockReturnValue({ tenantId: TENANT, manager } as any);
    vi.spyOn(requestContext, 'authorisedTenantId').mockReturnValue(TENANT);
    service = new ProductsService({} as any, { log: vi.fn() } as any, { runTx: (fn: () => Promise<unknown>) => fn() } as any);
  });
  afterEach(async () => {
    vi.restoreAllMocks();
    await rm(root, { recursive: true, force: true });
    if (prev === undefined) delete process.env.PRODUCT_IMAGES_DIR;
    else process.env.PRODUCT_IMAGES_DIR = prev;
  });

  it('keeps a referenced file, however old', async () => {
    await write();
    await backdate();
    referenced = true;
    await service.removeImageIfUnreferenced(KEY);
    expect(present()).toEqual([true, true]);
  });

  it('keeps an unreferenced file written within the grace period (an upload may not have committed)', async () => {
    await write();
    await service.removeImageIfUnreferenced(KEY);
    expect(present()).toEqual([true, true]);
  });

  it('deletes an unreferenced file older than the grace period', async () => {
    await write();
    await backdate();
    await service.removeImageIfUnreferenced(KEY);
    expect(present()).toEqual([false, false]);
  });

  it('evenIfFresh (the refused upload created the files) deletes at once', async () => {
    await write();
    await service.removeImageIfUnreferenced(KEY, { evenIfFresh: true });
    expect(present()).toEqual([false, false]);
  });
});
