import {
  Controller,
  HttpException,
  HttpStatus,
  Module,
  Post,
  UseGuards,
  type INestApplication,
} from '@nestjs/common';
import type { Redis } from 'ioredis';
import request, { type Response } from 'supertest';
import type { DataSource, EntityManager } from 'typeorm';
import { TenantService } from '../src/common/database/tenant.service.js';
import { TenantGuard } from '../src/common/guards/tenant.guard.js';
import {
  currentRequestContext,
  runInRequestContext,
} from '../src/common/request-context.js';
import {
  generationKey,
  TenantCache,
  type CacheNamespace,
} from '../src/infra/tenant-cache.service.js';
import { TenantImportService } from '../src/platform/tenant-import.service.js';
import { ProductsService } from '../src/products/products.service.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedMechanic,
  seedOpenShift,
  seedCustomer,
  seedProduct,
  seedSettings,
  type TenantFixture,
} from './support/fixture.js';

/**
 * A write that registers the invalidation and then fails, which no real route does
 * on purpose. It changes stock first, so a leaked hook would be visible twice over:
 * as a replaced generation, and as a MISS serving the rolled-back stock.
 */
@Controller('test-cache-rollback')
@UseGuards(TenantGuard)
class RollbackProbeController {
  constructor(
    private readonly cache: TenantCache,
    private readonly tenants: TenantService,
  ) {}

  @Post()
  write(): Promise<never> {
    // Its own runTx, as every production handler has since tx.4 (#153).
    return this.tenants.runTx(async () => {
      const { tenantId, manager } = currentRequestContext();
      await manager.query(
        `UPDATE products SET stock = 0 WHERE tenant_id = $1::uuid AND id = 'p1'`,
        [tenantId],
      );
      for (const ns of ['products', 'settings', 'customers', 'mechanics'] as const) {
        this.cache.invalidateAfterCommit(tenantId, ns);
      }
      throw new HttpException({ code: 'PROBE', message: 'rolled back' }, HttpStatus.CONFLICT);
    });
  }
}

@Module({
  controllers: [RollbackProbeController],
})
class RollbackProbeModule {}

/**
 * #32 — invalidate-after-commit. One case per row of the write-path → cache-keys table
 * in `server/README.md` *The server cache*: each primes both cached reads (list and
 * item) to a HIT, writes, and proves the very next read is a MISS carrying the new
 * value. Then the negatives: refusals and rollbacks leave the generation alone, the
 * other tenant is never touched, and the read-populate race cannot poison the cache.
 */
const TENANT = '32323232-3232-4232-8232-323232323232';
const OTHER = '32323232-4242-4242-8242-424242424242';
const PIN = '4321';
const PLATFORM_ADMIN = '32323232-5252-4252-8252-525252525252';

