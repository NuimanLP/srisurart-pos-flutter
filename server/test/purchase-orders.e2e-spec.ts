import type { INestApplication } from '@nestjs/common';
import type { Redis } from 'ioredis';
import request, { type Response } from 'supertest';
import type { DataSource } from 'typeorm';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedOpenShift,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';

/**
 * #26 `p6.1` — purchase orders and receiving.
 *
 * The "Dart parity" cases are `frontend/test/purchase_orders_repository_test.dart`
 * replayed at the HTTP seam; the rest are the acceptance criteria and the paths the
 * Dart version cannot have (a status guard, other tenants, other roles, concurrency).
 */
const TENANT = '26262626-2626-4626-8626-262626262626';
const OTHER = '26262626-3636-4636-8636-363636363636';

interface Line {
  partNo: string;
  name?: string;
  qty: number;
  cost: string;
}

describe('purchase orders (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: Redis;
  let fixture: TenantFixture;
  let manager: string;
  let posManager: string;
  let otherManager: string;
  let seq = 0;

  const http = () => request(app.getHttpServer());
  const auth = (token: string) => ({ Authorization: `Bearer ${token}` });
  const key = () => `po-${++seq}-${Date.now()}-${Math.random()}`;

  const createPo = (
    body: unknown,
    token = manager,
    k = key(),
  ): Promise<Response> =>
    http()
      .post('/api/v1/purchase-orders')
      .set(auth(token))
      .set('Idempotency-Key', k)
      .send(body as object);
  const action = (
    id: string,
    verb: 'receive' | 'cancel',
    token = manager,
    k = key(),
  ): Promise<Response> =>
    http()
      .post(`/api/v1/purchase-orders/${id}/${verb}`)
      .set(auth(token))
      .set('Idempotency-Key', k);
  const del = (id: string, token = manager): Promise<Response> =>
    http()
      .delete(`/api/v1/purchase-orders/${id}`)
      .set(auth(token))
      .set('Idempotency-Key', key());
  const list = (query = '', token = manager): Promise<Response> =>
    http().get(`/api/v1/purchase-orders${query}`).set(auth(token));

  /** Creates an open PO and returns its id and number. */
  const openPo = async (
    items: Line[],
    supplier = 'Acme',
  ): Promise<{ id: string; poNo: string }> => {
    const res = await createPo({
      supplier,
      items: items.map((l) => ({ name: 'Widget', ...l })),
    });
    expect(res.status).toBe(201);
    return { id: res.body.data.id, poNo: res.body.data.poNo };
  };

  const product = async (id: string, tenant = TENANT) =>
    (
      await admin.query(
        `SELECT stock, cost::text AS cost FROM products WHERE tenant_id = $1::uuid AND id = $2`,
        [tenant, id],
      )
    )[0] as { stock: number; cost: string };
  const receiveMovements = async (poId: string) =>
    (await admin.query(
      `SELECT product_id, part_no, delta, type, note, stock_after, ref_id
         FROM movements WHERE tenant_id = $1::uuid AND ref_id = $2 ORDER BY product_id`,
      [TENANT, poId],
    )) as {
      product_id: string;
      part_no: string;
      delta: number;
      type: string;
      note: string;
      stock_after: number;
      ref_id: string;
    }[];
  const poRow = async (id: string, tenant = TENANT) =>
    (
      await admin.query(
        `SELECT status, received_at, cancelled_at FROM purchase_orders
          WHERE tenant_id = $1::uuid AND id = $2`,
        [tenant, id],
      )
    )[0] as
      | { status: string; received_at: Date | null; cancelled_at: Date | null }
      | undefined;

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { cache });
    const other = await resetTenant(admin, OTHER, { cache });
    const bo = (tenantId: string, f: TenantFixture, role = 'owner') =>
      accessToken({
        tenantId,
        userId: f.userId,
        role,
        deviceId: f.backofficeDeviceId,
        deviceRole: 'backoffice',
      });
    manager = bo(TENANT, fixture, 'owner');
    otherManager = bo(OTHER, other, 'owner');
    posManager = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'owner',
      deviceId: fixture.posDeviceId,
      deviceRole: 'pos',
    });
    // The Dart suite's dedicated test product: stock 10 at cost 100.
    await seedProduct(admin, TENANT, {
      id: 'tp1',
      partNo: 'TEST-1',
      name: 'Test Part',
      price: 200,
      cost: 100,
      stock: 10,
    });
  });

  afterAll(async () => {
    for (const t of [TENANT, OTHER]) {
      await resetTenant(admin, t);
      await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [t]);
    }
    await app.close();
  });

  describe('Dart parity', () => {
    it('savePO: server id and PO number, status open, lines written, stock untouched', async () => {
      const res = await createPo({
        supplier: 'Acme',
        items: [{ partNo: 'TEST-1', name: 'Widget', qty: 5, cost: '160.00' }],
      });
      expect(res.status).toBe(201);
      const po = res.body.data;
      expect(po.id).toMatch(/^po/);
      // ADR-0007: PO + two-digit device number + Buddhist year-month + running number.
      expect(po.poNo).toMatch(
        new RegExp(`^PO${String(fixture.posDeviceNo + 50).padStart(2, '0')}-\\d{4}-\\d{2}-0001$`),
      );
      expect(po.status).toBe('open');
      expect(po.supplier).toBe('Acme');
      expect(po.receivedAt).toBeNull();
      expect(po.items).toEqual([
        { lineNo: 1, partNo: 'TEST-1', name: 'Widget', qty: 5, cost: '160.00' },
      ]);
      expect(await product('tp1')).toEqual({ stock: 10, cost: '100.00' });
    });

    it('receivePO: exact weighted average 10@100 + 5@160 → 120.00, stock 15', async () => {
      const { id } = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '160.00' }]);
      const res = await action(id, 'receive');
      expect(res.status).toBe(200);
      expect(res.body.data).toMatchObject({
        poId: id,
        status: 'received',
        updated: [{ productId: 'tp1', partNo: 'TEST-1', stockAfter: 15, costAfter: '120.00' }],
        unmatched: [],
      });
      expect(await product('tp1')).toEqual({ stock: 15, cost: '120.00' });
    });

    it('receivePO: marks the PO received and sets receivedAt', async () => {
      const { id } = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '160.00' }]);
      const res = await action(id, 'receive');
      const row = await poRow(id);
      expect(row?.status).toBe('received');
      expect(row?.received_at).not.toBeNull();
      expect(res.body.data.receivedAt).toBe(row!.received_at!.toISOString());
    });

    it('receivePO: one receive movement with stockAfter, the verbatim note, and the PO as ref', async () => {
      const { id, poNo } = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '160.00' }]);
      const res = await action(id, 'receive');
      const rows = await receiveMovements(id);
      expect(rows).toEqual([
        {
          product_id: 'tp1',
          part_no: 'TEST-1',
          delta: 5,
          type: 'receive',
          // Integer-valued cost renders without `.00` (JS template parity).
          note: `PO ${poNo} จาก Acme · ทุนใหม่ ฿120`,
          stock_after: 15,
          ref_id: id,
        },
      ]);
      expect(res.body.data.movements).toHaveLength(1);
      expect(res.body.data.movements[0]).toMatchObject({
        productId: 'tp1',
        delta: 5,
        type: 'receive',
        stockAfter: 15,
      });
    });

    it('receivePO: matches the part number case-insensitively', async () => {
      await admin.query(
        `UPDATE products SET part_no = 'TeST-1' WHERE tenant_id = $1::uuid AND id = 'tp1'`,
        [TENANT],
      );
      const { id } = await openPo([{ partNo: 'test-1', qty: 5, cost: '160.00' }]);
      const res = await action(id, 'receive');
      expect(res.body.data.unmatched).toEqual([]);
      expect(await product('tp1')).toEqual({ stock: 15, cost: '120.00' });
    });

    it('cancelPO: status cancelled and cancelledAt', async () => {
      const { id } = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '160.00' }]);
      const res = await action(id, 'cancel');
      expect(res.status).toBe(200);
      expect(res.body.data.status).toBe('cancelled');
      expect(res.body.data.cancelledAt).not.toBeNull();
      expect((await poRow(id))?.status).toBe('cancelled');
    });

    it('deletePO: removes the PO and its lines', async () => {
      const { id } = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '160.00' }]);
      const res = await del(id);
      expect(res.status).toBe(200);
      expect(res.body.data).toEqual({ id, deleted: true });
      expect(await poRow(id)).toBeUndefined();
      const lines = await admin.query(
        `SELECT 1 FROM po_items WHERE tenant_id = $1::uuid AND po_id = $2`,
        [TENANT, id],
      );
      expect(lines).toHaveLength(0);
    });

    it('getPOs: newest first, each with its lines', async () => {
      const first = await openPo([{ partNo: 'X', qty: 1, cost: '1.00' }], 'A');
      const second = await openPo([{ partNo: 'Y', qty: 1, cost: '1.00' }], 'B');
      const res = await list();
      expect(res.status).toBe(200);
      expect(res.body.data.map((p: { id: string }) => p.id)).toEqual([second.id, first.id]);
      expect(res.body.data[0].items).toHaveLength(1);
      expect(res.body.meta.total).toBe(2);
    });
  });

  describe('acceptance criteria', () => {
    it('AC1: receiving twice is 409 PO_ALREADY_RECEIVED and stock moves exactly once', async () => {
      const { id } = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '160.00' }]);
      expect((await action(id, 'receive')).status).toBe(200);

      const again = await action(id, 'receive');
      expect(again.status).toBe(409);
      expect(again.body.error.code).toBe('PO_ALREADY_RECEIVED');
      expect(again.body.error.message).toBe('ใบสั่งซื้อนี้รับของแล้ว');

      expect(await product('tp1')).toEqual({ stock: 15, cost: '120.00' });
      expect(await receiveMovements(id)).toHaveLength(1);
    });

    it('AC1: two receipts racing with different keys — one wins, stock moves once', async () => {
      const { id } = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '160.00' }]);
      const results = await Promise.all(
        Array.from({ length: 5 }, () => action(id, 'receive')),
      );
      const statuses = results.map((r) => r.status).sort();
      expect(statuses).toEqual([200, 409, 409, 409, 409]);
      for (const r of results.filter((x) => x.status === 409)) {
        expect(r.body.error.code).toBe('PO_ALREADY_RECEIVED');
      }
      expect(await product('tp1')).toEqual({ stock: 15, cost: '120.00' });
      expect(await receiveMovements(id)).toHaveLength(1);
    });

    it('AC2: a line at cost zero leaves the average cost unchanged', async () => {
      const { id } = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '0.00' }]);
      const res = await action(id, 'receive');
      expect(res.body.data.updated[0].costAfter).toBe('100.00');
      expect(await product('tp1')).toEqual({ stock: 15, cost: '100.00' });
    });

    it('AC3: receiving into zero stock sets the cost to the incoming cost', async () => {
      await seedProduct(admin, TENANT, {
        id: 'tp0',
        partNo: 'ZERO-1',
        name: 'Empty Shelf',
        price: 200,
        cost: 90,
        stock: 0,
      });
      const { id } = await openPo([{ partNo: 'ZERO-1', qty: 4, cost: '125.50' }]);
      const res = await action(id, 'receive');
      expect(res.status).toBe(200);
      expect(await product('tp0')).toEqual({ stock: 4, cost: '125.50' });
    });

    it('AC4: unmatched part numbers come back as a list and the rest still applies', async () => {
      const { id } = await openPo([
        { partNo: 'TEST-1', qty: 5, cost: '160.00' },
        { partNo: 'NOPE-9', name: 'Ghost', qty: 3, cost: '50.00' },
      ]);
      const res = await action(id, 'receive');
      expect(res.status).toBe(200);
      expect(res.body.data.unmatched).toEqual(['NOPE-9']);
      expect(await product('tp1')).toEqual({ stock: 15, cost: '120.00' });
      const ghost = await admin.query(
        `SELECT 1 FROM products WHERE tenant_id = $1::uuid AND lower(part_no) = 'nope-9'`,
        [TENANT],
      );
      expect(ghost).toHaveLength(0);
      expect((await poRow(id))?.status).toBe('received');
    });

    it('AC4: a soft-deleted product is unmatched, and its stock is not touched', async () => {
      await admin.query(
        `UPDATE products SET deleted_at = now() WHERE tenant_id = $1::uuid AND id = 'tp1'`,
        [TENANT],
      );
      const { id } = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '160.00' }]);
      const res = await action(id, 'receive');
      expect(res.body.data.unmatched).toEqual(['TEST-1']);
      expect(res.body.data.updated).toEqual([]);
      expect(await product('tp1')).toEqual({ stock: 10, cost: '100.00' });
    });

    it('AC5: one part on two lines averages line by line, as the Dart loop does', async () => {
      // Line 1: (10×100 + 5×160)/15 = 120.00 → line 2: (15×120 + 5×100)/20 = 115.00.
      const { id, poNo } = await openPo([
        { partNo: 'TEST-1', qty: 5, cost: '160.00' },
        { partNo: 'test-1', qty: 5, cost: '100.00' },
      ]);
      const res = await action(id, 'receive');
      expect(res.status).toBe(200);
      expect(await product('tp1')).toEqual({ stock: 20, cost: '115.00' });
      // One ledger row per product per PO (`uq_movements_ref`), carrying both lines.
      const rows = await receiveMovements(id);
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({
        delta: 10,
        stock_after: 20,
        note: `PO ${poNo} จาก Acme · ทุนใหม่ ฿115`,
      });
    });

    it('AC5: a non-terminating average is rounded to the satang', async () => {
      await seedProduct(admin, TENANT, {
        id: 'tp7',
        partNo: 'ODD-7',
        name: 'Odd',
        price: 50,
        cost: 33.33,
        stock: 7,
      });
      // (7×33.33 + 3×41.07)/10 = 35.652 → Dart round2 → 35.65
      const { id, poNo } = await openPo([{ partNo: 'ODD-7', qty: 3, cost: '41.07' }]);
      await action(id, 'receive');
      expect(await product('tp7')).toEqual({ stock: 10, cost: '35.65' });
      const rows = await receiveMovements(id);
      expect(rows[0].note).toBe(`PO ${poNo} จาก Acme · ทุนใหม่ ฿35.65`);
    });
  });

  describe('idempotency and concurrency', () => {
    it('a replay with the same Idempotency-Key answers the same body and moves stock once', async () => {
      const { id } = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '160.00' }]);
      const k = key();
      const first = await action(id, 'receive', manager, k);
      const replay = await action(id, 'receive', manager, k);
      expect(first.status).toBe(200);
      expect(replay.status).toBe(200);
      expect(replay.body).toEqual(first.body);
      expect(await product('tp1')).toEqual({ stock: 15, cost: '120.00' });
      expect(await receiveMovements(id)).toHaveLength(1);
    });

    it('the same key on a different PO is refused, not replayed', async () => {
      const a = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '160.00' }]);
      const b = await openPo([{ partNo: 'TEST-1', qty: 1, cost: '160.00' }]);
      const k = key();
      expect((await action(a.id, 'receive', manager, k)).status).toBe(200);
      const res = await action(b.id, 'receive', manager, k);
      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('IDEMPOTENCY_KEY_REUSED');
      expect((await poRow(b.id))?.status).toBe('open');
    });

    it('a receipt racing sales on the same product: no deadlock, no 500, stock adds up', async () => {
      await seedProduct(admin, TENANT, {
        id: 'hot',
        partNo: 'HOT-1',
        name: 'Hot Part',
        price: 100,
        cost: 60,
        stock: 50,
      });
      await seedOpenShift(admin, TENANT, fixture.posDeviceId, { userId: fixture.userId });
      const { id } = await openPo([
        { partNo: 'HOT-1', qty: 7, cost: '80.00' },
        { partNo: 'TEST-1', qty: 2, cost: '100.00' },
      ]);

      const sale = (i: number) =>
        http()
          .post('/api/v1/sales')
          .set(auth(posManager))
          .set('Idempotency-Key', key())
          .send({
            id: `s-po-race-${i}-${Date.now()}`,
            subtotal: '200.00',
            discount: '0.00',
            total: '200.00',
            paymentMethod: 'เงินสด',
            // Two products, so a sale locks both rows the receipt also locks.
            items: [
              { lineNo: 1, productId: 'hot', name: 'Hot Part', qty: 1, price: '100.00' },
              { lineNo: 2, productId: 'tp1', name: 'Test Part', qty: 1, price: '100.00' },
            ],
          });

      const requests: Promise<Response>[] = [];
      for (let i = 0; i < 8; i++) {
        requests.push(sale(i));
        if (i === 3) requests.push(action(id, 'receive'));
      }
      const results = await Promise.all(requests);
      expect(results.map((r) => r.status).filter((s) => s !== 200 && s !== 201)).toEqual([]);

      expect((await product('hot')).stock).toBe(50 - 8 + 7);
      expect((await product('tp1')).stock).toBe(10 - 8 + 2);
      // The ledger agrees with the counter: the receive row's stock_after is whatever
      // the product held when the receipt ran, plus the delivery.
      const [hotRow] = (await receiveMovements(id)).filter((r) => r.product_id === 'hot');
      expect(hotRow.delta).toBe(7);
      expect(hotRow.stock_after).toBeGreaterThanOrEqual(50 - 8 + 7);
      expect(hotRow.stock_after).toBeLessThanOrEqual(50 + 7);
    });
  });

  describe('status rules', () => {
    it('a received PO cannot be cancelled or deleted', async () => {
      const { id } = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '160.00' }]);
      await action(id, 'receive');

      const cancel = await action(id, 'cancel');
      expect(cancel.status).toBe(409);
      expect(cancel.body.error.code).toBe('PO_ALREADY_RECEIVED');

      const remove = await del(id);
      expect(remove.status).toBe(409);
      expect(remove.body.error.code).toBe('PO_ALREADY_RECEIVED');

      expect((await poRow(id))?.status).toBe('received');
    });

    it('a cancelled PO cannot be received', async () => {
      const { id } = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '160.00' }]);
      await action(id, 'cancel');
      const res = await action(id, 'receive');
      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('PO_CANCELLED');
      expect(await product('tp1')).toEqual({ stock: 10, cost: '100.00' });
      expect(await receiveMovements(id)).toHaveLength(0);
    });

    it('cancelling a cancelled PO answers it unchanged', async () => {
      const { id } = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '160.00' }]);
      const first = await action(id, 'cancel');
      const second = await action(id, 'cancel');
      expect(second.status).toBe(200);
      expect(second.body.data.cancelledAt).toBe(first.body.data.cancelledAt);
    });

    it('a cancelled PO can be deleted', async () => {
      const { id } = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '160.00' }]);
      await action(id, 'cancel');
      expect((await del(id)).status).toBe(200);
      expect(await poRow(id)).toBeUndefined();
    });

    it('?status= filters, and an unknown status is a 400', async () => {
      const a = await openPo([{ partNo: 'TEST-1', qty: 1, cost: '1.00' }]);
      const b = await openPo([{ partNo: 'TEST-1', qty: 1, cost: '1.00' }]);
      await action(b.id, 'cancel');
      const open = await list('?status=open');
      expect(open.body.data.map((p: { id: string }) => p.id)).toEqual([a.id]);
      expect((await list('?status=done')).status).toBe(400);
    });

    it('an unknown PO is 404 PO_NOT_FOUND on receive and cancel', async () => {
      for (const verb of ['receive', 'cancel'] as const) {
        const res = await action('po-missing', verb);
        expect(res.status).toBe(404);
        expect(res.body.error.code).toBe('PO_NOT_FOUND');
      }
    });
  });

  describe('side effects', () => {
    it('writes one po.receive audit row with the products before and after', async () => {
      const { id } = await openPo([
        { partNo: 'TEST-1', qty: 5, cost: '160.00' },
        { partNo: 'NOPE-9', qty: 1, cost: '1.00' },
      ]);
      await action(id, 'receive');
      const rows = await admin.query(
        `SELECT user_id, device_id, entity, before, after FROM audit_log
          WHERE tenant_id = $1::uuid AND action = 'po.receive' AND entity_id = $2`,
        [TENANT, id],
      );
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({
        user_id: fixture.userId,
        device_id: fixture.backofficeDeviceId,
        entity: 'purchase_order',
        before: { products: [{ id: 'tp1', stock: 10, cost: '100.00' }] },
        after: {
          products: [{ productId: 'tp1', partNo: 'TEST-1', stockAfter: 15, costAfter: '120.00' }],
          unmatched: ['NOPE-9'],
        },
      });
    });

    it('clears the product cache after the receipt commits', async () => {
      const read = () => http().get('/api/v1/products/tp1').set(auth(manager));
      await read();
      const cached = await read();
      expect(cached.headers['x-cache']).toBe('HIT');

      const { id } = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '160.00' }]);
      await action(id, 'receive');

      const after = await read();
      expect(after.headers['x-cache']).toBe('MISS');
      expect(after.body.data).toMatchObject({ stock: 15, cost: '120.00' });
    });
  });

  describe('refusals', () => {
    it('requires authentication for purchase order routes', async () => {
      expect((await request(app.getHttpServer()).get('/api/v1/purchase-orders')).status).toBe(401);
    });

    it("another tenant's manager cannot see, receive, cancel or delete this tenant's PO", async () => {
      const { id } = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '160.00' }]);
      // The other tenant has a product with the same part number; it must not move either.
      await seedProduct(admin, OTHER, {
        id: 'tp1',
        partNo: 'TEST-1',
        name: 'Test Part',
        price: 200,
        cost: 100,
        stock: 10,
      });

      const seen = await list('', otherManager);
      expect(seen.body.data).toEqual([]);
      for (const verb of ['receive', 'cancel'] as const) {
        const res = await action(id, verb, otherManager);
        expect(res.status).toBe(404);
      }
      expect((await del(id, otherManager)).status).toBe(200);

      expect((await poRow(id))?.status).toBe('open');
      expect(await product('tp1')).toEqual({ stock: 10, cost: '100.00' });
      expect(await product('tp1', OTHER)).toEqual({ stock: 10, cost: '100.00' });
    });

    it("a part number that exists only in another tenant is unmatched, and that tenant's stock stays put", async () => {
      await seedProduct(admin, OTHER, {
        id: 'ob1',
        partNo: 'ONLY-B',
        name: 'Other Shop Part',
        price: 200,
        cost: 100,
        stock: 10,
      });
      const { id } = await openPo([{ partNo: 'ONLY-B', qty: 5, cost: '160.00' }]);
      const res = await action(id, 'receive');
      expect(res.status).toBe(200);
      expect(res.body.data.unmatched).toEqual(['ONLY-B']);
      expect(res.body.data.updated).toEqual([]);
      expect(await product('ob1', OTHER)).toEqual({ stock: 10, cost: '100.00' });
      const otherMoves = await admin.query(
        `SELECT 1 FROM movements WHERE tenant_id = $1::uuid`,
        [OTHER],
      );
      expect(otherMoves).toHaveLength(0);
    });

    it('refuses malformed bodies with a 400 and writes nothing', async () => {
      const line = { partNo: 'TEST-1', name: 'Widget', qty: 1, cost: '1.00' };
      const bad: unknown[] = [
        { items: [line] },
        { supplier: '  ', items: [line] },
        { supplier: 'Acme', items: [] },
        { supplier: 'Acme' },
        { supplier: 'Acme', items: [{ ...line, partNo: ' ' }] },
        { supplier: 'Acme', items: [{ ...line, qty: 0 }] },
        { supplier: 'Acme', items: [{ ...line, qty: -3 }] },
        { supplier: 'Acme', items: [{ ...line, qty: 1.5 }] },
        { supplier: 'Acme', items: [{ ...line, qty: 2_147_483_648 }] },
        { supplier: 'Acme', items: [{ ...line, cost: '-1.00' }] },
        { supplier: 'Acme', items: [{ ...line, cost: '1.005' }] },
        { supplier: 'Acme', items: [{ ...line, cost: 'free' }] },
        { supplier: 'Acme', items: [{ ...line, cost: '99999999999.00' }] },
      ];
      for (const body of bad) {
        const res = await createPo(body);
        expect(res.status, JSON.stringify(body)).toBe(400);
      }
      const count = await admin.query(
        `SELECT count(*)::int AS n FROM purchase_orders WHERE tenant_id = $1::uuid`,
        [TENANT],
      );
      expect(count[0].n).toBe(0);
    });

    it('refuses a receive with no Idempotency-Key', async () => {
      const { id } = await openPo([{ partNo: 'TEST-1', qty: 5, cost: '160.00' }]);
      const res = await http()
        .post(`/api/v1/purchase-orders/${id}/receive`)
        .set(auth(manager));
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('IDEMPOTENCY_KEY_INVALID');
      expect((await poRow(id))?.status).toBe('open');
    });

    it('refuses a receive that would take stock past INT max, and rolls back', async () => {
      await admin.query(
        `UPDATE products SET stock = 2147483640 WHERE tenant_id = $1::uuid AND id = 'tp1'`,
        [TENANT],
      );
      const { id } = await openPo([{ partNo: 'TEST-1', qty: 10, cost: '160.00' }]);
      const res = await action(id, 'receive');
      expect(res.status).toBe(400);
      expect((await poRow(id))?.status).toBe('open');
      expect((await product('tp1')).stock).toBe(2147483640);
    });
  });
});
