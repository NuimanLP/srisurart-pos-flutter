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
      role: 'owner',
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

  /*
   * A credit note dated outside its bill's range: j1 (20 Jun, 300 = p2 1@200 cost 100
   * + p3 1@100 cost 10) and rj1 (2 Jul, p2 1 back, refund 200, cost 100).
   *
   *   June  revenue 300, 1 bill, avg 300, refunds 0, net 300, items 2
   *         gross profit 300 ÷ 1.07 = 280.3738 − 110 = 170.37
   *   July  no bills; refunds 200, net −200, items −1
   *         gross profit −200 ÷ 1.07 = −186.9159 + 100 = −86.92
   *
   * June keeps its bill; July nets the note by its own date, without its parent.
   * Kept out of September so the top-products and by-category figures there stand.
   */
  it('nets a credit note in its own range, apart from a parent bill in another', async () => {
    const june = await get('/summary?from=2026-06&to=2026-06');
    expect(june.status).toBe(200);
    expect(june.body.data).toEqual({
      totalRevenue: '300.00',
      totalTransactions: 1,
      avgTicket: '300.00',
      totalRefunds: '0.00',
      netRevenue: '300.00',
      totalItems: 2,
      grossProfit: '170.37',
      estimatedCostRows: 0,
      unknownCostRows: 0,
    });

    const july = await get('/summary?from=2026-07&to=2026-07');
    expect(july.status).toBe(200);
    expect(july.body.data).toEqual({
      totalRevenue: '0.00',
      totalTransactions: 0,
      avgTicket: '0.00',
      totalRefunds: '200.00',
      netRevenue: '-200.00',
      totalItems: -1,
      grossProfit: '-86.92',
      estimatedCostRows: 0,
      unknownCostRows: 0,
    });
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
      // (500 − 100) ÷ 1.07 = 373.8318 − (s1 2×50 + s2 50 + 100 − r1 50 = 200)
      grossProfit: '173.83',
      estimatedCostRows: 0,
      unknownCostRows: 0,
    });

    const day = await get('/summary?from=2026-09-01&to=2026-09-01');
    expect(day.body.data).toMatchObject({
      totalRevenue: '200.00',
      totalTransactions: 1,
      totalRefunds: '0.00',
      netRevenue: '200.00',
      totalItems: 2,
      // 200 ÷ 1.07 = 186.9159 − 2×50 (r1 is dated 20 Sep, outside this day)
      grossProfit: '86.92',
    });
  });

  /*
   * #95 — August holds the three kinds of bill the summary must tell apart:
   *
   *   a1  counted   350: p2 1@200 (cost_at_sale 100), p3 1@100 (null → today's 10),
   *                      'gone' 1@50 (null, no product row → 0)
   *   a2  manual void 400: p1 4@100 — voided with no credit note, excluded
   *   a3  auto-void   200: p1 2@100 (cost 50) — voided by ra3, its full return, counted
   *   ra3 credit note 200: p1 2 (cost 50)
   *
   *   revenue 350 + 200 = 550 over 2 bills, avg 275; refunds 200; net 350
   *   items (3 + 2) − 2 = 3
   *   gross profit (550 − 200) ÷ 1.07 = 327.1028 − (100 + 10 + 0 + 100 − 100 = 110) = 217.10
   *
   * #29's query counted a2 too: revenue 950, 3 bills, avg 317, net 750, items 7 — a
   * response whose revenue and gross profit came from two different sets of bills.
   * Falsified by dropping `AND ${COUNTED_SALE}` from gp_sales: those #29 figures return,
   * with grossProfit 390.93.
   */
  it('builds every summary figure, gross profit included, from one set of bills', async () => {
    const res = await get('/summary?from=2026-08&to=2026-08');
    expect(res.status).toBe(200);
    expect(res.body.data).toEqual({
      totalRevenue: '550.00',
      totalTransactions: 2,
      avgTicket: '275.00',
      totalRefunds: '200.00',
      netRevenue: '350.00',
      totalItems: 3,
      grossProfit: '217.10',
      estimatedCostRows: 1,
      unknownCostRows: 1,
    });
  });

  /*
   * #97 — the item reports over August's bill set above. Lines are price × qty
   * (not bill-discounted, as #29 documents):
   *
   *   a1  p2 1@200 (oils), p3 1@100 (filters), 'gone' 1@50 (no product → อื่นๆ)
   *   a2  manual void — p1 4@100 excluded
   *   a3  p1 2@100 (brakes), counted;  ra3  p1 −2 @100 nets it to 0 / 0.00
   *
   *   top-products  p2 1/200, p3 1/100, gone 1/50 (p1 nets to zero, dropped by HAVING)
   *   by-category   oils 1/200, filters 1/100, อื่นๆ 1/50
   *   product-sales p1 0 / 0.00
   *
   * Without `COUNTED_SALE` in the sale_events CTEs a2 comes back as p1 4/400: first in
   * top-products, brakes 4/400 first in by-category, product-sales p1 4 / 400.00.
   * The other direction guards the auto-void half: a filter as broad as `NOT s.voided`
   * would also drop a3 and leave p1 at −2/−200 in all three — keep a3 and ra3 in the seed.
   */
  it('excludes manual voids from top products, categories, and product sales', async () => {
    const top = await get('/top-products?from=2026-08&to=2026-08&limit=10');
    expect(top.status).toBe(200);
    expect(top.body.data).toEqual([
      {
        productId: 'p2',
        partNo: 'OIL-1',
        name: 'Oil',
        qty: 1,
        revenue: '200.00',
      },
      {
        productId: 'p3',
        partNo: 'FILTER-1',
        name: 'Filter',
        qty: 1,
        revenue: '100.00',
      },
      {
        productId: 'gone',
        partNo: 'GONE',
        name: 'Deleted part',
        qty: 1,
        revenue: '50.00',
      },
    ]);

    const categories = await get('/by-category?from=2026-08&to=2026-08');
    expect(categories.status).toBe(200);
    expect(categories.body.data).toEqual([
      { category: 'oils', qty: 1, revenue: '200.00' },
      { category: 'filters', qty: 1, revenue: '100.00' },
      { category: 'อื่นๆ', qty: 1, revenue: '50.00' },
    ]);

    const product = await get(
      '/product-sales?productId=p1&from=2026-08&to=2026-08',
    );
    expect(product.status).toBe(200);
    expect(product.body.data).toEqual({
      productId: 'p1',
      partNo: 'BRAKE-1',
      name: 'Brake Pad',
      qty: 0,
      revenue: '0.00',
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

    // June bill, July partial credit note (#95): a note outside its bill's range.
    await admin.query(
      `INSERT INTO sales
              (tenant_id, id, receipt_no, subtotal, discount, total, payment_method, date)
       VALUES ($1::uuid, 'j1', 'RC-A-J1', 300, 0, 300, 'เงินสด', '2026-06-20T10:00:00+07')`,
      [TENANT_A],
    );
    await admin.query(
      `INSERT INTO sale_items
              (tenant_id, sale_id, line_no, product_id, part_no, name, qty, price, cost_at_sale)
       VALUES ($1::uuid, 'j1', 1, 'p2', 'OIL-1', 'Oil', 1, 200, 100),
              ($1::uuid, 'j1', 2, 'p3', 'FILTER-1', 'Filter', 1, 100, 10)`,
      [TENANT_A],
    );
    await admin.query(
      `INSERT INTO returns
              (tenant_id, id, cn_no, sale_id, receipt_no, refund_subtotal,
               refund_discount, refund_total, refund_method, date)
       VALUES ($1::uuid, 'rj1', 'CN-A-J1', 'j1', 'RC-A-J1', 200, 0, 200, 'เงินสด',
               '2026-07-02T10:00:00+07')`,
      [TENANT_A],
    );
    await admin.query(
      `INSERT INTO return_items
              (tenant_id, return_id, line_no, product_id, name, qty, price, original_qty, cost_at_sale)
       VALUES ($1::uuid, 'rj1', 1, 'p2', 'Oil', 1, 200, 1, 100)`,
      [TENANT_A],
    );

    // August (#95): a counted bill with estimated and unknown cost lines, a manual
    // void, and a bill auto-voided by its full return.
    await admin.query(
      `INSERT INTO sales
              (tenant_id, id, receipt_no, subtotal, discount, total, payment_method, date,
               voided, voided_at)
       VALUES ($1::uuid, 'a1', 'RC-A-A1', 350, 0, 350, 'เงินสด', '2026-08-03T10:00:00+07',
               FALSE, NULL),
              ($1::uuid, 'a2', 'RC-A-A2', 400, 0, 400, 'เงินสด', '2026-08-10T10:00:00+07',
               TRUE, '2026-08-10T10:05:00+07'),
              ($1::uuid, 'a3', 'RC-A-A3', 200, 0, 200, 'เงินสด', '2026-08-12T10:00:00+07',
               TRUE, '2026-08-12T11:00:00+07')`,
      [TENANT_A],
    );
    await admin.query(
      `INSERT INTO sale_items
              (tenant_id, sale_id, line_no, product_id, part_no, name, qty, price, cost_at_sale)
       VALUES ($1::uuid, 'a1', 1, 'p2', 'OIL-1', 'Oil', 1, 200, 100),
              ($1::uuid, 'a1', 2, 'p3', 'FILTER-1', 'Filter', 1, 100, NULL),
              ($1::uuid, 'a1', 3, 'gone', 'GONE', 'Deleted part', 1, 50, NULL),
              ($1::uuid, 'a2', 1, 'p1', 'BRAKE-1', 'Brake Pad', 4, 100, 50),
              ($1::uuid, 'a3', 1, 'p1', 'BRAKE-1', 'Brake Pad', 2, 100, 50)`,
      [TENANT_A],
    );
    await admin.query(
      `INSERT INTO returns
              (tenant_id, id, cn_no, sale_id, receipt_no, refund_subtotal,
               refund_discount, refund_total, refund_method, date)
       VALUES ($1::uuid, 'ra3', 'CN-A-A3', 'a3', 'RC-A-A3', 200, 0, 200, 'เงินสด',
               '2026-08-12T11:00:00+07')`,
      [TENANT_A],
    );
    await admin.query(
      `INSERT INTO return_items
              (tenant_id, return_id, line_no, product_id, name, qty, price, original_qty, cost_at_sale)
       VALUES ($1::uuid, 'ra3', 1, 'p1', 'Brake Pad', 2, 100, 2, 50)`,
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
    await admin.query('ANALYZE sales; ANALYZE sale_items;');
  }
});
