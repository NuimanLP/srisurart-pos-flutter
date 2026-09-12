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

// #21 acceptance suite: the customer and mechanic ledger effects of `POST /sales`,
// with the numbers from `frontend/test/sales_repository_test.dart` where it has them,
// plus the credit-limit override that only exists at the HTTP seam.
const TENANT = 'eeeeeeee-2121-4121-8121-eeeeeeeeeeee';

interface Line {
  productId: string;
  name: string;
  qty: number;
  price: string;
}

interface MechanicRow {
  credit_balance: string;
  total_sales: string;
  total_credit: string;
  total_discount: string;
  total_markup: string;
}

describe('POST /sales — ledger effects (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;
  let posToken: string;
  let saleSeq = 0;

  /** A bill body whose totals are consistent with its lines. */
  const bill = (lines: Line[], overrides: Record<string, unknown> = {}) => {
    const subtotal = lines.reduce((s, l) => s + l.qty * Number(l.price), 0);
    return {
      id: `s-ledger-${++saleSeq}-${Date.now()}`,
      subtotal: subtotal.toFixed(2),
      discount: '0.00',
      total: subtotal.toFixed(2),
      paymentMethod: 'เงินสด',
      items: lines.map((l, i) => ({ lineNo: i + 1, ...l })),
      ...overrides,
    };
  };

  const chain = (qty = 1): Line[] => [
    { productId: 'p3', name: 'Drive Chain #520', qty, price: '350.00' },
  ];

  const post = (body: unknown, key = `k-${Math.random()}`) =>
    request(app.getHttpServer())
      .post('/api/v1/sales')
      .set('Authorization', `Bearer ${posToken}`)
      .set('Idempotency-Key', key)
      .send(body as object);

  const mechanic = async (id: string): Promise<MechanicRow> => {
    const rows = await admin.query(
      `SELECT credit_balance, total_sales, total_credit, total_discount, total_markup
         FROM mechanics WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, id],
    );
    return rows[0] as MechanicRow;
  };

  const customer = async (id: string) => {
    const rows = await admin.query(
      `SELECT points, total_spend FROM customers WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, id],
    );
    return rows[0] as { points: number; total_spend: string };
  };

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

  const overrideAudits = () =>
    admin.query(
      `SELECT entity, entity_id, user_id, device_id, after FROM audit_log
        WHERE tenant_id = $1::uuid AND action = 'sale.credit_limit_override'`,
      [TENANT],
    ) as Promise<
      {
        entity: string;
        entity_id: string;
        user_id: string;
        device_id: string;
        after: Record<string, unknown>;
      }[]
    >;

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { posDeviceNo: 4, cache });
    posToken = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'cashier',
      deviceId: fixture.posDeviceId,
      deviceRole: 'pos',
    });
    await seedProduct(admin, TENANT, {
      id: 'p3',
      partNo: 'DC-520',
      name: 'Drive Chain #520',
      price: 350,
      cost: 200,
      stock: 20,
    });
    // The Dart fixture: c1 at 450 points / 4500 spend, m1 with an empty tab.
    await seedCustomer(admin, TENANT, {
      id: 'c1',
      code: 'C001',
      name: 'Somchai Jaidee',
      points: 450,
      totalSpend: 4500,
    });
    await seedMechanic(admin, TENANT, {
      id: 'm1',
      code: 'M001',
      name: 'Lung Manop',
      creditLimit: 5000,
      totalCredit: 120,
    });
    await seedMechanic(admin, TENANT, {
      id: 'm2',
      code: 'M002',
      name: 'Chang Tao',
      creditLimit: 3000,
    });
    // 800 on a 1000 limit: one 350 chain pushes it to 1150.
    await seedMechanic(admin, TENANT, {
      id: 'm3',
      code: 'M003',
      name: 'Tight Limit',
      creditLimit: 1000,
      creditBalance: 800,
    });
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it('customer sale: points += floor(total/10), total_spend += total', async () => {
    const res = await post(
      bill(
        [
          {
            productId: 'p3',
            name: 'Drive Chain #520',
            qty: 1,
            price: '120.00',
          },
        ],
        {
          customerId: 'c1',
          customerName: 'Somchai Jaidee',
        },
      ),
    );
    expect(res.status).toBe(201);
    expect(res.body.data.pointsGranted).toBe(12);
    expect(res.body.data.customerAfter).toEqual({
      id: 'c1',
      points: 462,
      totalSpend: '4620.00',
    });
    expect(res.body.data.mechanicCreditBalanceAfter).toBeNull();

    const c = await customer('c1');
    expect(c.points).toBe(462);
    expect(Number(c.total_spend)).toBe(4620);
  });

  it('mechanic credit sale with a discount: the tab, the sales and the discount move; total_credit does not', async () => {
    const res = await post(
      bill(chain(), {
        paymentMethod: 'เครดิตช่าง',
        mechanicId: 'm1',
        mechanicName: 'Lung Manop',
        mechanicDelta: '-50.00',
      }),
    );
    expect(res.status).toBe(201);
    expect(res.body.data.mechanicCreditBalanceAfter).toBe('350.00');
    expect(res.body.data.customerAfter).toBeNull();

    const m = await mechanic('m1');
    expect(Number(m.credit_balance)).toBe(350);
    expect(Number(m.total_sales)).toBe(350);
    expect(Number(m.total_discount)).toBe(50);
    expect(Number(m.total_markup)).toBe(0);
    // Decision #11: a legacy alias of `total_discount` from the JS app. The server
    // never writes it, so it is exactly what the fixture seeded.
    expect(Number(m.total_credit)).toBe(120);

    // #82: all four running totals come back, because the mechanics screen shows all
    // four and the client may not recompute a server-owned figure.
    expect(res.body.data.mechanicAfter).toEqual({
      id: 'm1',
      totalSales: '350.00',
      totalDiscount: '50.00',
      totalMarkup: '0.00',
      creditBalance: '350.00',
    });
    // 🔴 `total_credit` is 120 in the row above and must not be on the wire at all:
    // returning it would invite the client to patch a column nothing writes.
    expect(res.body.data.mechanicAfter).not.toHaveProperty('totalCredit');
    expect(JSON.stringify(res.body)).not.toContain('total_credit');
  });

  it('no mechanic on the bill: mechanicAfter is null, alongside the balance', async () => {
    const res = await post(bill(chain()));
    expect(res.status).toBe(201);
    expect(res.body.data.mechanicAfter).toBeNull();
    expect(res.body.data.mechanicCreditBalanceAfter).toBeNull();
  });

  it('a replayed bill answers the identical ledger body (#82)', async () => {
    const body = bill(chain(), {
      paymentMethod: 'เครดิตช่าง',
      customerId: 'c1',
      customerName: 'Somchai Jaidee',
      mechanicId: 'm1',
      mechanicName: 'Lung Manop',
      mechanicDelta: '-50.00',
    });
    const first = await post(body);
    expect(first.status).toBe(201);
    expect(first.body.data.mechanicAfter.totalSales).toBe('350.00');

    // The `existingSale` replay reads the mechanic and customer rows as they stand.
    // Nothing moved between the two calls, so the two bodies must be equal — and the
    // widened `mechanicAfter` is exactly the sort of field a replay forgets to fill.
    const replay = await post(body, `k-replay-${Date.now()}`);
    expect(replay.status).toBe(201);
    expect(replay.body).toEqual(first.body);
    expect(await saleCount()).toBe(1);
  });

  it('mechanic cash sale with a markup: no tab movement, markup added', async () => {
    const res = await post(
      bill(chain(), {
        mechanicId: 'm2',
        mechanicName: 'Chang Tao',
        mechanicDelta: '30.00',
      }),
    );
    expect(res.status).toBe(201);
    expect(res.body.data.mechanicCreditBalanceAfter).toBe('0.00');

    const m = await mechanic('m2');
    expect(Number(m.credit_balance)).toBe(0);
    expect(Number(m.total_markup)).toBe(30);
    expect(Number(m.total_discount)).toBe(0);
    expect(Number(m.total_sales)).toBe(350);
  });

  it('โอน/QR with a mechanic leaves the tab alone', async () => {
    const res = await post(
      bill(chain(), {
        paymentMethod: 'โอน/QR',
        mechanicId: 'm1',
        mechanicName: 'Lung Manop',
      }),
    );
    expect(res.status).toBe(201);
    expect(Number((await mechanic('m1')).credit_balance)).toBe(0);
    expect(Number((await mechanic('m1')).total_sales)).toBe(350);
  });

  it('over the limit without the flag: 409 CREDIT_LIMIT_EXCEEDED, and nothing is written', async () => {
    const res = await post(
      bill(chain(), {
        paymentMethod: 'เครดิตช่าง',
        mechanicId: 'm3',
        mechanicName: 'Tight Limit',
      }),
    );
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('CREDIT_LIMIT_EXCEEDED');
    expect(res.body.error.details).toEqual({
      creditLimit: '1000.00',
      creditBalance: '800.00',
      newBalance: '1150.00',
    });

    expect(await saleCount()).toBe(0);
    expect(await stockOf('p3')).toBe(20);
    const m = await mechanic('m3');
    expect(Number(m.credit_balance)).toBe(800);
    expect(Number(m.total_sales)).toBe(0);
    expect(await overrideAudits()).toEqual([]);
  });

  it('over the limit with the flag: 201, the tab moves, and exactly one audit row says who', async () => {
    const res = await post(
      bill(chain(), {
        paymentMethod: 'เครดิตช่าง',
        mechanicId: 'm3',
        mechanicName: 'Tight Limit',
        overrideCreditLimit: true,
      }),
    );
    expect(res.status).toBe(201);
    expect(res.body.data.mechanicCreditBalanceAfter).toBe('1150.00');
    expect(Number((await mechanic('m3')).credit_balance)).toBe(1150);

    const audits = await overrideAudits();
    expect(audits).toHaveLength(1);
    expect(audits[0].entity).toBe('mechanic');
    expect(audits[0].entity_id).toBe('m3');
    expect(audits[0].user_id).toBe(fixture.userId);
    expect(audits[0].device_id).toBe(fixture.posDeviceId);
    expect(audits[0].after).toEqual({
      saleId: res.body.data.id,
      total: '350.00',
      creditLimit: '1000.00',
      creditBalanceBefore: '800.00',
      creditBalanceAfter: '1150.00',
    });
  });

  it('the counter path: 409, the dialog, the same bill and the same key resent with the flag', async () => {
    // The client keys the bill, not the attempt, so the resend after 'ยืนยันขายเครดิต?'
    // carries the same Idempotency-Key with a different body. That is only not
    // IDEMPOTENCY_KEY_REUSED because the claim rolled back with the refused bill —
    // pinned here so a later change to the claim's lifetime (tx.3) cannot turn the
    // dialog's confirm into a bill that can never be rung up.
    const body = bill(chain(), {
      paymentMethod: 'เครดิตช่าง',
      mechanicId: 'm3',
      mechanicName: 'Tight Limit',
    });
    const key = `k-same-${Date.now()}`;
    const refused = await post(body, key);
    expect(refused.status).toBe(409);
    expect(refused.body.error.code).toBe('CREDIT_LIMIT_EXCEEDED');

    const confirmed = await post({ ...body, overrideCreditLimit: true }, key);
    expect(confirmed.status).toBe(201);
    expect(confirmed.body.data.mechanicCreditBalanceAfter).toBe('1150.00');
    expect(await saleCount()).toBe(1);
    expect(await overrideAudits()).toHaveLength(1);
  });

  it('the flag on a bill that is under the limit records nothing', async () => {
    const res = await post(
      bill(chain(), {
        paymentMethod: 'เครดิตช่าง',
        mechanicId: 'm1',
        mechanicName: 'Lung Manop',
        overrideCreditLimit: true,
      }),
    );
    expect(res.status).toBe(201);
    expect(await overrideAudits()).toEqual([]);
  });

  it('rejects a flag that is not a boolean', async () => {
    const res = await post(
      bill(chain(), {
        paymentMethod: 'เครดิตช่าง',
        mechanicId: 'm3',
        overrideCreditLimit: 'true',
      }),
    );
    expect(res.status).toBe(400);
    expect(await saleCount()).toBe(0);
  });

  it('replaying the same bill id answers the same ledger and moves nothing twice', async () => {
    const body = bill(chain(), {
      paymentMethod: 'เครดิตช่าง',
      customerId: 'c1',
      customerName: 'Somchai Jaidee',
      mechanicId: 'm1',
      mechanicName: 'Lung Manop',
    });
    const first = await post(body);
    expect(first.status).toBe(201);

    // A retry that lost its Idempotency-Key.
    const replay = await post(body, `k-fresh-${Date.now()}`);
    expect(replay.status).toBe(201);
    expect(replay.body.data.customerAfter).toEqual(
      first.body.data.customerAfter,
    );
    expect(replay.body.data.customerAfter).toEqual({
      id: 'c1',
      points: 485,
      totalSpend: '4850.00',
    });
    expect(replay.body.data.mechanicCreditBalanceAfter).toBe('350.00');

    expect(await saleCount()).toBe(1);
    expect((await customer('c1')).points).toBe(485);
    expect(Number((await mechanic('m1')).credit_balance)).toBe(350);
  });

  it('a bill with neither customer nor mechanic answers null for both', async () => {
    const res = await post(bill(chain()));
    expect(res.status).toBe(201);
    expect(res.body.data.customerAfter).toBeNull();
    expect(res.body.data.mechanicCreditBalanceAfter).toBeNull();
  });
});
