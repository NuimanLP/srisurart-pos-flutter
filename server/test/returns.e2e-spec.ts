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

  it('a credit note with no drawer open carries no shift_id', async () => {
    await insertSale({
      id: 's_noshift',
      receiptNo: 'R24',
      subtotal: 85,
      total: 85,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 1, price: 85 }],
    });
    const res = await post(
      credit('s_noshift', [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
      ]),
    );

    expect(res.status).toBe(201);
    expect(res.body.data.shiftId).toBeNull();
    const rows = await admin.query(
      `SELECT shift_id FROM returns WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, res.body.data.id],
    );
    expect(rows[0].shift_id).toBeNull();
  });

  // ── The fix round: the server, not the client, decides what a refund is worth ──

  it('refuses a line priced at anything the bill did not charge', async () => {
    // The hole this closes: the refund used to be Σ(qty × the *client's* price), so a
    // `pos` token could credit 999,999 baht against a bill that sold the part for 85.
    // `GREATEST(0, …)` then absorbed it in silence — the tab floored at 0 and nothing
    // was raised — which is why the mechanic's balance is asserted here too.
    await seedMechanic(admin, TENANT, {
      id: 'm9',
      code: 'M009',
      name: 'Lung Manop',
      creditLimit: 20000,
      creditBalance: 5000,
      totalSales: 1000,
    });
    await insertSale({
      id: 's_price',
      receiptNo: 'R15',
      subtotal: 85,
      total: 85,
      paymentMethod: 'เครดิตช่าง',
      mechanicId: 'm9',
      mechanicName: 'Lung Manop',
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 1, price: 85 }],
    });
    const before = await stockOf('p1');

    const res = await post(
      credit(
        's_price',
        [{ productId: 'p1', name: 'Oil Filter', qty: 1, price: '999999.00' }],
        'หักจากเครดิต',
      ),
    );

    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('RETURN_PRICE_MISMATCH');
    expect(res.body.error.details).toEqual({
      lines: [{ productId: 'p1', price: '999999.00', soldAt: ['85.00'] }],
    });
    expect(await returnCount()).toBe(0);
    expect(await stockOf('p1')).toBe(before);
    expect(Number((await mechanicRow('m9')).credit_balance)).toBe(5000);
  });

  it('refunds one part on two lines at each price the bill charged', async () => {
    // 85 + 70 = 155. Collapsing by product alone kept the first line's price and
    // multiplied it by the whole quantity, so this refunded 170 and stored a single
    // 85.00 row that matched neither the bill nor the request.
    await insertSale({
      id: 's_twoprice',
      receiptNo: 'R16',
      subtotal: 155,
      total: 155,
      items: [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: 85 },
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: 70 },
      ],
    });
    const before = await stockOf('p1');

    const res = await post(
      credit('s_twoprice', [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '70.00' },
      ]),
    );

    expect(res.status).toBe(201);
    expect(res.body.data.refundSubtotal).toBe('155.00');
    expect(res.body.data.refundTotal).toBe('155.00');
    expect(
      res.body.data.items.map((i: { price: string; qty: number }) => [
        i.price,
        i.qty,
      ]),
    ).toEqual([
      ['85.00', 1],
      ['70.00', 1],
    ]);
    // Every unit came back, so the bill auto-voids.
    expect(res.body.data.saleVoided).toBe(true);

    // One ledger row for the product, not one per price — `uq_movements_ref` is
    // unique on (tenant_id, type, ref_id, product_id) and a second would be a 500.
    const movements = await admin.query(
      `SELECT product_id, delta FROM movements WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    expect(movements).toEqual([{ product_id: 'p1', delta: 2 }]);
    expect(await stockOf('p1')).toBe(before + 2);
  });

  it('bounds the quantity per price, not per product', async () => {
    await insertSale({
      id: 's_bucket',
      receiptNo: 'R17',
      subtotal: 155,
      total: 155,
      items: [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: 85 },
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: 70 },
      ],
    });

    // Two units *at 85* when the bill sold one at 85 and one at 70: the per-product
    // guard saw two units left and let this refund 170 for goods worth 155.
    const res = await post(
      credit('s_bucket', [
        { productId: 'p1', name: 'Oil Filter', qty: 2, price: '85.00' },
      ]),
    );
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('OVER_REFUND');
    expect(res.body.error.message).toBe(
      'คืนเกินจำนวนที่ขาย:\nOil Filter: คืนได้อีก 1 แต่ขอคืน 2',
    );
    expect(await returnCount()).toBe(0);
  });

  it('restores a soft-deleted product, exactly as the void does', async () => {
    await insertSale({
      id: 's_deleted',
      receiptNo: 'R18',
      subtotal: 85,
      total: 85,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 1, price: 85 }],
    });
    const before = await stockOf('p1');
    // A product that has ever sold cannot be hard-deleted — `movements` references it
    // with no cascade — so this is the only deletion the returns path can ever meet.
    await admin.query(
      `UPDATE products SET deleted_at = now() WHERE tenant_id = $1::uuid AND id = 'p1'`,
      [TENANT],
    );

    const res = await post(
      credit('s_deleted', [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
      ]),
    );

    expect(res.status).toBe(201);
    expect(res.body.data.products).toEqual([{ id: 'p1', stock: before + 1 }]);
    expect(await stockOf('p1')).toBe(before + 1);
    const movements = await admin.query(
      `SELECT product_id, delta, type FROM movements WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    expect(movements).toEqual([{ product_id: 'p1', delta: 1, type: 'return' }]);
  });

  it('refuses หักจากเครดิต on a bill with no mechanic', async () => {
    await insertSale({
      id: 's_nomech',
      receiptNo: 'R19',
      subtotal: 85,
      total: 85,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 1, price: 85 }],
    });

    const res = await post(
      credit(
        's_nomech',
        [{ productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' }],
        'หักจากเครดิต',
      ),
    );

    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('REFUND_METHOD_NOT_ALLOWED');
    // Otherwise the credit note says it was deducted from a tab that does not exist,
    // and the closing report does not count it as cash either.
    expect(await returnCount()).toBe(0);
  });

  it('assigns the legacy total_credit as the discount base when total_discount is 0', async () => {
    // 🔴 decision #11: `total_credit` is the JS app's alias of `total_discount`, read
    // here as the old app's own `(totalDiscount || totalCredit)` fallback and never
    // written. `returns_repository.dart:168-176` *assigns* that base, so an untouched
    // mechanic's `total_discount` jumps to it on the first unrelated return. That is
    // the reference behaviour — pinned so nobody "fixes" it by accident.
    await seedMechanic(admin, TENANT, {
      id: 'm8',
      code: 'M008',
      name: 'Legacy Import',
      creditLimit: 20000,
      creditBalance: 0,
      totalSales: 1000,
      totalCredit: 5000,
      totalDiscount: 0,
    });
    await insertSale({
      id: 's_legacy',
      receiptNo: 'R20',
      subtotal: 200,
      total: 200,
      mechanicId: 'm8',
      mechanicName: 'Legacy Import',
      mechanicDelta: 0,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 1, price: 200 }],
    });

    const res = await post(
      credit('s_legacy', [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '200.00' },
      ]),
    );
    expect(res.status).toBe(201);

    const mech = await mechanicRow('m8');
    expect(Number(mech.total_discount)).toBe(5000);
    expect(Number(mech.total_credit)).toBe(5000);
    expect(Number(mech.total_sales)).toBe(800);
  });

  it('reverses a discount given to the mechanic in proportion', async () => {
    // A negative `mechanic_delta` is a discount: half the bill back takes half of it
    // off `total_discount`. The other mechanic bills here use +50 and 0, so this is
    // the only case that exercises `reverseCredit`.
    await seedMechanic(admin, TENANT, {
      id: 'm7',
      code: 'M007',
      name: 'Discounted',
      creditLimit: 20000,
      creditBalance: 0,
      totalSales: 1000,
      totalDiscount: 300,
    });
    await insertSale({
      id: 's_disc_mech',
      receiptNo: 'R21',
      subtotal: 200,
      total: 200,
      mechanicId: 'm7',
      mechanicName: 'Discounted',
      mechanicDelta: -60,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 2, price: 100 }],
    });

    const res = await post(
      credit('s_disc_mech', [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '100.00' },
      ]),
    );
    expect(res.status).toBe(201);

    // ratio = 100/200 → 30 of the 60 comes back off the assigned base of 300.
    const mech = await mechanicRow('m7');
    expect(Number(mech.total_discount)).toBe(270);
    expect(Number(mech.total_sales)).toBe(900);
    expect(Number(mech.credit_balance)).toBe(0);
  });

  it('the counter path: 409, a corrected body, the same Idempotency-Key', async () => {
    // Returns has a 409 the sale path does not — `OVER_REFUND` — and staff correct the
    // quantity and press the same button, so the client resends under the same key.
    // That only works because the claim rolls back with the refused request; pinned
    // here so a change to the claim's lifetime (tx.3) cannot make a corrected credit
    // note impossible to issue.
    await insertSale({
      id: 's_retry',
      receiptNo: 'R22',
      subtotal: 170,
      total: 170,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 2, price: 85 }],
    });
    const key = `cn-corrected-${Date.now()}`;

    const refused = await post(
      credit('s_retry', [
        { productId: 'p1', name: 'Oil Filter', qty: 5, price: '85.00' },
      ]),
      { key },
    );
    expect(refused.status).toBe(409);
    expect(refused.body.error.code).toBe('OVER_REFUND');

    const corrected = await post(
      credit('s_retry', [
        { productId: 'p1', name: 'Oil Filter', qty: 2, price: '85.00' },
      ]),
      { key },
    );
    expect(corrected.status).toBe(201);
    expect(corrected.body.data.refundTotal).toBe('170.00');
    expect(await returnCount()).toBe(1);
  });

  it('filters the history by date range, as 02_API_SCREENS §3.7 defines it', async () => {
    await insertSale({
      id: 's_dates',
      receiptNo: 'R23',
      subtotal: 170,
      total: 170,
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 2, price: 85 }],
    });
    const cn = await post(
      credit('s_dates', [
        { productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
      ]),
    );
    expect(cn.status).toBe(201);

    const soon = new Date(Date.now() + 60_000).toISOString();
    const earlier = new Date(Date.now() - 60_000).toISOString();

    const inRange = await listReturns(`?from=${earlier}&to=${soon}`);
    expect(inRange.body.data.map((r: { id: string }) => r.id)).toEqual([
      cn.body.data.id,
    ]);

    const past = await listReturns(`?from=${earlier}&to=${earlier}`);
    expect(past.body.data).toEqual([]);
    expect(past.body.meta.total).toBe(0);

    const bad = await listReturns('?from=not-a-date');
    expect(bad.status).toBe(400);
    expect(bad.body.error.message).toBe('from must be an ISO-8601 timestamp');
  });
});
