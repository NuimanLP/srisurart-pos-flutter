import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedCustomer,
  seedMechanic,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';

// #22 acceptance suite. Every case in `frontend/test/returns_repository_test.dart` is
// reproduced here at the HTTP seam with its numbers and its Thai strings verbatim,
// plus the four things that only exist on the server: idempotency, the device role,
// the negative-price guard, and `cost_at_sale` / `shift_id` on the credit note.
const TENANT = 'eeeeeeee-2222-4222-8222-eeeeeeeeeeee';

interface SaleLine {
  productId: string;
  name: string;
  qty: number;
  price: number;
  costAtSale?: number;
}

interface RefundLine {
  productId: string;
  name: string;
  qty: number;
  price: string;
}

describe('POST /returns (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;
  let posToken: string;
  let backofficeToken: string;

  const post = (body: unknown, opts: { key?: string; token?: string } = {}) =>
    request(app.getHttpServer())
      .post('/api/v1/returns')
      .set('Authorization', `Bearer ${opts.token ?? posToken}`)
      .set('Idempotency-Key', opts.key ?? `k-${Math.random()}`)
      .send(body as object);

  const listReturns = (query = '') =>
    request(app.getHttpServer())
      .get(`/api/v1/returns${query}`)
      .set('Authorization', `Bearer ${posToken}`);

  /** A credit-note body. `reason` is left off so the '' default is exercised. */
  const credit = (
    saleId: string,
    items: RefundLine[],
    refundMethod = 'เงินสด',
  ) => ({ saleId, refundMethod, items });

  /**
   * Seeds a bill directly, the way `returns_repository_test.dart` does: the scenarios
   * need exact control over `points_granted`, `mechanic_delta` and `voided`, which a
   * bill rung up through `POST /sales` cannot give.
   */
  const insertSale = async (sale: {
    id: string;
    receiptNo: string;
    subtotal: number;
    discount?: number;
    total: number;
    paymentMethod?: string;
    customerId?: string;
    mechanicId?: string;
    mechanicName?: string;
    mechanicDelta?: number;
    pointsGranted?: number;
    voided?: boolean;
    items: SaleLine[];
  }): Promise<void> => {
    await admin.query(
      `INSERT INTO sales (tenant_id, id, receipt_no, subtotal, discount, total,
                          payment_method, customer_id, mechanic_id, mechanic_name,
                          mechanic_delta, points_granted, voided)
            VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)`,
      [
        TENANT,
        sale.id,
        sale.receiptNo,
        sale.subtotal,
        sale.discount ?? 0,
        sale.total,
        sale.paymentMethod ?? 'เงินสด',
        sale.customerId ?? null,
        sale.mechanicId ?? null,
        sale.mechanicName ?? null,
        sale.mechanicDelta ?? null,
        sale.pointsGranted ?? 0,
        sale.voided ?? false,
      ],
    );
    for (const [i, line] of sale.items.entries()) {
      await admin.query(
        `INSERT INTO sale_items (tenant_id, sale_id, line_no, product_id, name, qty, price, cost_at_sale)
              VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8)`,
        [
          TENANT,
          sale.id,
          i + 1,
          line.productId,
          line.name,
          line.qty,
          line.price,
          line.costAtSale ?? null,
        ],
      );
    }
  };

  const stockOf = async (id: string): Promise<number> => {
    const rows = await admin.query(
      `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, id],
    );
    return rows[0].stock as number;
  };

  const returnCount = async (): Promise<number> => {
    const rows = await admin.query(
      `SELECT count(*)::int AS n FROM returns WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    return rows[0].n as number;
  };

  const saleRow = async (id: string) => {
    const rows = await admin.query(
      `SELECT voided, voided_at FROM sales WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, id],
    );
    return rows[0] as { voided: boolean; voided_at: Date | null };
  };

  const customerRow = async (id: string) => {
    const rows = await admin.query(
      `SELECT points, total_spend FROM customers WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, id],
    );
    return rows[0] as { points: number; total_spend: string };
  };

  const mechanicRow = async (id: string) => {
    const rows = await admin.query(
      `SELECT credit_balance, total_sales, total_credit, total_discount, total_markup
         FROM mechanics WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, id],
    );
    return rows[0] as {
      credit_balance: string;
      total_sales: string;
      total_credit: string;
      total_discount: string;
      total_markup: string;
    };
  };

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { posDeviceNo: 7, cache });
    posToken = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'manager',
      deviceId: fixture.posDeviceId,
      deviceRole: 'pos',
    });
    backofficeToken = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'manager',
      deviceId: fixture.backofficeDeviceId,
      deviceRole: 'backoffice',
    });
    await seedProduct(admin, TENANT, {
      id: 'p1',
      partNo: 'HN-15412-KVB',
      name: 'Oil Filter',
      nameTH: 'กรองน้ำมันเครื่อง',
      price: 85,
      cost: 50,
      stock: 48,
    });
    await seedProduct(admin, TENANT, {
      id: 'p2',
      partNo: 'NGK-CPR8EA',
      name: 'Spark Plug',
      nameTH: 'หัวเทียน',
      price: 70,
      cost: 40,
      stock: 30,
    });
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it('an unknown bill is 404 SALE_NOT_FOUND', async () => {
    const res = await post(
      credit('nope', [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
      ]),
    );
    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('SALE_NOT_FOUND');
    expect(res.body.error.message).toBe('Sale not found');
  });

  it('a bill that is already voided is refused', async () => {
    await insertSale({
      id: 's_void',
      receiptNo: 'R1',
      subtotal: 85,
      total: 85,
      voided: true,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 1, price: 85 }],
    });

    const res = await post(
      credit('s_void', [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
      ]),
    );
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('SALE_VOIDED');
    expect(res.body.error.message).toBe('Bill already voided');
  });

  it('over-refunding is refused with the Thai message, and nothing is written', async () => {
    await insertSale({
      id: 's_over',
      receiptNo: 'R2',
      subtotal: 170,
      total: 170,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 2, price: 85 }],
    });
    const before = await stockOf('p1');

    const res = await post(
      credit('s_over', [
        { productId: 'p1', name: 'Oil Filter', qty: 5, price: '85.00' },
      ]),
    );
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('OVER_REFUND');
    expect(res.body.error.message).toBe(
      'คืนเกินจำนวนที่ขาย:\nOil Filter: คืนได้อีก 2 แต่ขอคืน 5',
    );

    // The guard fires before the first write: stock untouched, no credit note.
    expect(await stockOf('p1')).toBe(before);
    expect(await returnCount()).toBe(0);
  });

  it('a product that was never on the bill is refused', async () => {
    await insertSale({
      id: 's_notin',
      receiptNo: 'R3',
      subtotal: 85,
      total: 85,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 1, price: 85 }],
    });

    const res = await post(
      credit('s_notin', [
        { productId: 'p2', name: 'Spark Plug', qty: 1, price: '120.00' },
      ]),
    );
    expect(res.status).toBe(409);
    expect(res.body.error.message).toBe(
      'คืนเกินจำนวนที่ขาย:\nSpark Plug: ไม่อยู่ในบิลนี้',
    );
    expect(await returnCount()).toBe(0);
  });

  it('a partial return restores stock and reverses the customer proportionally', async () => {
    // 4 oil filters @85 = 340, no discount, pointsGranted = floor(340/10) = 34.
    await seedCustomer(admin, TENANT, {
      id: 'c1',
      code: 'C001',
      name: 'Somchai Jaidee',
      points: 450,
      totalSpend: 4500,
    });
    await insertSale({
      id: 's_partial',
      receiptNo: 'R4',
      subtotal: 340,
      total: 340,
      customerId: 'c1',
      pointsGranted: 34,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 4, price: 85 }],
    });
    const stockBefore = await stockOf('p1');

    // Refund 1 of 4 → 85. ratio = 85/340 = 0.25; floor(34 × 0.25) = 8.
    const res = await post(
      credit('s_partial', [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
      ]),
    );

    expect(res.status).toBe(201);
    expect(res.body.data.refundSubtotal).toBe('85.00');
    expect(res.body.data.refundDiscount).toBe('0.00');
    expect(res.body.data.refundTotal).toBe('85.00');
    expect(res.body.data.cnNo).toMatch(/^CN07-\d{4}-\d{2}-0001$/);
    expect(res.body.data.receiptNo).toBe('R4');
    expect(res.body.data.saleVoided).toBe(false);
    expect(res.body.data.products).toEqual([{ id: 'p1', stock: stockBefore + 1 }]);
    expect(res.body.data.customerAfter).toEqual({
      id: 'c1',
      points: 442,
      totalSpend: '4415.00',
    });

    expect(await stockOf('p1')).toBe(stockBefore + 1);
    const cust = await customerRow('c1');
    expect(Number(cust.total_spend)).toBe(4500 - 85);
    expect(cust.points).toBe(450 - 8);
    expect((await saleRow('s_partial')).voided).toBe(false);

    // One ledger row per product, keyed on the credit note, not the bill.
    const movements = await admin.query(
      `SELECT product_id, delta, type, stock_after, ref_id FROM movements
        WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    expect(movements).toEqual([
      {
        product_id: 'p1',
        delta: 1,
        type: 'return',
        stock_after: stockBefore + 1,
        ref_id: res.body.data.id,
      },
    ]);
  });

  it('two partial returns summing to the whole bill void it; a third is refused', async () => {
    await insertSale({
      id: 's_full',
      receiptNo: 'R5',
      subtotal: 240,
      total: 240,
      items: [
        { productId: 'p1', name: 'Oil Filter', qty: 2, price: 85 },
        { productId: 'p2', name: 'Spark Plug', qty: 1, price: 70 },
      ],
    });

    const first = await post(
      credit('s_full', [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
      ]),
    );
    expect(first.status).toBe(201);
    expect(first.body.data.saleVoided).toBe(false);
    expect((await saleRow('s_full')).voided).toBe(false);

    const second = await post(
      credit('s_full', [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
        { productId: 'p2', name: 'Spark Plug', qty: 1, price: '70.00' },
      ]),
    );
    expect(second.status).toBe(201);
    expect(second.body.data.saleVoided).toBe(true);
    const voided = await saleRow('s_full');
    expect(voided.voided).toBe(true);
    expect(voided.voided_at).not.toBeNull();

    const third = await post(
      credit('s_full', [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
      ]),
    );
    expect(third.status).toBe(409);
    expect(third.body.error.code).toBe('SALE_VOIDED');
    expect(await returnCount()).toBe(2);
  });

  it('credit_balance moves only on หักจากเครดิต; a cash refund leaves the tab alone', async () => {
    await seedMechanic(admin, TENANT, {
      id: 'm1',
      code: 'M001',
      name: 'Lung Manop',
      creditLimit: 20000,
      creditBalance: 500,
      totalSales: 1000,
      totalMarkup: 200,
    });
    await insertSale({
      id: 's_credit',
      receiptNo: 'R6',
      subtotal: 200,
      total: 200,
      paymentMethod: 'เครดิตช่าง',
      mechanicId: 'm1',
      mechanicName: 'Lung Manop',
      mechanicDelta: 50,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 1, price: 200 }],
    });

    const cash = await post(
      credit(
        's_credit',
        [{ productId: 'p1', name: 'Oil Filter', qty: 1, price: '200.00' }],
        'เงินสด',
      ),
    );
    expect(cash.status).toBe(201);
    expect(cash.body.data.mechanicCreditBalanceAfter).toBe('500.00');

    let mech = await mechanicRow('m1');
    expect(Number(mech.credit_balance)).toBe(500);
    expect(Number(mech.total_sales)).toBe(800);
    // ratio = 200/200 = 1, so the whole +50 markup comes back off.
    expect(Number(mech.total_markup)).toBe(150);

    await insertSale({
      id: 's_credit2',
      receiptNo: 'R7',
      subtotal: 300,
      total: 300,
      paymentMethod: 'เครดิตช่าง',
      mechanicId: 'm1',
      mechanicName: 'Lung Manop',
      mechanicDelta: 0,
      items: [{ productId: 'p2', name: 'Spark Plug', qty: 1, price: 300 }],
    });
    const deduct = await post(
      credit(
        's_credit2',
        [{ productId: 'p2', name: 'Spark Plug', qty: 1, price: '300.00' }],
        'หักจากเครดิต',
      ),
    );
    expect(deduct.status).toBe(201);
    expect(deduct.body.data.mechanicCreditBalanceAfter).toBe('200.00');

    mech = await mechanicRow('m1');
    expect(Number(mech.credit_balance)).toBe(500 - 300);
    // 🔴 decision #11: the server reads `total_credit` as the discount-base fallback
    // and never writes it.
    expect(Number(mech.total_credit)).toBe(0);
  });

  it('the discount on the bill comes back in proportion', async () => {
    // 4 × 85 = 340 less a 40 discount = 300. Refunding one unit refunds 85 less
    // round2(85 × 40/340) = 10.00 → 75.00.
    await insertSale({
      id: 's_disc',
      receiptNo: 'R9',
      subtotal: 340,
      discount: 40,
      total: 300,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 4, price: 85 }],
    });

    const res = await post(
      credit('s_disc', [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
      ]),
    );
    expect(res.status).toBe(201);
    expect(res.body.data.refundSubtotal).toBe('85.00');
    expect(res.body.data.refundDiscount).toBe('10.00');
    expect(res.body.data.refundTotal).toBe('75.00');
  });

  it('lists credit notes newest first, and filters by bill', async () => {
    await insertSale({
      id: 's_order',
      receiptNo: 'R8',
      subtotal: 170,
      total: 170,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 2, price: 85 }],
    });
    const line = [
      { productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
    ];
    const r1 = await post(credit('s_order', line));
    const r2 = await post(credit('s_order', line));
    expect(r2.status).toBe(201);

    const all = await listReturns();
    expect(all.status).toBe(200);
    expect(all.body.data.map((r: { id: string }) => r.id)).toEqual([
      r2.body.data.id,
      r1.body.data.id,
    ]);
    expect(all.body.meta.total).toBe(2);
    expect(all.body.data[0].items).toEqual([
      {
        lineNo: 1,
        productId: 'p1',
        name: 'Oil Filter',
        qty: 1,
        price: '85.00',
        originalQty: null,
        costAtSale: null,
      },
    ]);

    const none = await listReturns('?saleId=s_nothing');
    expect(none.body.data).toEqual([]);
    expect(none.body.meta.total).toBe(0);
  });

  it('replays a repeated Idempotency-Key without crediting twice', async () => {
    await insertSale({
      id: 's_idem',
      receiptNo: 'R10',
      subtotal: 170,
      total: 170,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 2, price: 85 }],
    });
    const before = await stockOf('p1');
    const body = credit('s_idem', [
      { productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
    ]);

    const first = await post(body, { key: 'cn-retry' });
    const replay = await post(body, { key: 'cn-retry' });

    expect(first.status).toBe(201);
    expect(replay.status).toBe(201);
    expect(replay.body.data.id).toBe(first.body.data.id);
    expect(replay.body.data.cnNo).toBe(first.body.data.cnNo);
    expect(await returnCount()).toBe(1);
    expect(await stockOf('p1')).toBe(before + 1);
  });

  it('a backoffice device may not credit goods back', async () => {
    await insertSale({
      id: 's_role',
      receiptNo: 'R11',
      subtotal: 85,
      total: 85,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 1, price: 85 }],
    });

    const res = await post(
      credit('s_role', [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
      ]),
      { token: backofficeToken },
    );
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');
    expect(await returnCount()).toBe(0);
  });

  it('a negative line price is a 400', async () => {
    await insertSale({
      id: 's_neg',
      receiptNo: 'R12',
      subtotal: 85,
      total: 85,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 1, price: 85 }],
    });

    const res = await post(
      credit('s_neg', [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '-85.00' },
      ]),
    );
    expect(res.status).toBe(400);
    expect(res.body.error.message).toBe('items[0].price must not be negative');
    expect(await returnCount()).toBe(0);
  });

  it('carries cost_at_sale from the parent sale line, never the catalogue cost', async () => {
    // The bill sold at cost 50; the catalogue has since been repriced to 99.
    await insertSale({
      id: 's_cost',
      receiptNo: 'R13',
      subtotal: 170,
      total: 170,
      items: [
        { productId: 'p1', name: 'Oil Filter', qty: 2, price: 85, costAtSale: 50 },
      ],
    });
    await admin.query(
      `UPDATE products SET cost = 99 WHERE tenant_id = $1::uuid AND id = 'p1'`,
      [TENANT],
    );

    const res = await post(
      credit('s_cost', [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
      ]),
    );
    expect(res.status).toBe(201);
    expect(res.body.data.items[0].costAtSale).toBe('50.00');

    const rows = await admin.query(
      `SELECT cost_at_sale FROM return_items
        WHERE tenant_id = $1::uuid AND return_id = $2`,
      [TENANT, res.body.data.id],
    );
    expect(Number(rows[0].cost_at_sale)).toBe(50);
  });

  it("stamps the device's open drawer on the credit note", async () => {
    const shift = await request(app.getHttpServer())
      .post('/api/v1/shifts/open')
      .set('Authorization', `Bearer ${posToken}`)
      .set('Idempotency-Key', `k-${Math.random()}`)
      .send({ startingCash: '2000.00' });
    expect(shift.status).toBe(200);

    await insertSale({
      id: 's_shift',
      receiptNo: 'R14',
      subtotal: 85,
      total: 85,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 1, price: 85 }],
    });
    const res = await post(
      credit('s_shift', [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
      ]),
    );

    expect(res.status).toBe(201);
    expect(res.body.data.shiftId).toBe(shift.body.data.id);
    const rows = await admin.query(
      `SELECT shift_id FROM returns WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, res.body.data.id],
    );
    expect(rows[0].shift_id).toBe(shift.body.data.id);
  });
});
