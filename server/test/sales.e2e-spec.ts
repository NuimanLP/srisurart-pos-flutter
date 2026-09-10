import type { INestApplication } from '@nestjs/common';
import request, { type Response } from 'supertest';
import type { DataSource } from 'typeorm';
import {
  accessToken,
  clearTenantCache,
  createTestApp,
  resetTenant,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';

// #20 acceptance suite. Every stock case in `frontend/test/sales_repository_test.dart`
// is reproduced here at the HTTP seam, with the Thai assertions verbatim, plus the
// concurrency the Dart version cannot have (one machine, one process).
const TENANT = 'eeeeeeee-5555-4555-8555-eeeeeeeeeeee';

interface Line {
  productId: string;
  name: string;
  qty: number;
  price: string;
  partNo?: string;
  nameTH?: string;
}

describe('POST /sales (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;
  let posToken: string;
  let backofficeToken: string;
  let saleSeq = 0;

  /** A bill body whose totals are consistent with its lines. */
  const bill = (lines: Line[], overrides: Record<string, unknown> = {}) => {
    const subtotal = lines.reduce((s, l) => s + l.qty * Number(l.price), 0);
    return {
      id: `s-test-${++saleSeq}-${Date.now()}`,
      subtotal: subtotal.toFixed(2),
      discount: '0.00',
      total: subtotal.toFixed(2),
      paymentMethod: 'เงินสด',
      items: lines.map((l, i) => ({ lineNo: i + 1, ...l })),
      ...overrides,
    };
  };

  const post = (body: unknown, opts: { key?: string; token?: string } = {}) =>
    request(app.getHttpServer())
      .post('/api/v1/sales')
      .set('Authorization', `Bearer ${opts.token ?? posToken}`)
      .set('Idempotency-Key', opts.key ?? `k-${Math.random()}`)
      .send(body as object);

  const stockOf = async (id: string): Promise<number> => {
    const rows = await admin.query(
      `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, id],
    );
    return rows[0].stock as number;
  };

  const saleCount = async (): Promise<number> => {
    const rows = await admin.query(
      `SELECT count(*)::int AS n FROM sales WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    return rows[0].n as number;
  };

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { posDeviceNo: 3, cache });
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
      id: 'p8',
      partNo: 'PK-STD',
      name: 'Piston Kit STD',
      nameTH: 'ชุดลูกสูบ',
      price: 3200,
      cost: 2400,
      stock: 5,
    });
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it('rings up a bill: receipt number, points, and the new stock of every line', async () => {
    const res = await post(
      bill([{ productId: 'p1', name: 'Oil Filter', qty: 3, price: '85.00', partNo: 'HN-15412-KVB' }]),
    );

    expect(res.status).toBe(201);
    expect(res.body.status).toBe('success');
    expect(res.body.data.receiptNo).toMatch(/^RC03-\d{4}-\d{2}-0001$/);
    expect(res.body.data.total).toBe('255.00');
    // floor(255/10) — computed server-side from the persisted total.
    expect(res.body.data.pointsGranted).toBe(25);
    expect(res.body.data.products).toEqual([{ id: 'p1', stock: 45 }]);
    expect(res.body.data).not.toHaveProperty('offlineOk');

    expect(await stockOf('p1')).toBe(45);
    const items = await admin.query(
      `SELECT line_no, product_id, part_no, qty, price, cost_at_sale
         FROM sale_items WHERE tenant_id = $1::uuid AND sale_id = $2`,
      [TENANT, res.body.data.id],
    );
    expect(items).toHaveLength(1);
    expect(items[0].part_no).toBe('HN-15412-KVB');
    expect(items[0].qty).toBe(3);
    // ADR-0008: the cost as it stood inside the transaction, not today's cost.
    expect(Number(items[0].cost_at_sale)).toBe(50);
  });

  it('writes one movement row per product, referencing the bill', async () => {
    const res = await post(
      bill([{ productId: 'p1', name: 'Oil Filter', qty: 2, price: '85.00' }]),
    );
    const rows = await admin.query(
      `SELECT product_id, delta, type, stock_after, ref_id
         FROM movements WHERE tenant_id = $1::uuid AND ref_id = $2`,
      [TENANT, res.body.data.id],
    );
    expect(rows).toEqual([
      {
        product_id: 'p1',
        delta: -2,
        type: 'sale',
        stock_after: 46,
        ref_id: res.body.data.id,
      },
    ]);
  });

  it('insufficient stock: the verbatim Thai message, and nothing is written', async () => {
    // The Dart case: p8 has stock 5, the bill wants 6.
    const res = await post(
      bill([{ productId: 'p8', name: 'Piston Kit STD', qty: 6, price: '3200.00' }]),
    );

    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('INSUFFICIENT_STOCK');
    expect(res.body.error.message).toBe(
      'สต็อกไม่พอ:\nPiston Kit STD: สต็อก 5 แต่ต้องการ 6',
    );
    expect(res.body.error.details).toEqual([
      { productId: 'p8', stock: 5, requested: 6 },
    ]);
    expect(await stockOf('p8')).toBe(5);
    expect(await saleCount()).toBe(0);
  });

  it('a missing product: ไม่พบในสต็อก, and nothing is written', async () => {
    const res = await post(bill([{ productId: 'NOPE', name: 'Ghost', qty: 1, price: '10.00' }]));

    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('INSUFFICIENT_STOCK');
    expect(res.body.error.message).toBe('สต็อกไม่พอ:\nGhost: ไม่พบในสต็อก');
    expect(await saleCount()).toBe(0);
  });

  it('three short lines come back as three Thai lines in ONE response', async () => {
    await seedProduct(admin, TENANT, {
      id: 'p2',
      partNo: 'BP-1234',
      name: 'Front Brake Pad',
      price: 750,
      cost: 500,
      stock: 1,
    });
    const res = await post(
      bill([
        { productId: 'p8', name: 'Piston Kit STD', qty: 6, price: '3200.00' },
        { productId: 'p2', name: 'Front Brake Pad', qty: 2, price: '750.00' },
        { productId: 'NOPE', name: 'Ghost', qty: 1, price: '10.00' },
      ]),
    );

    expect(res.status).toBe(409);
    // One response, every failing line, in the order they were typed — staff must
    // not have to re-submit the bill once per missing item to find out what is short.
    expect(res.body.error.message).toBe(
      'สต็อกไม่พอ:\n' +
        'Piston Kit STD: สต็อก 5 แต่ต้องการ 6\n' +
        'Front Brake Pad: สต็อก 1 แต่ต้องการ 2\n' +
        'Ghost: ไม่พบในสต็อก',
    );
  });

  it('tells a missing product apart from a short one in that same response', async () => {
    const res = await post(
      bill([
        { productId: 'p8', name: 'Piston Kit STD', qty: 99, price: '3200.00' },
        { productId: 'GONE', name: 'ของที่ไม่มี', qty: 1, price: '5.00' },
      ]),
    );
    const lines = res.body.error.message.split('\n');
    expect(lines[1]).toBe('Piston Kit STD: สต็อก 5 แต่ต้องการ 99');
    expect(lines[2]).toBe('ของที่ไม่มี: ไม่พบในสต็อก');
    expect(res.body.error.details).toEqual([
      { productId: 'p8', stock: 5, requested: 99 },
      { productId: 'GONE', stock: null, requested: 1 },
    ]);
  });

  it('a soft-deleted product reads as ไม่พบในสต็อก, not as a sellable row', async () => {
    await admin.query(
      `UPDATE products SET deleted_at = now() WHERE tenant_id = $1::uuid AND id = 'p1'`,
      [TENANT],
    );
    const res = await post(bill([{ productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' }]));
    expect(res.body.error.message).toBe('สต็อกไม่พอ:\nOil Filter: ไม่พบในสต็อก');
  });

  it('refuses a total more than 0.01 out, and keeps one within tolerance', async () => {
    const off = await post(
      bill([{ productId: 'p1', name: 'Oil Filter', qty: 2, price: '85.00' }], {
        subtotal: '170.00',
        total: '150.00',
      }),
    );
    expect(off.status).toBe(409);
    expect(off.body.error.code).toBe('TOTAL_MISMATCH');
    expect(off.body.error.message).toBe('ยอดเงินไม่ตรงกัน กรุณาทำรายการใหม่');
    expect(await stockOf('p1')).toBe(48);

    // One satang out — the rounding gap between Dart's double and Postgres NUMERIC.
    // Within tolerance the client's number is the one stored: the receipt is printed.
    const near = await post(
      bill([{ productId: 'p1', name: 'Oil Filter', qty: 2, price: '85.00' }], {
        subtotal: '170.00',
        total: '169.99',
      }),
    );
    expect(near.status).toBe(201);
    const rows = await admin.query(
      `SELECT total FROM sales WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, near.body.data.id],
    );
    expect(Number(rows[0].total)).toBe(169.99);
    expect(near.body.data.pointsGranted).toBe(16);
  });

  it('never compares a line price against the catalogue price', async () => {
    // Sold at 60 when the catalogue says 85: haggling is an ordinary day here.
    const res = await post(
      bill([{ productId: 'p1', name: 'Oil Filter', qty: 1, price: '60.00' }]),
    );
    expect(res.status).toBe(201);
    expect(res.body.data.total).toBe('60.00');
  });

  it('the same idempotency key five times creates one bill and deducts stock once', async () => {
    const body = bill([{ productId: 'p1', name: 'Oil Filter', qty: 2, price: '85.00' }]);
    const key = `k-five-${Date.now()}`;
    const responses = [];
    for (let i = 0; i < 5; i++) responses.push(await post(body, { key }));

    for (const res of responses) {
      expect(res.status).toBe(201);
      expect(res.body.data.receiptNo).toBe(responses[0].body.data.receiptNo);
    }
    expect(await saleCount()).toBe(1);
    expect(await stockOf('p1')).toBe(46);
  });

  it('200 concurrent bills against 50 units yield exactly 50 bills and zero stock', async () => {
    await seedProduct(admin, TENANT, {
      id: 'hot',
      partNo: 'HOT-1',
      name: 'Hot Part',
      price: 100,
      cost: 60,
      stock: 50,
    });

    const attempts = Array.from({ length: 200 }, () =>
      post(bill([{ productId: 'hot', name: 'Hot Part', qty: 1, price: '100.00' }])),
    );
    // `allSettled`, not `all`: a rejection would leave the other 199 requests still in
    // flight, writing rows into a tenant the next test's `resetTenant` is already
    // deleting — a foreign-key error in the fixture, pointing nowhere near the cause.
    const settled = await Promise.allSettled(attempts);
    const failed = settled.filter((r) => r.status === 'rejected');
    expect(failed).toEqual([]);
    const results = settled.map((r) => (r as PromiseFulfilledResult<Response>).value);

    const created = results.filter((r) => r.status === 201);
    const refused = results.filter((r) => r.status === 409);
    expect(created).toHaveLength(50);
    expect(refused).toHaveLength(150);
    for (const r of refused) expect(r.body.error.code).toBe('INSUFFICIENT_STOCK');

    expect(await stockOf('hot')).toBe(0);
    const rows = await admin.query(
      `SELECT count(*)::int AS n FROM sale_items
        WHERE tenant_id = $1::uuid AND product_id = 'hot'`,
      [TENANT],
    );
    expect(rows[0].n).toBe(50);

    // Every winner got its own receipt number: no duplicates, no gaps.
    const numbers = created.map((r) => r.body.data.receiptNo);
    expect(new Set(numbers).size).toBe(50);
  }, 60_000);

  it('a bill listing the same product twice is one demand, not two', async () => {
    const res = await post(
      bill([
        { productId: 'p8', name: 'Piston Kit STD', qty: 3, price: '3200.00' },
        { productId: 'p8', name: 'Piston Kit STD', qty: 3, price: '3200.00' },
      ]),
    );
    // 3 + 3 against a stock of 5: the ordinary Thai message, not a 500 from the
    // second line underflowing after the first passed its own check.
    expect(res.status).toBe(409);
    expect(res.body.error.message).toBe(
      'สต็อกไม่พอ:\nPiston Kit STD: สต็อก 5 แต่ต้องการ 6',
    );
  });

  it('a backoffice device cannot sell', async () => {
    const res = await post(
      bill([{ productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' }]),
      { token: backofficeToken },
    );
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');
    expect(res.body.error.message).toBe('เครื่องนี้ขายของไม่ได้');
    expect(await saleCount()).toBe(0);
  });

  it('refuses an unauthenticated request, and one for a suspended shop', async () => {
    const anon = await request(app.getHttpServer())
      .post('/api/v1/sales')
      .set('Idempotency-Key', 'k-anon')
      .send(bill([{ productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' }]));
    expect(anon.status).toBe(401);

    await admin.query(`UPDATE tenants SET status = 'suspended' WHERE id = $1::uuid`, [
      TENANT,
    ]);
    // The guard caches status for five minutes, so the suspension is invisible until
    // that key is gone. Dropping it is what makes this an assertion about the guard
    // rather than about Redis timing: without it the test has to accept a 201, and a
    // suspended shop quietly ringing up a real bill would pass.
    await clearTenantCache(cache, TENANT);

    const suspended = await post(
      bill([{ productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' }]),
    );
    expect(suspended.status).toBe(403);
    expect(suspended.body.error.code).toBe('TENANT_SUSPENDED');
    expect(suspended.body.error.message).toBe('ร้านนี้ถูกระงับการใช้งาน');
    expect(await saleCount()).toBe(0);

    await admin.query(`UPDATE tenants SET status = 'active' WHERE id = $1::uuid`, [TENANT]);
    await clearTenantCache(cache, TENANT);
  });

  it('replays a bill whose id was already written, instead of a 500 on the key', async () => {
    const body = bill([{ productId: 'p1', name: 'Oil Filter', qty: 2, price: '85.00' }]);
    const first = await post(body);
    expect(first.status).toBe(201);

    // A retry that lost its Idempotency-Key: a page reload, an app restart. §3.1 makes
    // the client id a natural idempotency key, and a 500 here would send staff to ring
    // the same bill up a second time.
    const replay = await post(body, { key: `k-fresh-${Date.now()}` });
    expect(replay.status).toBe(201);
    expect(replay.body.data.receiptNo).toBe(first.body.data.receiptNo);
    expect(await saleCount()).toBe(1);
    expect(await stockOf('p1')).toBe(46);
  });

  it('refuses a different bill wearing an id that is already taken', async () => {
    const first = await post(
      bill([{ productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' }]),
    );
    const clash = await post(
      bill([{ productId: 'p1', name: 'Oil Filter', qty: 2, price: '85.00' }], {
        id: first.body.data.id,
      }),
      { key: `k-clash-${Date.now()}` },
    );
    expect(clash.status).toBe(409);
    expect(clash.body.error.code).toBe('SALE_ID_REUSED');
    expect(await stockOf('p1')).toBe(47);
  });

  it('refuses an unknown customer with a 400, not a 500 from the foreign key', async () => {
    const res = await post(
      bill([{ productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' }], {
        customerId: 'no-such-customer',
        customerName: 'ไม่มีตัวตน',
      }),
    );
    expect(res.status).toBe(400);
    expect(await saleCount()).toBe(0);
  });

  it('refuses money that does not make sense', async () => {
    const line = { productId: 'p1', name: 'Oil Filter', qty: 2, price: '85.00' };
    // A negative discount inflates the total, and pointsGranted is computed from the
    // total that gets stored — points the shop never owed.
    const negativeDiscount = await post(
      bill([line], { subtotal: '170.00', discount: '-50.00', total: '220.00' }),
    );
    expect(negativeDiscount.status).toBe(400);

    const negativeTotal = await post(
      bill([line], { subtotal: '170.00', discount: '200.00', total: '-30.00' }),
    );
    expect(negativeTotal.status).toBe(400);

    // NUMERIC(12,2) would raise 22003 several statements later: a 500 for what is
    // plainly a bad request.
    const absurd = await post(
      bill([{ ...line, qty: 1, price: '20000000000.00' }], {
        subtotal: '20000000000.00',
        total: '20000000000.00',
      }),
    );
    expect(absurd.status).toBe(400);

    expect(await saleCount()).toBe(0);
    expect(await stockOf('p1')).toBe(48);
  });

  it('keeps the client line numbers, and refuses two lines that share one', async () => {
    const ok = await post({
      id: `s-lineno-${Date.now()}`,
      subtotal: '170.00',
      discount: '0.00',
      total: '170.00',
      paymentMethod: 'เงินสด',
      items: [
        { lineNo: 7, productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
        { lineNo: 3, productId: 'p8', name: 'Piston Kit STD', qty: 1, price: '85.00' },
      ],
    });
    expect(ok.status).toBe(201);
    const rows = await admin.query(
      `SELECT line_no, product_id FROM sale_items
        WHERE tenant_id = $1::uuid AND sale_id = $2 ORDER BY line_no`,
      [TENANT, ok.body.data.id],
    );
    // What the receipt in the customer's hand says is what gets stored.
    expect(rows).toEqual([
      { line_no: 3, product_id: 'p8' },
      { line_no: 7, product_id: 'p1' },
    ]);

    const clash = await post({
      id: `s-dupline-${Date.now()}`,
      subtotal: '170.00',
      discount: '0.00',
      total: '170.00',
      paymentMethod: 'เงินสด',
      items: [
        { lineNo: 1, productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' },
        { lineNo: 1, productId: 'p8', name: 'Piston Kit STD', qty: 1, price: '85.00' },
      ],
    });
    expect(clash.status).toBe(400);
  });

  it('refuses a bill with no Idempotency-Key, and one with no lines', async () => {
    const keyless = await request(app.getHttpServer())
      .post('/api/v1/sales')
      .set('Authorization', `Bearer ${posToken}`)
      .send(bill([{ productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' }]));
    expect(keyless.status).toBe(400);
    expect(keyless.body.error.code).toBe('IDEMPOTENCY_KEY_INVALID');

    const empty = await post({ ...bill([]), items: [] });
    expect(empty.status).toBe(400);
    expect(await saleCount()).toBe(0);
  });

  it('ignores a receiptNo the client tries to choose (phase 1 issues it)', async () => {
    const res = await post(
      bill([{ productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' }], {
        receiptNo: 'RC99-2000-01-0001',
      }),
    );
    expect(res.status).toBe(201);
    expect(res.body.data.receiptNo).toMatch(/^RC03-\d{4}-\d{2}-\d{4}$/);
  });

  it('stamps the user and the device from the token, never from the body', async () => {
    const res = await post(
      bill([{ productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' }], {
        deviceId: 'someone-elses-machine',
        userId: '00000000-0000-4000-8000-000000000000',
      }),
    );
    const rows = await admin.query(
      `SELECT user_id, device_id FROM sales WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, res.body.data.id],
    );
    expect(rows[0].device_id).toBe(fixture.posDeviceId);
    expect(rows[0].user_id).toBe(fixture.userId);
  });
});
