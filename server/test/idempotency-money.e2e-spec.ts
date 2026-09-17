import type { INestApplication } from '@nestjs/common';
import type { Request, Response } from 'express';
import type { Redis } from 'ioredis';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import {
  runInTenantScope,
  setRequestTenant,
} from '../src/common/request-context.js';
import { MechanicsController } from '../src/mechanics/mechanics.controller.js';
import { SalesController } from '../src/sales/sales.controller.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedMechanic,
  seedOpenShift,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';

// tx.3 (#152): idempotency moved from an interceptor into each handler's runTx. A claim
// committed in a different transaction from its work is a bill charged twice with every
// response a 200, so this suite does not trust responses: it counts rows.
//
//   - Over HTTP (since tx.4 #153 the route's runIdempotent opens the only transaction): the same key five
//     times, three of them at once, on the three money writes that move stock or cash.
//   - Called directly with no request transaction (the tx.4 shape): the controller's own
//     runIdempotent must open the one transaction, and claim, work and completion must all
//     use its query runner.
describe('idempotent money writes leave one effect in the tables (e2e, #152)', () => {
  const TENANT = '15215215-3333-4333-8333-152152152152';
  const MECHANIC = 'm-idem-152';
  const PIN = '1521';

  let app: INestApplication;
  let ds: DataSource;
  let admin: DataSource;
  let cache: Redis;
  let fixture: TenantFixture;
  let token: string;
  let seq = 0;

  const uniq = (prefix: string) => `${prefix}-${++seq}-${Date.now()}`;

  beforeAll(async () => {
    ({ app, ds, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { pin: PIN, cache });
    token = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'owner',
      deviceId: fixture.posDeviceId,
      deviceRole: 'pos',
    });
    await seedProduct(admin, TENANT, {
      id: 'p1',
      partNo: 'OF-1',
      name: 'Oil Filter',
      price: 85,
      cost: 50,
      stock: 40,
    });
    await seedMechanic(admin, TENANT, {
      id: MECHANIC,
      code: 'M152',
      name: 'ช่างทดสอบ',
      creditLimit: 20000,
      creditBalance: 3000,
    });
    await seedOpenShift(admin, TENANT, fixture.posDeviceId, {
      userId: fixture.userId,
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  const post = (path: string, key: string, body: object) =>
    request(app.getHttpServer())
      .post(`/api/v1${path}`)
      .set('Authorization', `Bearer ${token}`)
      .set('Idempotency-Key', key)
      .send(body);

  const saleBody = (qty = 1) => ({
    id: uniq('s-idem'),
    subtotal: (85 * qty).toFixed(2),
    discount: '0.00',
    total: (85 * qty).toFixed(2),
    paymentMethod: 'เงินสด',
    items: [
      {
        lineNo: 1,
        productId: 'p1',
        partNo: 'OF-1',
        name: 'Oil Filter',
        nameTH: 'Oil Filter',
        qty,
        price: '85.00',
      },
    ],
  });

  /** Three at once, then two more after they have all answered. */
  const fiveTimes = async (path: string, key: string, body: object) => {
    const burst = await Promise.all([
      post(path, key, body),
      post(path, key, body),
      post(path, key, body),
    ]);
    const tail = [await post(path, key, body), await post(path, key, body)];
    return [...burst, ...tail];
  };

  const count = async (sql: string, params: unknown[]): Promise<number> =>
    ((await admin.query(sql, params)) as { n: number }[])[0].n;

  const stock = async (): Promise<number> =>
    (
      (await admin.query(
        `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = 'p1'`,
        [TENANT],
      )) as { stock: number }[]
    )[0].stock;

  const keyRows = (key: string) =>
    admin.query(
      `SELECT status, endpoint, response_code FROM idempotency_keys
        WHERE tenant_id = $1::uuid AND key = $2`,
      [TENANT, key],
    ) as Promise<{ status: string; endpoint: string; response_code: number }[]>;

  const expectAllEqual = (
    responses: { status: number; body: unknown }[],
    status: number,
  ) => {
    for (const res of responses) {
      expect(res.status).toBe(status);
      expect(res.body).toEqual(responses[0].body);
    }
  };

  it('POST /sales five times with one key (three at once) → one bill, one movement, stock down once, one done key', async () => {
    const key = uniq('k-sale');
    const body = saleBody(2);

    const responses = await fiveTimes('/sales', key, body);

    expectAllEqual(responses, 201);
    // The table counts here are also backstopped by `existingSale` (the client's bill id),
    // so on this route the replay proof is the equal 201s and the one 'done' key; the returns
    // and credit-payment cases below are where the key is the only defence.
    expect(
      await count(
        `SELECT count(*)::int AS n FROM sales WHERE tenant_id = $1::uuid`,
        [TENANT],
      ),
    ).toBe(1);
    expect(
      await count(
        `SELECT count(*)::int AS n FROM movements
          WHERE tenant_id = $1::uuid AND product_id = 'p1' AND type = 'sale'`,
        [TENANT],
      ),
    ).toBe(1);
    expect(await stock()).toBe(38);
    expect(await keyRows(key)).toEqual([
      { status: 'done', endpoint: 'POST /api/v1/sales', response_code: 201 },
    ]);
  });

  it('POST /returns five times with one key (three at once) → one credit note, one movement, stock back once', async () => {
    const sale = await post('/sales', uniq('k-sale'), saleBody(2));
    expect(sale.status).toBe(201);
    expect(await stock()).toBe(38);

    const key = uniq('k-return');
    const responses = await fiveTimes('/returns', key, {
      saleId: sale.body.data.id,
      refundMethod: 'เงินสด',
      items: [{ productId: 'p1', name: 'Oil Filter', qty: 1, price: '85.00' }],
    });

    expectAllEqual(responses, 201);
    // No client id on a return: the key is its only duplicate defence.
    expect(
      await count(
        `SELECT count(*)::int AS n FROM returns WHERE tenant_id = $1::uuid`,
        [TENANT],
      ),
    ).toBe(1);
    expect(
      await count(
        `SELECT count(*)::int AS n FROM return_items WHERE tenant_id = $1::uuid`,
        [TENANT],
      ),
    ).toBe(1);
    expect(
      await count(
        `SELECT count(*)::int AS n FROM movements
          WHERE tenant_id = $1::uuid AND product_id = 'p1' AND type = 'return'`,
        [TENANT],
      ),
    ).toBe(1);
    expect(await stock()).toBe(39);
    expect(await keyRows(key)).toEqual([
      { status: 'done', endpoint: 'POST /api/v1/returns', response_code: 201 },
    ]);
  });

  it('POST /mechanics/:id/credit-payments five times with one key (three at once) → one payment, tab down once', async () => {
    const key = uniq('k-pay');
    // No client `id`, so the key is the only duplicate defence under test.
    const responses = await fiveTimes(
      `/mechanics/${MECHANIC}/credit-payments`,
      key,
      {
        amount: '1000.00',
        paymentMethod: 'เงินสด',
      },
    );

    expectAllEqual(responses, 201);
    expect(
      await count(
        `SELECT count(*)::int AS n FROM credit_payments WHERE tenant_id = $1::uuid`,
        [TENANT],
      ),
    ).toBe(1);
    const rows = (await admin.query(
      `SELECT credit_balance FROM mechanics WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, MECHANIC],
    )) as { credit_balance: string }[];
    expect(rows[0].credit_balance).toBe('2000.00');
    expect(await keyRows(key)).toEqual([
      {
        status: 'done',
        endpoint: `POST /api/v1/mechanics/${MECHANIC}/credit-payments`,
        response_code: 201,
      },
    ]);
  });

  it('the drawer and void routes answer the same status first time and on replay', async () => {
    const sale = await post('/sales', uniq('k-sale'), saleBody(1));
    expect(sale.status).toBe(201);
    const cases: Array<[string, object, number]> = [
      ['/shifts/current/entries', { type: 'in', amount: '50.00' }, 201],
      [`/sales/${sale.body.data.id}/void`, { reason: 'Return' }, 200],
      ['/shifts/close', { physicalCash: '0.00' }, 200],
      ['/shifts/open', { startingCash: '500.00' }, 200],
    ];
    for (const [path, body, status] of cases) {
      const key = uniq('k-status');
      const first = await post(path, key, body);
      const replay = await post(path, key, body);
      expect([path, first.status, replay.status]).toEqual([
        path,
        status,
        status,
      ]);
      expect(replay.body).toEqual(first.body);
    }
  });

  // ── the tx.4 shape: no request transaction ──────────────────────────────────────────

  /** A tenant scope with no transaction — what `TenantScopeMiddleware` + the guard give tx.4. */
  const inTenantScope = <T>(fn: () => Promise<T>): Promise<T> =>
    runInTenantScope(async () => {
      setRequestTenant(TENANT);
      return fn();
    });

  /** Refuses a second query runner outright, so a claim on its own connection is reported as that. */
  const refuseSecondRunner = () => {
    const original = ds.createQueryRunner.bind(ds);
    let calls = 0;
    return vi
      .spyOn(ds, 'createQueryRunner')
      .mockImplementation(
        (...args: Parameters<DataSource['createQueryRunner']>) => {
          if (++calls > 1) {
            throw new Error(
              'a second query runner was requested while the first is held',
            );
          }
          return original(...args);
        },
      );
  };

  /** What the controller reads from a request: the key header, the concrete path, the token. */
  const fakeRequest = (key: string, body: object, path = '/api/v1/sales') =>
    ({
      method: 'POST',
      baseUrl: '',
      path,
      body,
      header: (name: string) => (name === 'idempotency-key' ? key : undefined),
      user: {
        userId: fixture.userId,
        tenantId: TENANT,
        role: 'owner',
        deviceId: fixture.posDeviceId,
        deviceRole: 'pos',
      },
    }) as unknown as Request & { user: never };

  const fakeResponse = () => {
    const statuses: number[] = [];
    const res = {
      status: (code: number) => {
        statuses.push(code);
        return res;
      },
    };
    return { res: res as unknown as Response, statuses };
  };

  it('with no request transaction (the tx.4 shape), claim + sale + completion share one query runner, and a replay re-runs nothing', async () => {
    const sales = app.get(SalesController);
    const key = uniq('k-tx4');
    const body = saleBody(3);

    let runners = refuseSecondRunner();
    const first = fakeResponse();
    const created = await inTenantScope(() =>
      sales.create(body, fakeRequest(key, body), first.res),
    );
    expect(runners).toHaveBeenCalledTimes(1);
    expect(first.statuses).toEqual([]);
    expect(await stock()).toBe(37);
    expect(await keyRows(key)).toEqual([
      { status: 'done', endpoint: 'POST /api/v1/sales', response_code: 201 },
    ]);

    vi.restoreAllMocks();
    runners = refuseSecondRunner();
    const again = fakeResponse();
    const replayed = await inTenantScope(() =>
      sales.create(body, fakeRequest(key, body), again.res),
    );
    expect(runners).toHaveBeenCalledTimes(1);
    expect(again.statuses).toEqual([201]);
    expect(JSON.parse(JSON.stringify(replayed))).toEqual(
      JSON.parse(JSON.stringify(created)),
    );
    expect(await stock()).toBe(37);
    expect(
      await count(
        `SELECT count(*)::int AS n FROM movements WHERE tenant_id = $1::uuid AND type = 'sale'`,
        [TENANT],
      ),
    ).toBe(1);
  });

  it('with no request transaction (the tx.4 shape), a sale refused after the claim leaves no key and no bill', async () => {
    const sales = app.get(SalesController);
    const key = uniq('k-tx4-refused');
    // More than the 40 on the shelf: refused inside the transaction, after the claim.
    const body = saleBody(41);

    const runners = refuseSecondRunner();
    await expect(
      inTenantScope(() =>
        sales.create(body, fakeRequest(key, body), fakeResponse().res),
      ),
    ).rejects.toThrow();
    expect(runners).toHaveBeenCalledTimes(1);

    expect(await keyRows(key)).toEqual([]);
    expect(
      await count(
        `SELECT count(*)::int AS n FROM sales WHERE tenant_id = $1::uuid`,
        [TENANT],
      ),
    ).toBe(0);
    expect(await stock()).toBe(40);
  });

  it('with no request transaction (the tx.4 shape), three simultaneous same-key credit payments: two wait on the claim, then replay the winner', async () => {
    const mechanics = app.get(MechanicsController);
    const key = uniq('k-tx4-race');
    const body = { amount: '1000.00', paymentMethod: 'เงินสด' };
    const path = `/api/v1/mechanics/${MECHANIC}/credit-payments`;
    // Each call owns its connection: no middleware transaction to share.
    const runners = vi.spyOn(ds, 'createQueryRunner');

    // The winner claims, then parks on the mechanic row this superuser transaction holds,
    // so the other two arrive while its claim is uncommitted and block on the INSERT.
    const holder = admin.createQueryRunner();
    await holder.connect();
    await holder.startTransaction();
    let calls: Promise<{ result: unknown; statuses: number[] }>[] = [];
    try {
      await holder.query(
        `SELECT id FROM mechanics WHERE tenant_id = $1::uuid AND id = $2 FOR UPDATE`,
        [TENANT, MECHANIC],
      );
      calls = [0, 1, 2].map(() => {
        const { res, statuses } = fakeResponse();
        return inTenantScope(() =>
          mechanics.creditPayment(
            MECHANIC,
            body,
            fakeRequest(key, body, path),
            res,
          ),
        ).then((result) => ({ result, statuses }));
      });
      const deadline = Date.now() + 10_000;
      for (;;) {
        const waiting = (await admin.query(
          `SELECT count(*)::int AS n FROM pg_stat_activity
            WHERE usename = 'pos_app' AND datname = current_database()
              AND wait_event_type = 'Lock'`,
        )) as { n: number }[];
        if (waiting[0].n === 3) break;
        if (Date.now() > deadline) {
          throw new Error(
            `expected 3 pos_app backends waiting on a lock, saw ${waiting[0].n}`,
          );
        }
        await new Promise((r) => setTimeout(r, 20));
      }
    } finally {
      await holder.commitTransaction();
      await holder.release();
    }
    const outcomes = await Promise.all(calls);

    expect(runners).toHaveBeenCalledTimes(3);
    // Exactly one ran the work (Nest's own status stands); two replayed with the stored 201.
    expect(outcomes.map((o) => o.statuses).sort()).toEqual([[], [201], [201]]);
    const bodies = outcomes.map((o) => JSON.parse(JSON.stringify(o.result)));
    expect(bodies[1]).toEqual(bodies[0]);
    expect(bodies[2]).toEqual(bodies[0]);
    expect(
      await count(
        `SELECT count(*)::int AS n FROM credit_payments WHERE tenant_id = $1::uuid`,
        [TENANT],
      ),
    ).toBe(1);
    const rows = (await admin.query(
      `SELECT credit_balance FROM mechanics WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, MECHANIC],
    )) as { credit_balance: string }[];
    expect(rows[0].credit_balance).toBe('2000.00');
    expect(await keyRows(key)).toEqual([
      { status: 'done', endpoint: `POST ${path}`, response_code: 201 },
    ]);
  });
});