describe('cache invalidation after commit (e2e, #32)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: Redis;
  let fixture: TenantFixture;
  let token: string;
  let otherToken: string;
  let seq = 0;

  const http = () => request(app.getHttpServer());
  const key = () => `k32-${++seq}-${Date.now()}`;
  const post = (path: string, body: unknown = {}, t = token): Promise<Response> =>
    http()
      .post(`/api/v1${path}`)
      .set('Authorization', `Bearer ${t}`)
      .set('Idempotency-Key', key())
      .send(body as object);
  const get = (path: string, t = token): Promise<Response> =>
    http().get(`/api/v1${path}`).set('Authorization', `Bearer ${t}`);

  const generation = (tid = TENANT, ns: CacheNamespace = 'products') =>
    cache.get(generationKey(tid, ns));

  /** GET `path` twice so the second answer is a HIT. */
  const primePath = async (path: string) => {
    await get(path);
    expect((await get(path)).headers['x-cache']).toBe('HIT');
  };
  /** The next read of `path` is a MISS; returns it. */
  const miss = async (path: string) => {
    const res = await get(path);
    expect(res.headers['x-cache']).toBe('MISS');
    return res;
  };
  const row = <T extends { id: string }>(res: Response, id: string) =>
    (res.body.data as T[]).find((r) => r.id === id);

  /** Reads list and item until both are HITs, so a later MISS can only be an invalidation. */
  const prime = async (t = token, id = 'p1') => {
    await get('/products', t);
    await get(`/products/${id}`, t);
    const list = await get('/products', t);
    const item = await get(`/products/${id}`, t);
    expect(list.headers['x-cache']).toBe('HIT');
    expect(item.headers['x-cache']).toBe('HIT');
  };

  const listed = (res: Response, id = 'p1') =>
    (res.body.data as { id: string; stock: number; name: string }[]).find(
      (p) => p.id === id,
    );

  /** The next list and item reads are fresh, and show `stock` for p1. */
  const expectFresh = async (stock: number) => {
    const list = await get('/products');
    expect(list.headers['x-cache']).toBe('MISS');
    expect(listed(list)?.stock).toBe(stock);
    const item = await get('/products/p1');
    expect(item.headers['x-cache']).toBe('MISS');
    expect(item.body.data.stock).toBe(stock);
  };

  const sale = (id: string, qty: number, extra: Record<string, unknown> = {}) => {
    const total = (qty * 100).toFixed(2);
    return post('/sales', {
      id,
      subtotal: total,
      discount: '0.00',
      total,
      paymentMethod: 'เงินสด',
      items: [{ lineNo: 1, productId: 'p1', name: 'Brake Pad', qty, price: '100.00' }],
      ...extra,
    });
  };

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp([RollbackProbeModule]));
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { posDeviceNo: 32, pin: PIN, cache });
    const other = await resetTenant(admin, OTHER, { posDeviceNo: 33, cache });
    for (const tid of [TENANT, OTHER]) {
      await seedProduct(admin, tid, {
        id: 'p1',
        partNo: 'BP-1',
        name: tid === TENANT ? 'Brake Pad' : 'Other Shop Pad',
        price: 100,
        cost: 60,
        stock: 50,
      });
    }
    await seedOpenShift(admin, TENANT, fixture.posDeviceId, { userId: fixture.userId });
    await seedSettings(admin, TENANT, { shopName: 'ร้านเดิม' });
    await seedCustomer(admin, TENANT, { id: 'c1', code: 'CUS001', name: 'Somchai' });
    await seedMechanic(admin, TENANT, {
      id: 'm1',
      code: 'M001',
      name: 'Lung Manop',
      creditLimit: 10000,
      creditBalance: 500,
    });
    token = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'owner',
      deviceId: fixture.posDeviceId,
      deviceRole: 'pos',
    });
    otherToken = accessToken({
      tenantId: OTHER,
      userId: other.userId,
      role: 'owner',
      deviceId: other.posDeviceId,
      deviceRole: 'pos',
    });
  });

  afterAll(async () => {
    for (const tid of [TENANT, OTHER]) {
      await resetTenant(admin, tid, { cache });
      await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [tid]);
    }
    await admin.query(`DELETE FROM platform_admins WHERE id = $1::uuid`, [PLATFORM_ADMIN]);
    await app.close();
  });

  describe('every write path: read → write → the next read is fresh', () => {
    it('POST /products', async () => {
      await prime();
      const res = await post('/products', { partNo: 'NEW-1', name: 'New Part', stock: 3 });
      expect(res.status).toBe(201);
      const list = await get('/products');
      expect(list.headers['x-cache']).toBe('MISS');
      expect(listed(list, res.body.data.id)?.stock).toBe(3);
    });

    it('PATCH /products/:id', async () => {
      await prime();
      expect((await http()
        .patch('/api/v1/products/p1')
        .set('Authorization', `Bearer ${token}`)
        .set('Idempotency-Key', key())
        .send({ name: 'Renamed Pad' })).status).toBe(200);
      const list = await get('/products');
      expect(list.headers['x-cache']).toBe('MISS');
      expect(listed(list)?.name).toBe('Renamed Pad');
      const item = await get('/products/p1');
      expect(item.headers['x-cache']).toBe('MISS');
      expect(item.body.data.name).toBe('Renamed Pad');
    });

    it('DELETE /products/:id', async () => {
      await prime();
      expect((await http()
        .delete('/api/v1/products/p1')
        .set('Authorization', `Bearer ${token}`)
        .set('Idempotency-Key', key())).status).toBe(200);
      const list = await get('/products');
      expect(list.headers['x-cache']).toBe('MISS');
      expect(listed(list)).toBeUndefined();
      expect((await get('/products/p1')).status).toBe(404);
    });

    it('POST /products/:id/adjust-stock', async () => {
      await prime();
      expect((await post('/products/p1/adjust-stock', { delta: 5, type: 'adjustment-in' })).status)
        .toBe(201);
      await expectFresh(55);
    });

    it('POST /purchase-orders/:id/receive', async () => {
      const po = await post('/purchase-orders', {
        supplier: 'Acme',
        items: [{ partNo: 'BP-1', name: 'Brake Pad', qty: 7, cost: '60.00' }],
      });
      expect(po.status).toBe(201);
      await prime();
      expect((await post(`/purchase-orders/${po.body.data.id}/receive`)).status).toBe(200);
      await expectFresh(57);
    });

    it('POST /sales', async () => {
      await prime();
      expect((await sale('s32-sale', 2)).status).toBe(201);
      await expectFresh(48);
    });

    it('POST /quotes/:id/convert (sells through the sale path)', async () => {
      const quote = await post('/quotes', {
        subtotal: '300.00',
        discount: '0.00',
        total: '300.00',
        items: [{ productId: 'p1', name: 'Brake Pad', qty: 3, price: '100.00' }],
      });
      expect(quote.status).toBe(201);
      await prime();
      expect((await post(`/quotes/${quote.body.data.id}/convert`, {
        id: 's32-convert',
        paymentMethod: 'เงินสด',
      })).status).toBe(201);
      await expectFresh(47);
    });

    it('POST /sales/:id/void', async () => {
      expect((await sale('s32-void', 4)).status).toBe(201);
      await prime();
      expect((await post('/sales/s32-void/void', { reason: 'Return' })).status).toBe(200);
      await expectFresh(50);
    });

    it('POST /returns', async () => {
      expect((await sale('s32-return', 4)).status).toBe(201);
      await prime();
      const res = await post('/returns', {
        saleId: 's32-return',
        refundMethod: 'เงินสด',
        items: [{ productId: 'p1', name: 'Brake Pad', qty: 1, price: '100.00' }],
      });
      expect(res.status).toBe(201);
      await expectFresh(47);
    });

    it('platform tenant import (admin data source, not a request transaction)', async () => {
      // The import refuses a tenant with any shift; this one only has the fixture's.
      await admin.query(`DELETE FROM shifts WHERE tenant_id = $1::uuid`, [TENANT]);
      await admin.query(
        `INSERT INTO platform_admins (id, username, password_hash, display_name)
              VALUES ($1::uuid, $2, 'x', 'Cache Test') ON CONFLICT (id) DO NOTHING`,
        [PLATFORM_ADMIN, `admin-${PLATFORM_ADMIN}`],
      );
      await prime();
      for (const path of ['/settings', '/customers', '/mechanics']) await primePath(path);
      await app.get(TenantImportService).importSnapshot(
        TENANT,
        {
          __meta: { version: 2 },
          sa_products: [{ id: 'imp-1', partNo: 'IMP-1', name: 'Imported', stock: 9 }],
          sa_customers: [{ id: 'imp-c', code: 'CUS900', name: 'Imported Customer' }],
          sa_mechanics: [{ id: 'imp-m', code: 'M900', name: 'Imported Mechanic' }],
          sa_settings: { shopName: 'ร้านนำเข้า', shopNameEN: 'Imported Shop' },
        },
        PLATFORM_ADMIN,
      );
      const list = await get('/products');
      expect(list.headers['x-cache']).toBe('MISS');
      expect(listed(list, 'imp-1')?.stock).toBe(9);
      expect(row(await miss('/customers'), 'imp-c')).toBeDefined();
      expect(row(await miss('/mechanics'), 'imp-m')).toBeDefined();
      expect((await miss('/settings')).body.data.shopName).toBe('ร้านนำเข้า');
    });
  });

  describe('settings, customers and mechanics: read → write → the next read is fresh', () => {
    type CustomerOut = { id: string; name: string; points: number; totalSpend: string };
    type MechanicOut = { id: string; name: string; creditBalance: string; totalSales: string };

    const creditSale = (id: string) =>
      sale(id, 2, {
        paymentMethod: 'เครดิตช่าง',
        customerId: 'c1',
        customerName: 'Somchai',
        mechanicId: 'm1',
        mechanicName: 'Lung Manop',
      });

    it('POST · DELETE /categories', async () => {
      const names = (res: Response) => (res.body.data as { name: string }[]).map((c) => c.name);
      await primePath('/categories');
      expect((await post('/categories', { name: 'หมวดใหม่' })).status).toBe(201);
      expect(names(await miss('/categories'))).toContain('หมวดใหม่');

      await primePath('/categories');
      expect((await http()
        .delete(`/api/v1/categories/${encodeURIComponent('หมวดใหม่')}`)
        .set('Authorization', `Bearer ${token}`)
        .set('Idempotency-Key', key())).status).toBe(200);
      expect(names(await miss('/categories'))).not.toContain('หมวดใหม่');
    });

    it('PATCH /settings', async () => {
      await primePath('/settings');
      const res = await http()
        .patch('/api/v1/settings')
        .set('Authorization', `Bearer ${token}`)
        .set('Idempotency-Key', key())
        .send({ shopName: 'ร้านใหม่' });
      expect(res.status).toBe(200);
      expect((await miss('/settings')).body.data.shopName).toBe('ร้านใหม่');
    });

    it('POST · PATCH · DELETE /customers', async () => {
      await primePath('/customers');
      const created = await post('/customers', { name: 'New', nameTH: 'ใหม่' });
      expect(created.status).toBe(201);
      const id = created.body.data.id as string;
      expect(row<CustomerOut>(await miss('/customers'), id)?.name).toBe('New');

      await primePath('/customers');
      expect((await http()
        .patch(`/api/v1/customers/${id}`)
        .set('Authorization', `Bearer ${token}`)
        .set('Idempotency-Key', key())
        .send({ name: 'Renamed' })).status).toBe(200);
      expect(row<CustomerOut>(await miss('/customers'), id)?.name).toBe('Renamed');

      await primePath('/customers');
      expect((await http()
        .delete(`/api/v1/customers/${id}`)
        .set('Authorization', `Bearer ${token}`)
        .set('Idempotency-Key', key())).status).toBe(200);
      expect(row<CustomerOut>(await miss('/customers'), id)).toBeUndefined();
    });

    it('POST · PATCH · DELETE /mechanics', async () => {
      await primePath('/mechanics');
      const created = await post('/mechanics', { name: 'New Mechanic' });
      expect(created.status).toBe(201);
      const id = created.body.data.id as string;
      expect(row<MechanicOut>(await miss('/mechanics'), id)?.name).toBe('New Mechanic');

      await primePath('/mechanics');
      expect((await http()
        .patch(`/api/v1/mechanics/${id}`)
        .set('Authorization', `Bearer ${token}`)
        .set('Idempotency-Key', key())
        .send({ name: 'Renamed Mechanic' })).status).toBe(200);
      expect(row<MechanicOut>(await miss('/mechanics'), id)?.name).toBe('Renamed Mechanic');

      await primePath('/mechanics');
      expect((await http()
        .delete(`/api/v1/mechanics/${id}`)
        .set('Authorization', `Bearer ${token}`)
        .set('Idempotency-Key', key())).status).toBe(200);
      expect(row<MechanicOut>(await miss('/mechanics'), id)).toBeUndefined();
    });

    it('POST /mechanics/:id/credit-payments', async () => {
      await primePath('/mechanics');
      const res = await post('/mechanics/m1/credit-payments', {
        amount: '200.00',
        paymentMethod: 'เงินสด',
      });
      expect(res.status).toBe(201);
      expect(row<MechanicOut>(await miss('/mechanics'), 'm1')?.creditBalance).toBe('300.00');
    });

    it('POST /sales naming a customer and a mechanic', async () => {
      await primePath('/customers');
      await primePath('/mechanics');
      expect((await creditSale('s32-ledger')).status).toBe(201);
      expect(row<CustomerOut>(await miss('/customers'), 'c1')).toMatchObject({
        points: 20,
        totalSpend: '200.00',
      });
      expect(row<MechanicOut>(await miss('/mechanics'), 'm1')).toMatchObject({
        creditBalance: '700.00',
        totalSales: '200.00',
      });
    });

    it('POST /sales with no customer or mechanic leaves those caches alone', async () => {
      await primePath('/customers');
      await primePath('/mechanics');
      expect((await sale('s32-walkin', 1)).status).toBe(201);
      expect((await get('/customers')).headers['x-cache']).toBe('HIT');
      expect((await get('/mechanics')).headers['x-cache']).toBe('HIT');
    });

    it('POST /sales/:id/void reverses the ledger', async () => {
      expect((await creditSale('s32-ledger-void')).status).toBe(201);
      await primePath('/customers');
      await primePath('/mechanics');
      expect((await post('/sales/s32-ledger-void/void', { reason: 'Return' })).status).toBe(200);
      expect(row<CustomerOut>(await miss('/customers'), 'c1')).toMatchObject({
        points: 0,
        totalSpend: '0.00',
      });
      expect(row<MechanicOut>(await miss('/mechanics'), 'm1')?.creditBalance).toBe('500.00');
    });

    it('POST /returns reverses the ledger', async () => {
      expect((await creditSale('s32-ledger-return')).status).toBe(201);
      await primePath('/customers');
      await primePath('/mechanics');
      const res = await post('/returns', {
        saleId: 's32-ledger-return',
        refundMethod: 'หักจากเครดิต',
        items: [{ productId: 'p1', name: 'Brake Pad', qty: 1, price: '100.00' }],
      });
      expect(res.status).toBe(201);
      expect(row<CustomerOut>(await miss('/customers'), 'c1')?.totalSpend).toBe('100.00');
      expect(row<MechanicOut>(await miss('/mechanics'), 'm1')?.creditBalance).toBe('600.00');
    });

    it('409 CREDIT_LIMIT_EXCEEDED on a bill naming a customer and a mechanic: no invalidation', async () => {
      await admin.query(
        `UPDATE mechanics SET credit_limit = 100 WHERE tenant_id = $1::uuid AND id = 'm1'`,
        [TENANT],
      );
      await primePath('/customers');
      await primePath('/mechanics');
      const before = [await generation(TENANT, 'customers'), await generation(TENANT, 'mechanics')];
      const res = await creditSale('s32-ledger-refused');
      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('CREDIT_LIMIT_EXCEEDED');
      expect([await generation(TENANT, 'customers'), await generation(TENANT, 'mechanics')])
        .toEqual(before);
      expect((await get('/customers')).headers['x-cache']).toBe('HIT');
      const mechanics = await get('/mechanics');
      expect(mechanics.headers['x-cache']).toBe('HIT');
      expect(row<MechanicOut>(mechanics, 'm1')?.creditBalance).toBe('500.00');
    });

    it('409 CREDIT_PAYMENT_EXCEEDS_BALANCE: no invalidation', async () => {
      await primePath('/mechanics');
      const before = await generation(TENANT, 'mechanics');
      const res = await post('/mechanics/m1/credit-payments', {
        amount: '900.00',
        paymentMethod: 'เงินสด',
      });
      expect(res.status).toBe(409);
      expect(await generation(TENANT, 'mechanics')).toBe(before);
      expect((await get('/mechanics')).headers['x-cache']).toBe('HIT');
    });
  });

  describe('refused and rolled-back writes leave the cache untouched', () => {
    it('409 INSUFFICIENT_STOCK: no invalidation, the cached page still answers', async () => {
      await prime();
      const before = await generation();
      const res = await sale('s32-short', 999);
      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('INSUFFICIENT_STOCK');
      expect(await generation()).toBe(before);
      const list = await get('/products');
      expect(list.headers['x-cache']).toBe('HIT');
      expect(listed(list)?.stock).toBe(50);
    });

    it('409 CREDIT_LIMIT_EXCEEDED: no invalidation', async () => {
      await seedMechanic(admin, TENANT, {
        id: 'm32',
        code: 'M-32',
        name: 'Tight Limit',
        creditLimit: 100,
      });
      await prime();
      const before = await generation();
      const res = await sale('s32-credit', 2, {
        paymentMethod: 'เครดิตช่าง',
        mechanicId: 'm32',
        mechanicName: 'Tight Limit',
      });
      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('CREDIT_LIMIT_EXCEEDED');
      expect(await generation()).toBe(before);
      expect((await get('/products')).headers['x-cache']).toBe('HIT');
    });

    it('a transaction that registered the invalidation and then rolled back performs none', async () => {
      await prime();
      for (const path of ['/settings', '/customers', '/mechanics']) await primePath(path);
      const namespaces = ['products', 'settings', 'customers', 'mechanics'] as const;
      const before = await Promise.all(namespaces.map((ns) => generation(TENANT, ns)));
      const res = await http()
        .post('/api/v1/test-cache-rollback')
        .set('Authorization', `Bearer ${token}`);
      expect(res.status).toBe(409);
      expect(await Promise.all(namespaces.map((ns) => generation(TENANT, ns)))).toEqual(before);
      for (const path of ['/settings', '/customers', '/mechanics']) {
        expect((await get(path)).headers['x-cache']).toBe('HIT');
      }
      // The stock write rolled back, and the cached page (still 50) is still the truth.
      const [row] = await admin.query(
        `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = 'p1'`,
        [TENANT],
      );
      expect(row.stock).toBe(50);
      const list = await get('/products');
      expect(list.headers['x-cache']).toBe('HIT');
      expect(listed(list)?.stock).toBe(50);
    });
  });

  it("tenant A's write never invalidates or exposes tenant B's keys", async () => {
    await prime();
    await prime(otherToken);
    const otherBefore = await generation(OTHER);

    expect((await sale('s32-tenant', 1)).status).toBe(201);

    expect(await generation(OTHER)).toBe(otherBefore);
    const otherList = await get('/products', otherToken);
    expect(otherList.headers['x-cache']).toBe('HIT');
    expect(listed(otherList)).toMatchObject({ name: 'Other Shop Pad', stock: 50 });

    const mine = await get('/products');
    expect(mine.headers['x-cache']).toBe('MISS');
    expect(listed(mine)).toMatchObject({ name: 'Brake Pad', stock: 49 });
  });

  it('read-populate race: a reader that read before the commit cannot cache over the invalidation', async () => {
    const products = app.get(ProductsService);
    const tenantCache = app.get(TenantCache);
    // The slow reader's "query" runs while a writer commits stock 40 and invalidates;
    // it still answers with the pre-commit row, as a query that started first would.
    let calls = 0;
    const slowManager = {
      query: async (sql: string, params: unknown[]) => {
        if (calls++ === 0) {
          await admin.query(
            `UPDATE products SET stock = 40 WHERE tenant_id = $1::uuid AND id = 'p1'`,
            [TENANT],
          );
          await tenantCache.invalidate(TENANT, 'products');
        }
        const rows = await admin.query(sql, params);
        return sql.startsWith('SELECT count') ? rows : rows.map((r: { id: string }) =>
          r.id === 'p1' ? { ...r, stock: 50 } : r,
        );
      },
    } as unknown as EntityManager;

    const stale = await runInRequestContext(
      { tenantId: TENANT, manager: slowManager },
      () => products.list({ page: 1, limit: 50 }),
    );
    expect(stale.fromCache).toBe(false);
    expect(stale.items.find((p) => p.id === 'p1')?.stock).toBe(50);

    const next = await get('/products?limit=50');
    expect(next.headers['x-cache']).toBe('MISS');
    expect(listed(next)?.stock).toBe(40);
  });
});
