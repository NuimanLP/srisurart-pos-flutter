import { performance } from 'node:perf_hooks';
import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import {
  accessToken,
  createTestApp,
  resetTenant,
  type TenantFixture,
} from './support/fixture.js';

const TENANT_A = '29292929-2929-4929-8929-292929292929';
const TENANT_B = '30303030-3030-4030-8030-303030303030';

describe('server-side reports (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;
  let token: string;

  const get = (path: string) =>
    request(app.getHttpServer())
      .get(`/api/v1/reports${path}`)
      .set({ Authorization: `Bearer ${token}` });

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
    fixture = await resetTenant(admin, TENANT_A, { cache });
    await resetTenant(admin, TENANT_B, { cache });
    token = accessToken({
      tenantId: TENANT_A,
      userId: fixture.userId,
      role: 'manager',
      deviceId: fixture.backofficeDeviceId,
      deviceRole: 'backoffice',
    });
    await seedPrimaryDataset();
    await seedOtherTenant();
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT_A);
    await resetTenant(admin, TENANT_B);
    await admin.query(`DELETE FROM tenants WHERE id IN ($1::uuid, $2::uuid)`, [
      TENANT_A,
      TENANT_B,
    ]);
    await app.close();
  });

  it('matches the client KPI arithmetic and nets credit notes from revenue and quantity', async () => {
    const month = await get('/summary?from=2026-09&to=2026-09');
    expect(month.status).toBe(200);
    expect(month.body.data).toEqual({
      totalRevenue: '500.00',
      totalTransactions: 2,
      avgTicket: '250.00',
      totalRefunds: '100.00',
      netRevenue: '400.00',
      totalItems: 3,
    });

    const day = await get('/summary?from=2026-09-01&to=2026-09-01');
    expect(day.body.data).toMatchObject({
      totalRevenue: '200.00',
      totalTransactions: 1,
      totalRefunds: '0.00',
      netRevenue: '200.00',
      totalItems: 2,
    });
  });

  it('aggregates top products, categories, and one product entirely at the SQL seam', async () => {
    const top = await get(
      '/top-products?from=2026-09-01&to=2026-09-30&limit=10',
    );
    expect(top.status).toBe(200);
    expect(top.body.data).toEqual([
      {
        productId: 'p1',
        partNo: 'BRAKE-1',
        name: 'Brake Pad',
        qty: 2,
        revenue: '200.00',
      },
      {
        productId: 'p2',
        partNo: 'OIL-1',
        name: 'Oil',
        qty: 1,
        revenue: '200.00',
      },
    ]);

    const categories = await get('/by-category?from=2026-09&to=2026-09');
    expect(categories.status).toBe(200);
    expect(categories.body.data).toEqual([
      { category: 'brakes', qty: 2, revenue: '200.00' },
      { category: 'oils', qty: 1, revenue: '200.00' },
    ]);

    const product = await get(
      '/product-sales?productId=p1&from=2026-09&to=2026-09',
    );
    expect(product.status).toBe(200);
    expect(product.body.data).toEqual({
      productId: 'p1',
      partNo: 'BRAKE-1',
      name: 'Brake Pad',
      qty: 2,
      revenue: '200.00',
    });
  });

  it('computes stock value and returns a bounded, out-of-stock-first low-stock page', async () => {
    const value = await get('/stock-value');
    expect(value.status).toBe(200);
    expect(value.body.data).toEqual({
      productCount: 3,
      totalUnits: 13,
      totalValue: '210.00',
    });

    const first = await get('/low-stock?page=1&limit=1');
    const second = await get('/low-stock?page=2&limit=1');
    expect(first.body.meta).toEqual({
      total: 2,
      page: 1,
      limit: 1,
      totalPages: 2,
    });
    expect(first.body.data[0]).toMatchObject({
      id: 'p2',
      stock: 0,
      minStock: 1,
    });
    expect(second.body.data[0]).toMatchObject({
      id: 'p1',
      stock: 2,
      minStock: 2,
    });
  });

  it('accepts only real yyyy-MM-dd / yyyy-MM keys and bounded limits', async () => {
    expect((await get('/summary?from=2026-02-30')).status).toBe(400);
    expect((await get('/summary?from=2026/09')).status).toBe(400);
    expect((await get('/summary?from=2026-10&to=2026-09')).status).toBe(400);
    expect((await get('/product-sales')).status).toBe(400);
    expect((await get('/top-products?limit=0')).status).toBe(400);
  });

  it('never exposes another tenant through any report shape', async () => {
    const responses = await Promise.all([
      get('/summary?from=2026-09&to=2026-09'),
      get('/top-products?from=2026-09&to=2026-09'),
      get('/by-category?from=2026-09&to=2026-09'),
      get('/stock-value'),
      get('/low-stock'),
      get('/product-sales?productId=secret&from=2026-09&to=2026-09'),
    ]);
    expect(responses.every((response) => response.status === 200)).toBe(true);
    expect(responses[0].body.data.totalRevenue).toBe('500.00');
    expect(
      JSON.stringify(responses.map((response) => response.body)).includes(
        '999999.00',
      ),
    ).toBe(false);
    expect(
      JSON.stringify(responses.map((response) => response.body)).includes(
        'SECRET',
      ),
    ).toBe(false);
    expect(responses[5].body.data).toEqual({
      productId: 'secret',
      partNo: 'secret',
      name: 'secret',
      qty: 0,
      revenue: '0.00',
    });
  });

  it('keeps every endpoint below the §9 read latency budget on the demo dataset', async () => {
    await addDemoVolume();
    const paths = [
      '/summary?from=2026-09&to=2026-09',
      '/top-products?from=2026-09&to=2026-09',
      '/by-category?from=2026-09&to=2026-09',
      '/stock-value',
      '/low-stock?limit=5',
      '/product-sales?productId=p1&from=2026-09&to=2026-09',
    ];

    for (const path of paths) {
      expect((await get(path)).status).toBe(200); // warm caches and the connection
      const samples: number[] = [];
      for (let index = 0; index < 10; index++) {
        const started = performance.now();
        const response = await get(path);
        samples.push(performance.now() - started);
        expect(response.status).toBe(200);
      }
      samples.sort((a, b) => a - b);
      const p95 = samples[Math.ceil(samples.length * 0.95) - 1];
      expect(p95, `${path} p95 was ${p95.toFixed(1)} ms`).toBeLessThan(200);
    }
  });

  async function seedPrimaryDataset(): Promise<void> {
    await admin.query(
      `INSERT INTO products
              (tenant_id, id, part_no, name, name_th, category, brand,
               price, cost, stock, min_stock)
       VALUES ($1::uuid, 'p1', 'BRAKE-1', 'Brake Pad', 'ผ้าเบรก', 'brakes', 'A', 100, 50, 2, 2),
              ($1::uuid, 'p2', 'OIL-1', 'Oil', 'น้ำมัน', 'oils', 'B', 200, 100, 0, 1),
              ($1::uuid, 'p3', 'FILTER-1', 'Filter', 'กรอง', 'filters', 'C', 100, 10, 11, 2)`,
      [TENANT_A],
    );
    await admin.query(
      `INSERT INTO sales
              (tenant_id, id, receipt_no, subtotal, discount, total, payment_method, date)
       VALUES ($1::uuid, 's1', 'RC-A-1', 200, 0, 200, 'เงินสด', '2026-09-01T00:00:00+07'),
              ($1::uuid, 's2', 'RC-A-2', 300, 0, 300, 'เงินสด', '2026-09-15T12:00:00+07'),
              ($1::uuid, 's3', 'RC-A-3', 100, 0, 100, 'เงินสด', '2026-10-01T00:00:00+07')`,
      [TENANT_A],
    );
    await admin.query(
      `INSERT INTO sale_items
              (tenant_id, sale_id, line_no, product_id, part_no, name, name_th, qty, price, cost_at_sale)
       VALUES ($1::uuid, 's1', 1, 'p1', 'BRAKE-1', 'Brake Pad', 'ผ้าเบรก', 2, 100, 50),
              ($1::uuid, 's2', 1, 'p1', 'BRAKE-1', 'Brake Pad', 'ผ้าเบรก', 1, 100, 50),
              ($1::uuid, 's2', 2, 'p2', 'OIL-1', 'Oil', 'น้ำมัน', 1, 200, 100),
              ($1::uuid, 's3', 1, 'p3', 'FILTER-1', 'Filter', 'กรอง', 1, 100, 10)`,
      [TENANT_A],
    );
    await admin.query(
      `INSERT INTO returns
              (tenant_id, id, cn_no, sale_id, receipt_no, refund_subtotal,
               refund_discount, refund_total, refund_method, date)
       VALUES ($1::uuid, 'r1', 'CN-A-1', 's1', 'RC-A-1', 100, 0, 100, 'เงินสด',
               '2026-09-20T10:00:00+07')`,
      [TENANT_A],
    );
    await admin.query(
      `INSERT INTO return_items
              (tenant_id, return_id, line_no, product_id, name, qty, price, original_qty, cost_at_sale)
       VALUES ($1::uuid, 'r1', 1, 'p1', 'Brake Pad', 1, 100, 2, 50)`,
      [TENANT_A],
    );
  }

  async function seedOtherTenant(): Promise<void> {
    await admin.query(
      `INSERT INTO products
              (tenant_id, id, part_no, name, name_th, category, brand,
               price, cost, stock, min_stock)
       VALUES ($1::uuid, 'p1', 'SECRET-SAME-ID', 'SECRET', 'ลับ', 'secret', 'X',
               999999, 999999, 99, 100),
              ($1::uuid, 'secret', 'SECRET', 'SECRET', 'ลับ', 'secret', 'X',
               999999, 999999, 0, 1)`,
      [TENANT_B],
    );
    await admin.query(
      `INSERT INTO sales
              (tenant_id, id, receipt_no, subtotal, discount, total, payment_method, date)
       VALUES ($1::uuid, 'secret-sale', 'SECRET-RC', 999999, 0, 999999,
               'เงินสด', '2026-09-10T10:00:00+07')`,
      [TENANT_B],
    );
    await admin.query(
      `INSERT INTO sale_items
              (tenant_id, sale_id, line_no, product_id, part_no, name, qty, price)
       VALUES ($1::uuid, 'secret-sale', 1, 'p1', 'SECRET-SAME-ID', 'SECRET', 1, 999999)`,
      [TENANT_B],
    );
  }

  async function addDemoVolume(): Promise<void> {
    await admin.query(
      `INSERT INTO sales
              (tenant_id, id, receipt_no, subtotal, discount, total, payment_method, date)
       SELECT $1::uuid, 'perf-' || g, 'PERF-' || g, 100, 0, 100, 'เงินสด',
              '2026-09-10T10:00:00+07'::timestamptz
         FROM generate_series(1, 5000) AS g`,
      [TENANT_A],
    );
    await admin.query(
      `INSERT INTO sale_items
              (tenant_id, sale_id, line_no, product_id, part_no, name, qty, price, cost_at_sale)
       SELECT $1::uuid, 'perf-' || g, 1, 'p1', 'BRAKE-1', 'Brake Pad', 1, 100, 50
         FROM generate_series(1, 5000) AS g`,
      [TENANT_A],
    );
  }
});
