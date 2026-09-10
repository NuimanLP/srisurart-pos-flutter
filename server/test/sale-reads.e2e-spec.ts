import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';

// #23 acceptance suite: the read side of selling, plus the manual void.
const TENANT = '11111111-7777-4777-8777-111111111111';
const PIN = '4821';

describe('sale reads and void (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let fixture: TenantFixture;
  let posToken: string;
  let backofficeToken: string;
  let cashierToken: string;
  let keySeq = 0;

  const sell = (body: Record<string, unknown>, token?: string) =>
    request(app.getHttpServer())
      .post('/api/v1/sales')
      .set('Authorization', `Bearer ${token ?? posToken}`)
      .set('Idempotency-Key', `k-${++keySeq}-${Date.now()}`)
      .send(body);

  const get = (path: string, token?: string) =>
    request(app.getHttpServer())
      .get(`/api/v1${path}`)
      .set('Authorization', `Bearer ${token ?? posToken}`);

  const voidSale = (id: string, body: unknown, token?: string) =>
    request(app.getHttpServer())
      .post(`/api/v1/sales/${id}/void`)
      .set('Authorization', `Bearer ${token ?? posToken}`)
      .set('Idempotency-Key', `k-void-${++keySeq}-${Date.now()}`)
      .send(body as object);

  /** Rings up `qty` of p1 at 85 and returns the created bill. */
  const ringUp = async (qty = 1, extra: Record<string, unknown> = {}) => {
    const total = (qty * 85).toFixed(2);
    const res = await sell({
      id: `s-${++keySeq}-${Date.now()}`,
      subtotal: total,
      discount: '0.00',
      total,
      paymentMethod: 'เงินสด',
      items: [
        {
          lineNo: 1,
          productId: 'p1',
          partNo: 'OF-1',
          name: 'Oil Filter',
          nameTH: 'กรองน้ำมันเครื่อง',
          qty,
          price: '85.00',
        },
      ],
      ...extra,
    });
    expect(res.status).toBe(201);
    return res.body.data as { id: string; receiptNo: string };
  };

  const stockOf = async (id: string): Promise<number> => {
    const rows = await admin.query(
      `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, id],
    );
    return rows[0].stock as number;
  };

  beforeAll(async () => {
    ({ app, admin } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { posDeviceNo: 9, pin: PIN });
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
    cashierToken = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'cashier',
      deviceId: fixture.posDeviceId,
      deviceRole: 'pos',
    });
    await seedProduct(admin, TENANT, {
      id: 'p1',
      partNo: 'OF-1',
      name: 'Oil Filter',
      nameTH: 'กรองน้ำมันเครื่อง',
      price: 85,
      cost: 50,
      stock: 40,
    });
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it('finds a bill by the receipt number printed on the paper, with its lines', async () => {
    const sale = await ringUp(2);

    const res = await get(`/sales?receiptNo=${encodeURIComponent(sale.receiptNo)}`);
    expect(res.status).toBe(200);
    expect(res.body.data.total).toBe(1);
    expect(res.body.data.items[0].id).toBe(sale.id);
    expect(res.body.data.items[0].items).toHaveLength(1);
    expect(res.body.data.items[0].items[0].qty).toBe(2);
    expect(res.body.data.items[0].items[0].costAtSale).toBe('50.00');
  });

  it('searches by part of a receipt number or a customer name', async () => {
    await admin.query(
      `INSERT INTO customers (tenant_id, id, code, name, name_th)
            VALUES ($1::uuid, 'c1', 'C001', 'Somchai Motors', 'สมชาย ยานยนต์')`,
      [TENANT],
    );
    const withCustomer = await ringUp(1, {
      customerId: 'c1',
      customerName: 'สมชาย ยานยนต์',
    });
    await ringUp(1);

    const byName = await get('/sales?search=' + encodeURIComponent('สมชาย'));
    expect(byName.body.data.items).toHaveLength(1);
    expect(byName.body.data.items[0].id).toBe(withCustomer.id);

    const byNumber = await get('/sales?search=RC09-');
    expect(byNumber.body.data.total).toBe(2);
  });

  it('treats % and _ in a search as characters, not wildcards', async () => {
    await ringUp(1);
    const res = await get('/sales?search=%25');
    expect(res.status).toBe(200);
    expect(res.body.data.items).toHaveLength(0);
  });

  it('paginates instead of loading the whole table', async () => {
    for (let i = 0; i < 3; i++) await ringUp(1);

    const page1 = await get('/sales?page=1&limit=2');
    expect(page1.body.data.total).toBe(3);
    expect(page1.body.data.items).toHaveLength(2);
    expect(page1.body.data.limit).toBe(2);

    const page2 = await get('/sales?page=2&limit=2');
    expect(page2.body.data.items).toHaveLength(1);

    // Newest first, and the two pages do not overlap.
    const ids = [...page1.body.data.items, ...page2.body.data.items].map(
      (s: { id: string }) => s.id,
    );
    expect(new Set(ids).size).toBe(3);
    expect((await get('/sales?limit=0')).status).toBe(400);
    expect((await get('/sales?from=not-a-date')).status).toBe(400);
  });

  it('filters by date range', async () => {
    const old = await ringUp(1);
    await admin.query(
      `UPDATE sales SET date = '2020-01-01T00:00:00Z' WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, old.id],
    );
    const recent = await ringUp(1);

    const res = await get('/sales?from=2021-01-01T00:00:00Z');
    expect(res.body.data.items).toHaveLength(1);
    expect(res.body.data.items[0].id).toBe(recent.id);
  });

  it('reads one bill by id, and 404s for one that does not exist', async () => {
    const sale = await ringUp(1);
    const res = await get(`/sales/${sale.id}`);
    expect(res.status).toBe(200);
    expect(res.body.data.receiptNo).toBe(sale.receiptNo);

    const missing = await get('/sales/no-such-bill');
    expect(missing.status).toBe(404);
    expect(missing.body.error.code).toBe('SALE_NOT_FOUND');
    expect(missing.body.error.message).toBe('Sale not found');
  });

  it('reports per-line refunded quantities, summed across credit notes', async () => {
    const sale = await ringUp(5);

    const none = await get(`/sales/${sale.id}/refunded-qty`);
    expect(none.status).toBe(200);
    expect(none.body.data).toEqual({});

    // Two credit notes against the same bill, as `getRefundedQty` sums them.
    for (const [n, qty] of [
      ['1', 1],
      ['2', 2],
    ] as const) {
      await admin.query(
        `INSERT INTO returns (tenant_id, id, cn_no, sale_id, receipt_no,
                              refund_subtotal, refund_discount, refund_total, refund_method)
              VALUES ($1::uuid, $2, $3, $4, $5, 0, 0, 0, 'เงินสด')`,
        [TENANT, `r${n}`, `CN09-2569-01-000${n}`, sale.id, sale.receiptNo],
      );
      await admin.query(
        `INSERT INTO return_items (tenant_id, return_id, line_no, product_id, name, qty, price)
              VALUES ($1::uuid, $2, 1, 'p1', 'Oil Filter', $3, 85)`,
        [TENANT, `r${n}`, qty],
      );
    }

    const res = await get(`/sales/${sale.id}/refunded-qty`);
    expect(res.body.data).toEqual({ p1: 3 });
    expect((await get('/sales/no-such-bill/refunded-qty')).status).toBe(404);
  });

  it('a backoffice device can read bills', async () => {
    const sale = await ringUp(1);
    expect((await get('/sales', backofficeToken)).status).toBe(200);
    expect((await get(`/sales/${sale.id}`, backofficeToken)).status).toBe(200);
    expect((await get(`/sales/${sale.id}/refunded-qty`, backofficeToken)).status).toBe(200);
  });

  it('voids a bill: stock restored, movement written, audit row written', async () => {
    const sale = await ringUp(4);
    expect(await stockOf('p1')).toBe(36);

    const res = await voidSale(sale.id, { pin: PIN });
    expect(res.status).toBe(200);
    expect(res.body.data.voided).toBe(true);
    expect(res.body.data.voidedAt).not.toBeNull();
    expect(await stockOf('p1')).toBe(40);

    const movements = await admin.query(
      `SELECT delta, type, note, stock_after FROM movements
        WHERE tenant_id = $1::uuid AND ref_id = $2 AND type = 'return'`,
      [TENANT, sale.id],
    );
    expect(movements).toEqual([
      { delta: 4, type: 'return', note: 'ยกเลิกบิล', stock_after: 40 },
    ]);

    const audit = await admin.query(
      `SELECT action, entity, entity_id, user_id, device_id FROM audit_log
        WHERE tenant_id = $1::uuid AND action = 'sale.void'`,
      [TENANT],
    );
    expect(audit).toHaveLength(1);
    expect(audit[0].entity_id).toBe(sale.id);
    expect(audit[0].user_id).toBe(fixture.userId);
    expect(audit[0].device_id).toBe(fixture.posDeviceId);
  });

  it('refuses a void without the PIN, with a wrong PIN, or from a cashier', async () => {
    const sale = await ringUp(2);

    for (const body of [{}, { pin: '0000' }, { pin: 12345 }]) {
      const res = await voidSale(sale.id, body);
      expect(res.status).toBe(403);
    }
    // Right PIN, wrong rank: voiding is what staff fetch a manager for.
    const asCashier = await voidSale(sale.id, { pin: PIN }, cashierToken);
    expect(asCashier.status).toBe(403);

    expect(await stockOf('p1')).toBe(38);
    const rows = await admin.query(
      `SELECT voided FROM sales WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, sale.id],
    );
    expect(rows[0].voided).toBe(false);
    const audit = await admin.query(
      `SELECT count(*)::int AS n FROM audit_log
        WHERE tenant_id = $1::uuid AND action = 'sale.void'`,
      [TENANT],
    );
    expect(audit[0].n).toBe(0);
  });

  it('refuses to void twice', async () => {
    const sale = await ringUp(3);
    expect((await voidSale(sale.id, { pin: PIN })).status).toBe(200);
    expect(await stockOf('p1')).toBe(40);

    const again = await voidSale(sale.id, { pin: PIN });
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe('SALE_VOIDED');
    expect(again.body.error.message).toBe('Bill already voided');
    // Stock restored once, not twice — the shop must not gain inventory it never had.
    expect(await stockOf('p1')).toBe(40);
  });

  it('refuses to void a bill that already has a credit note against it', async () => {
    const sale = await ringUp(2);
    await admin.query(
      `INSERT INTO returns (tenant_id, id, cn_no, sale_id, receipt_no,
                            refund_subtotal, refund_discount, refund_total, refund_method)
            VALUES ($1::uuid, 'r-existing', 'CN09-2569-01-0009', $2, $3, 85, 0, 85, 'เงินสด')`,
      [TENANT, sale.id, sale.receiptNo],
    );

    const res = await voidSale(sale.id, { pin: PIN });
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('SALE_HAS_RETURNS');
    expect(await stockOf('p1')).toBe(38);
  });

  it('a backoffice device cannot void, and an unknown bill 404s', async () => {
    const sale = await ringUp(1);
    const wrongDevice = await voidSale(sale.id, { pin: PIN }, backofficeToken);
    expect(wrongDevice.status).toBe(403);
    expect(wrongDevice.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');

    const missing = await voidSale('no-such-bill', { pin: PIN });
    expect(missing.status).toBe(404);
    expect(missing.body.error.code).toBe('SALE_NOT_FOUND');
  });
});
