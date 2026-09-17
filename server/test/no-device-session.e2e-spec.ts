import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import { hashPassword } from '../src/common/password.js';
import {
  createTestApp,
  resetTenant,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';

// #297: dod.6 `test.no-device-session`
// Verifies ADR-0004 device enforcement:
// A user logged in without a deviceToken receives a token with did=undefined and drole=undefined.
// This session can read resources (e.g. GET /products) but cannot touch money/stock (e.g. POST /sales -> 403 DEVICE_ROLE_FORBIDDEN),
// and leaves the database completely untouched.
const TENANT = '29729729-2970-4297-8297-297297297297';
const PASSWORD = 'device-flow-297';

describe('no-device session (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;

  // One address per run: the login IP bucket is shared by every suite on 127.0.0.1.
  const ip = `203.0.113.${Math.floor(Math.random() * 250) + 1}`;

  const product = {
    id: 'p-297',
    partNo: 'PN-297',
    name: 'Product 297',
    price: 100,
    cost: 50,
    stock: 10,
  };

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { cache });
    await admin.query(
      `UPDATE users SET password_hash = $3, role = 'owner' WHERE tenant_id = $1::uuid AND id = $2::uuid`,
      [TENANT, fixture.userId, await hashPassword(PASSWORD)],
    );
    await seedProduct(admin, TENANT, product);
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT, { cache });
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it('authenticates without a device token and is forbidden from making sales', async () => {
    // 1. Real tokenless login via POST /api/v1/auth/token
    const loginRes = await request(app.getHttpServer())
      .post('/api/v1/auth/token')
      .set('X-Forwarded-For', ip)
      .send({ username: fixture.username, password: PASSWORD });

    expect(loginRes.status).toBe(200);
    const accessToken = loginRes.body.data.accessToken as string;
    expect(accessToken).toBeDefined();

    // 2. Decode returned accessToken and assert did and drole are undefined
    const payload = JSON.parse(
      Buffer.from(accessToken.split('.')[1], 'base64').toString(),
    ) as {
      sub: string;
      tid: string;
      role: string;
      did?: string;
      drole?: string;
    };
    expect(payload.did).toBeUndefined();
    expect(payload.drole).toBeUndefined();
    expect(payload.role).toBe('owner');
    expect(payload.tid).toBe(TENANT);

    // 3. GET /products with this token succeeds and includes the seeded product
    const productsRes = await request(app.getHttpServer())
      .get('/api/v1/products')
      .set('Authorization', `Bearer ${accessToken}`);

    expect(productsRes.status).toBe(200);
    const items = Array.isArray(productsRes.body.data)
      ? productsRes.body.data
      : (productsRes.body.data?.items as unknown[]);
    expect(items).toEqual(
      expect.arrayContaining([expect.objectContaining({ id: product.id })]),
    );

    // Record counters before sale attempt
    const countersBefore = await admin.query(
      `SELECT * FROM doc_counters WHERE tenant_id = $1::uuid`,
      [TENANT],
    );

    // 4. POST /sales with the tokenless session must return 403 DEVICE_ROLE_FORBIDDEN
    const idemKey = `k-no-device-${Date.now()}`;
    const saleBody = {
      id: 'sa-no-device-test',
      subtotal: '100.00',
      discount: '0.00',
      total: '100.00',
      paymentMethod: 'เงินสด',
      received: '100.00',
      items: [
        {
          lineNo: 1,
          productId: product.id,
          name: product.name,
          qty: 1,
          price: '100.00',
        },
      ],
    };

    const saleRes = await request(app.getHttpServer())
      .post('/api/v1/sales')
      .set('Authorization', `Bearer ${accessToken}`)
      .set('Idempotency-Key', idemKey)
      .send(saleBody);

    expect(saleRes.status).toBe(403);
    expect(saleRes.body.error?.code).toBe('DEVICE_ROLE_FORBIDDEN');
    expect(saleRes.body.error?.message).toBe('เครื่องนี้ขายของไม่ได้');

    // 5. Prove DB is untouched:
    // - No sales row with id 'sa-no-device-test'
    const salesRows = await admin.query(
      `SELECT count(*)::int AS n FROM sales WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, 'sa-no-device-test'],
    );
    expect(salesRows[0].n).toBe(0);

    // - No idempotency_keys row for that key
    const idemRows = await admin.query(
      `SELECT count(*)::int AS n FROM idempotency_keys WHERE tenant_id = $1::uuid AND key = $2`,
      [TENANT, idemKey],
    );
    expect(idemRows[0].n).toBe(0);

    // - No doc_counters changes for tenant
    const countersAfter = await admin.query(
      `SELECT * FROM doc_counters WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    expect(countersAfter).toEqual(countersBefore);
  });
});
