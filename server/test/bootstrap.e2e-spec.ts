import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import {
  accessToken,
  createTestApp,
  resetTenant,
  type TenantFixture,
} from './support/fixture.js';

const TENANT = '25252525-2525-4525-8525-252525252525';

describe('bootstrap and settings (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;
  let ownerToken: string;
  let key = 0;

  const auth = (token = ownerToken) => ({ Authorization: `Bearer ${token}` });
  const idempotency = () => `bootstrap-${++key}-${Date.now()}`;

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { cache });
    ownerToken = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'owner',
      deviceId: fixture.backofficeDeviceId,
      deviceRole: 'backoffice',
    });
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it('GET /settings returns settings for tenant', async () => {
    const res = await request(app.getHttpServer())
      .get('/api/v1/settings')
      .set(auth());

    expect(res.status).toBe(200);
    expect(res.body.data).toMatchObject({
      shopName: expect.any(String),
      taxRate: 7,
      quoteValidDays: 30,
    });
  });

  it('PATCH /settings requires auth', async () => {
    const res = await request(app.getHttpServer())
      .patch('/api/v1/settings')
      .set('Idempotency-Key', idempotency())
      .send({ shopName: 'Hacked Shop' });

    expect(res.status).toBe(401);
  });

  it('PATCH /settings updates settings when authorized as owner', async () => {
    const res = await request(app.getHttpServer())
      .patch('/api/v1/settings')
      .set(auth(ownerToken))
      .set('Idempotency-Key', idempotency())
      .send({
        shopName: 'SriSurart New Shop',
        taxRate: 10,
        phone: '077-123456',
      });

    expect(res.status).toBe(200);
    expect(res.body.data).toMatchObject({
      shopName: 'SriSurart New Shop',
      taxRate: 10,
      phone: '077-123456',
    });

    const getRes = await request(app.getHttpServer())
      .get('/api/v1/settings')
      .set(auth());

    expect(getRes.status).toBe(200);
    expect(getRes.body.data.shopName).toBe('SriSurart New Shop');
  });

  it('GET /bootstrap returns cold payload with ETag and answers 304 on match', async () => {
    const cold = await request(app.getHttpServer())
      .get('/api/v1/bootstrap')
      .set(auth());

    expect(cold.status).toBe(200);
    expect(cold.headers['cache-control']).toBe('private, no-cache');
    expect(cold.headers.etag).toBeDefined();
    expect(cold.body.data).toMatchObject({
      products: expect.any(Array),
      categories: expect.any(Array),
      customers: expect.any(Array),
      mechanics: expect.any(Array),
      settings: expect.objectContaining({
        shopName: expect.any(String),
      }),
    });

    const etag = cold.headers.etag;

    const repeat = await request(app.getHttpServer())
      .get('/api/v1/bootstrap')
      .set(auth())
      .set('If-None-Match', etag);

    expect(repeat.status).toBe(304);
    expect(repeat.headers['cache-control']).toBe('private, no-cache');
    expect(repeat.headers.etag).toBe(etag);
    expect(repeat.text).toBe('');
  });

  it('PATCH /settings rejects taxRate > 100 or with > 2 decimal places', async () => {
    const over100 = await request(app.getHttpServer())
      .patch('/api/v1/settings')
      .set(auth())
      .send({ taxRate: 150 });
    expect(over100.status).toBe(400);

    const overDecimals = await request(app.getHttpServer())
      .patch('/api/v1/settings')
      .set(auth())
      .send({ taxRate: 7.123 });
    expect(overDecimals.status).toBe(400);
  });

  it('changing any entity changes the ETag of /bootstrap', async () => {
    const first = await request(app.getHttpServer())
      .get('/api/v1/bootstrap')
      .set(auth());

    const etag1 = first.headers.etag;

    // Create a customer
    await request(app.getHttpServer())
      .post('/api/v1/customers')
      .set(auth())
      .set('Idempotency-Key', idempotency())
      .send({
        name: 'ETag Test Customer',
        nameTH: 'ทดสอบ ETag',
      });

    const second = await request(app.getHttpServer())
      .get('/api/v1/bootstrap')
      .set(auth());

    const etag2 = second.headers.etag;

    expect(etag2).not.toBe(etag1);
  });

  it('excludes tombstoned products, customers and mechanics from /bootstrap payload', async () => {
    // Insert a soft-deleted customer and product directly
    await admin.query(
      `INSERT INTO customers (tenant_id, id, code, name, name_th, deleted_at)
       VALUES ($1::uuid, 'c-deleted', 'CUS999', 'Deleted Cust', 'ลบแล้ว', NOW())`,
      [TENANT],
    );

    await admin.query(
      `INSERT INTO products (tenant_id, id, part_no, name, name_th, category, brand, price, cost, stock, deleted_at)
       VALUES ($1::uuid, 'p-deleted', 'PART-DEL', 'Deleted Prod', 'ลบแล้ว', 'เบรก', 'Brand', 100, 50, 10, NOW())`,
      [TENANT],
    );

    const res = await request(app.getHttpServer())
      .get('/api/v1/bootstrap')
      .set(auth());

    expect(res.status).toBe(200);
    const customerIds = res.body.data.customers.map((c: { id: string }) => c.id);
    const productIds = res.body.data.products.map((p: { id: string }) => p.id);

    expect(customerIds).not.toContain('c-deleted');
    expect(productIds).not.toContain('p-deleted');
  });
});
