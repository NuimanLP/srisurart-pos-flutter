import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import {
  accessToken,
  createTestApp,
  resetTenant,
  type TenantFixture,
} from './support/fixture.js';

const TENANT = '17171717-1717-4717-8717-171717171717';

describe('customers and mechanics (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;
  let managerToken: string;
  let cashierToken: string;
  let key = 0;

  const auth = (token = managerToken) => ({ Authorization: `Bearer ${token}` });
  const idempotency = () => `people-${++key}-${Date.now()}`;

  const createCustomer = (
    body: Record<string, unknown>,
    token = managerToken,
  ) =>
    request(app.getHttpServer())
      .post('/api/v1/customers')
      .set(auth(token))
      .set('Idempotency-Key', idempotency())
      .send(body);

  const createMechanic = (
    body: Record<string, unknown>,
    token = managerToken,
  ) =>
    request(app.getHttpServer())
      .post('/api/v1/mechanics')
      .set(auth(token))
      .set('Idempotency-Key', idempotency())
      .send(body);

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { cache });
    managerToken = accessToken({
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
      deviceId: fixture.backofficeDeviceId,
      deviceRole: 'backoffice',
    });
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it('starts customer codes at CUS001 and forces server-owned fields to zero/new values', async () => {
    const response = await createCustomer({
      id: 'client-id',
      code: 'CUS999',
      name: 'Walk-in',
      nameTH: 'ลูกค้า',
      points: 99,
      totalSpend: '123.45',
    });

    expect(response.status).toBe(201);
    expect(response.body.data).toMatchObject({
      code: 'CUS001',
      name: 'Walk-in',
      nameTH: 'ลูกค้า',
      points: 0,
      totalSpend: '0.00',
    });
    expect(response.body.data.id).not.toBe('client-id');
    expect(response.body.data.id.startsWith('c')).toBe(true);
    expect(Date.parse(response.body.data.createdAt)).not.toBeNaN();
    expect(Date.parse(response.body.data.updatedAt)).not.toBeNaN();
  });

  it('increments past the highest valid customer code and ignores malformed codes', async () => {
    await admin.query(
      `INSERT INTO customers (tenant_id, id, code, name, name_th)
       VALUES ($1::uuid, 'c-five', 'CUS005', 'Five', 'ห้า'),
              ($1::uuid, 'c-two', 'CUS002', 'Two', 'สอง'),
              ($1::uuid, 'c-bad', 'BAD', 'Bad', 'เสีย')`,
      [TENANT],
    );

    const response = await createCustomer({ name: 'Six', nameTH: 'หก' });
    expect(response.status).toBe(201);
    expect(response.body.data.code).toBe('CUS006');
  });

  it('serialises concurrent customer and mechanic code allocation in PostgreSQL', async () => {
    const customers = await Promise.all(
      Array.from({ length: 6 }, (_, index) =>
        createCustomer({
          name: `Customer ${index}`,
          nameTH: `ลูกค้า ${index}`,
        }),
      ),
    );
    expect(customers.every((response) => response.status === 201)).toBe(true);
    expect(
      new Set(customers.map((response) => response.body.data.code)).size,
    ).toBe(6);

    const mechanics = await Promise.all(
      Array.from({ length: 6 }, (_, index) =>
        createMechanic({ name: `Mechanic ${index}` }),
      ),
    );
    expect(mechanics.every((response) => response.status === 201)).toBe(true);
    expect(
      new Set(mechanics.map((response) => response.body.data.code)).size,
    ).toBe(6);
  });

  it('lists, searches, and patch-merges customers without changing server-owned fields', async () => {
    const first = await createCustomer({ name: 'Alpha', nameTH: 'อัลฟา' });
    await createCustomer({ name: 'Beta', nameTH: 'บีต้า' });
    const id = first.body.data.id as string;
    const before = first.body.data.updatedAt as string;

    const patch = await request(app.getHttpServer())
      .patch(`/api/v1/customers/${id}`)
      .set(auth())
      .set('Idempotency-Key', idempotency())
      .send({ phone: '0812345678', code: 'CUS900', points: 500 });
    expect(patch.status).toBe(200);
    expect(patch.body.data).toMatchObject({
      id,
      code: 'CUS001',
      name: 'Alpha',
      phone: '0812345678',
      points: 0,
    });
    expect(Date.parse(patch.body.data.updatedAt)).toBeGreaterThanOrEqual(
      Date.parse(before),
    );

    const list = await request(app.getHttpServer())
      .get('/api/v1/customers?page=1&limit=1')
      .set(auth());
    expect(list.status).toBe(200);
    expect(list.body.meta).toEqual({
      total: 2,
      page: 1,
      limit: 1,
      totalPages: 2,
    });
    expect(list.body.data).toHaveLength(1);

    const search = await request(app.getHttpServer())
      .get('/api/v1/customers?search=081234')
      .set(auth());
    expect(search.body.data.map((row: { id: string }) => row.id)).toEqual([id]);
  });

  it('soft-deletes a customer with bills, keeps the bill, and hides the tombstone', async () => {
    const customer = await createCustomer({
      name: 'Somchai Motors',
      nameTH: 'สมชาย ยานยนต์',
    });
    const id = customer.body.data.id as string;
    const cursor = new Date(
      Date.parse(customer.body.data.updatedAt) - 1,
    ).toISOString();
    await insertSale({
      id: 'sale-customer',
      customerId: id,
      customerName: 'สมชาย ยานยนต์',
    });

    const deleted = await request(app.getHttpServer())
      .delete(`/api/v1/customers/${id}`)
      .set(auth())
      .set('Idempotency-Key', idempotency());
    expect(deleted.status).toBe(200);
    expect(deleted.body.data).toEqual({ id, deleted: true });

    const list = await request(app.getHttpServer())
      .get('/api/v1/customers')
      .set(auth());
    const search = await request(app.getHttpServer())
      .get('/api/v1/customers?search=Somchai')
      .set(auth());
    expect(list.body.data).toHaveLength(0);
    expect(search.body.data).toHaveLength(0);
    expect(
      (
        await request(app.getHttpServer())
          .get(`/api/v1/customers/${id}`)
          .set(auth())
      ).status,
    ).toBe(404);

    const sync = await request(app.getHttpServer())
      .get(`/api/v1/customers?updatedSince=${encodeURIComponent(cursor)}`)
      .set(auth());
    expect(sync.body.data).toHaveLength(1);
    expect(sync.body.data[0]).toMatchObject({
      id,
      deletedAt: expect.any(String),
    });

    const rows = await admin.query(
      `SELECT c.deleted_at, s.customer_name
         FROM customers c
         JOIN sales s ON s.tenant_id = c.tenant_id AND s.customer_id = c.id
        WHERE c.tenant_id = $1::uuid AND c.id = $2`,
      [TENANT, id],
    );
    expect(rows[0].deleted_at).toBeInstanceOf(Date);
    expect(rows[0].customer_name).toBe('สมชาย ยานยนต์');
  });

  it('paginates customer sales at the database seam', async () => {
    const customer = await createCustomer({ name: 'Buyer', nameTH: 'ผู้ซื้อ' });
    const id = customer.body.data.id as string;
    for (let index = 1; index <= 3; index++) {
      await insertSale({
        id: `sale-page-${index}`,
        customerId: id,
        customerName: 'ผู้ซื้อ',
        date: `2026-09-1${index}T10:00:00Z`,
      });
    }

    const page1 = await request(app.getHttpServer())
      .get(`/api/v1/customers/${id}/sales?page=1&limit=2`)
      .set(auth());
    const page2 = await request(app.getHttpServer())
      .get(`/api/v1/customers/${id}/sales?page=2&limit=2`)
      .set(auth());
    expect(page1.body.meta).toEqual({
      total: 3,
      page: 1,
      limit: 2,
      totalPages: 2,
    });
    expect(page1.body.data).toHaveLength(2);
    expect(page2.body.data).toHaveLength(1);
    expect(
      new Set(
        [...page1.body.data, ...page2.body.data].map(
          (sale: { id: string }) => sale.id,
        ),
      ).size,
    ).toBe(3);
  });

  it('creates mechanics with M codes, zero ledger fields, and caller credit fields ignored', async () => {
    const response = await createMechanic({
      id: 'client-id',
      code: 'M999',
      name: 'New Guy',
      creditLimit: '1500.00',
      creditBalance: '900.00',
      totalSales: '800.00',
      totalCredit: '700.00',
      totalDiscount: '600.00',
      totalMarkup: '500.00',
    });
    expect(response.status).toBe(201);
    expect(response.body.data).toMatchObject({
      code: 'M001',
      name: 'New Guy',
      creditLimit: '1500.00',
      creditBalance: '0.00',
      totalSales: '0.00',
      totalCredit: '0.00',
      totalDiscount: '0.00',
      totalMarkup: '0.00',
    });
    expect(response.body.data.id.startsWith('m')).toBe(true);

    const second = await createMechanic({ name: 'Another' });
    expect(second.body.data.code).toBe('M002');
  });

  it('increments mechanics past valid maximum codes and ignores malformed codes', async () => {
    await admin.query(
      `INSERT INTO mechanics (tenant_id, id, code, name)
       VALUES ($1::uuid, 'm-five', 'M005', 'Five'),
              ($1::uuid, 'm-two', 'M002', 'Two'),
              ($1::uuid, 'm-bad', 'BAD', 'Bad')`,
      [TENANT],
    );
    const response = await createMechanic({ name: 'Six' });
    expect(response.status).toBe(201);
    expect(response.body.data.code).toBe('M006');
  });

  it('patches only editable mechanic fields and keeps every ledger field read-only', async () => {
    const created = await createMechanic({
      name: 'Original',
      creditLimit: '1000.00',
    });
    const id = created.body.data.id as string;
    await admin.query(
      `UPDATE mechanics
          SET credit_balance = 400, total_sales = 900, total_discount = 20, total_markup = 30
        WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, id],
    );

    const response = await request(app.getHttpServer())
      .patch(`/api/v1/mechanics/${id}`)
      .set(auth())
      .set('Idempotency-Key', idempotency())
      .send({
        name: 'Updated',
        phone: '0899999999',
        creditLimit: '2000.00',
        creditBalance: '0.00',
        totalSales: '0.00',
        totalDiscount: '0.00',
        totalMarkup: '0.00',
      });
    expect(response.status).toBe(200);
    expect(response.body.data).toMatchObject({
      name: 'Updated',
      phone: '0899999999',
      creditLimit: '2000.00',
      creditBalance: '400.00',
      totalSales: '900.00',
      totalDiscount: '20.00',
      totalMarkup: '30.00',
    });
  });

  it('requires manager access for mechanic writes but allows authenticated reads', async () => {
    const refused = await createMechanic(
      { name: 'Cashier edit' },
      cashierToken,
    );
    expect(refused.status).toBe(403);
    expect(refused.body.error.code).toBe('FORBIDDEN');

    const read = await request(app.getHttpServer())
      .get('/api/v1/mechanics')
      .set(auth(cashierToken));
    expect(read.status).toBe(200);
  });

  it('soft-deletes mechanics from normal list/search while exposing the sync tombstone', async () => {
    const created = await createMechanic({
      name: 'Hidden Mechanic',
      nickname: 'ช่างเอ',
    });
    const id = created.body.data.id as string;
    const cursor = new Date(
      Date.parse(created.body.data.updatedAt) - 1,
    ).toISOString();

    const deleted = await request(app.getHttpServer())
      .delete(`/api/v1/mechanics/${id}`)
      .set(auth())
      .set('Idempotency-Key', idempotency());
    expect(deleted.status).toBe(200);

    const list = await request(app.getHttpServer())
      .get('/api/v1/mechanics')
      .set(auth());
    const search = await request(app.getHttpServer())
      .get('/api/v1/mechanics?search=Hidden')
      .set(auth());
    expect(list.body.data).toHaveLength(0);
    expect(search.body.data).toHaveLength(0);

    const sync = await request(app.getHttpServer())
      .get(`/api/v1/mechanics?updatedSince=${encodeURIComponent(cursor)}`)
      .set(auth());
    expect(sync.body.data).toHaveLength(1);
    expect(sync.body.data[0].id).toBe(id);
    expect(sync.body.data[0].deletedAt).not.toBeNull();
  });

  it('returns paginated mechanic sales without loading all bills', async () => {
    const mechanic = await createMechanic({ name: 'Sales Mechanic' });
    const id = mechanic.body.data.id as string;
    for (let index = 1; index <= 3; index++) {
      await insertSale({
        id: `mechanic-sale-${index}`,
        mechanicId: id,
        mechanicName: 'Sales Mechanic',
        date: `2026-09-1${index}T11:00:00Z`,
      });
    }
    const response = await request(app.getHttpServer())
      .get(`/api/v1/mechanics/${id}/sales?page=2&limit=2`)
      .set(auth());
    expect(response.status).toBe(200);
    expect(response.body.meta).toEqual({
      total: 3,
      page: 2,
      limit: 2,
      totalPages: 2,
    });
    expect(response.body.data).toHaveLength(1);
  });

  async function insertSale(input: {
    id: string;
    customerId?: string;
    customerName?: string;
    mechanicId?: string;
    mechanicName?: string;
    date?: string;
  }): Promise<void> {
    await admin.query(
      `INSERT INTO sales
              (tenant_id, id, receipt_no, subtotal, discount, total, payment_method,
               customer_id, customer_name, mechanic_id, mechanic_name, date)
       VALUES ($1::uuid, $2, $3, 100, 0, 100, 'เงินสด', $4, $5, $6, $7, $8)`,
      [
        TENANT,
        input.id,
        `RC-${input.id}`,
        input.customerId ?? null,
        input.customerName ?? null,
        input.mechanicId ?? null,
        input.mechanicName ?? null,
        input.date ?? new Date().toISOString(),
      ],
    );
  }
});
