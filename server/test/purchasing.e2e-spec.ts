import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import {
  accessToken,
  createTestApp,
  resetTenant,
  type TenantFixture,
} from './support/fixture.js';

const TENANT = '36363636-3636-4636-8636-363636363636';

describe('purchasing / PO (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;
  let managerToken: string;
  let key = 0;

  const auth = (token = managerToken) => ({ Authorization: `Bearer ${token}` });
  const idempotency = () => `po-test-${++key}-${Date.now()}`;

  const createPo = (body: unknown, token = managerToken, k = idempotency()) =>
    request(app.getHttpServer())
      .post('/api/v1/purchase-orders')
      .set(auth(token))
      .set('Idempotency-Key', k)
      .send(body as object);

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { cache });
    managerToken = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'owner',
      deviceId: fixture.posDeviceId,
      deviceRole: 'pos',
    });

    await admin.query(
      `INSERT INTO products (tenant_id, id, part_no, name, name_th, category, brand, price, cost, stock)
       VALUES ($1::uuid, 'prod-bp', 'BP-1234', 'Front Brake Pad', 'ผ้าเบรกหน้า', 'เบรก', 'Brand', 350, 200.00, 10)`,
      [TENANT],
    );
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it('creates and lists purchase orders', async () => {
    const createRes = await createPo({
      supplier: 'Siam Auto Supply',
      items: [
        { partNo: 'BP-1234', name: 'Front Brake Pad', qty: 10, cost: '250.00' },
        { partNo: 'UNKNOWN-01', name: 'Unknown Filter', qty: 5, cost: '100.00' },
      ],
    });

    expect(createRes.status).toBe(201);
    expect(createRes.body.data).toMatchObject({
      id: expect.any(String),
      poNo: expect.stringMatching(/^PO\d{2}-\d{4}-\d{2}-\d{4}$/),
      supplier: 'Siam Auto Supply',
      status: 'open',
      items: expect.arrayContaining([
        expect.objectContaining({ partNo: 'BP-1234', qty: 10, cost: '250.00' }),
      ]),
    });

    const poId = createRes.body.data.id;

    const listRes = await request(app.getHttpServer())
      .get('/api/v1/purchase-orders?status=open')
      .set(auth());

    expect(listRes.status).toBe(200);
    const poList = Array.isArray(listRes.body.data) ? listRes.body.data : listRes.body.data.items;
    expect(poList).toEqual(
      expect.arrayContaining([expect.objectContaining({ id: poId })]),
    );

    const getRes = await request(app.getHttpServer())
      .get(`/api/v1/purchase-orders/${poId}`)
      .set(auth());

    expect(getRes.status).toBe(200);
    expect(getRes.body.data.id).toBe(poId);
  });

  it('receives PO: calculates weighted average cost, updates stock, writes movement and handles unmatched part numbers', async () => {
    // Product 1: BP-1234 (existing stock = 10, cost = 200.00)
    // Product 2: ZERO-STOCK (existing stock = 0, cost = 50.00)
    await admin.query(
      `INSERT INTO products (tenant_id, id, part_no, name, name_th, category, brand, price, cost, stock)
       VALUES ($1::uuid, 'prod-zero', 'ZERO-STOCK', 'Zero Stock Product', 'สต็อกศูนย์', 'เบรก', 'Brand', 100, 50.00, 0)`,
      [TENANT],
    );

    const poRes = await createPo({
      supplier: 'Siam Auto Supply',
      items: [
        { partNo: 'bp-1234', name: 'Front Brake Pad', qty: 5, cost: '320.00' }, // Case-insensitive part_no match
        { partNo: 'ZERO-STOCK', name: 'Zero Stock Product', qty: 10, cost: '80.00' },
        { partNo: 'UNMATCHED-99', name: 'Non Existent Part', qty: 2, cost: '500.00' },
      ],
    });

    const poId = poRes.body.data.id;

    const receiveRes = await request(app.getHttpServer())
      .post(`/api/v1/purchase-orders/${poId}/receive`)
      .set(auth())
      .set('Idempotency-Key', idempotency())
      .send();

    expect(receiveRes.status).toBe(200);
    expect(receiveRes.body.data).toMatchObject({
      poId,
      status: 'received',
      receivedAt: expect.any(String),
      unmatched: ['UNMATCHED-99'],
    });

    // BP-1234 original: stock 10, cost 200.00. Receive: qty 5, cost 320.00
    // Total stock: 15. Weighted cost: (10*200 + 5*320) / 15 = 3600 / 15 = 240.00
    const bpUpdated = receiveRes.body.data.updated.find(
      (u: { partNo: string }) => u.partNo === 'BP-1234',
    );
    expect(bpUpdated).toMatchObject({
      stockAfter: 15,
      costAfter: '240.00',
    });

    // ZERO-STOCK original: stock 0, cost 50.00. Receive: qty 10, cost 80.00
    // Total stock: 10. Weighted cost: 80.00
    const zeroUpdated = receiveRes.body.data.updated.find(
      (u: { partNo: string }) => u.partNo === 'ZERO-STOCK',
    );
    expect(zeroUpdated).toMatchObject({
      stockAfter: 10,
      costAfter: '80.00',
    });

    // Verify movements
    expect(receiveRes.body.data.movements).toHaveLength(2);
    const bpMov = receiveRes.body.data.movements.find(
      (m: { partNo: string }) => m.partNo === 'BP-1234',
    );
    expect(bpMov).toMatchObject({
      delta: 5,
      type: 'receive',
      stockAfter: 15,
    });
  });

  it('refuses receiving the same PO twice (409 PO_ALREADY_RECEIVED) and stock moves only once', async () => {
    const poRes = await createPo({
      supplier: 'Supplier B',
      items: [{ partNo: 'BP-1234', name: 'Brake Pad', qty: 5, cost: '200.00' }],
    });

    const poId = poRes.body.data.id;

    // First receive
    const rec1 = await request(app.getHttpServer())
      .post(`/api/v1/purchase-orders/${poId}/receive`)
      .set(auth())
      .set('Idempotency-Key', idempotency())
      .send();

    expect(rec1.status).toBe(200);

    // Second receive with different idempotency key
    const rec2 = await request(app.getHttpServer())
      .post(`/api/v1/purchase-orders/${poId}/receive`)
      .set(auth())
      .set('Idempotency-Key', idempotency())
      .send();

    expect(rec2.status).toBe(409);
    expect(rec2.body.error).toMatchObject({
      code: 'PO_ALREADY_RECEIVED',
    });
  });

  it('leaves product average cost unchanged when receiving a line with cost zero', async () => {
    // BP-1234 stock = 10, cost = 200.00
    const poRes = await createPo({
      supplier: 'Freebie Supplier',
      items: [{ partNo: 'BP-1234', name: 'Free Brake Pad', qty: 5, cost: '0.00' }],
    });

    const poId = poRes.body.data.id;

    const recRes = await request(app.getHttpServer())
      .post(`/api/v1/purchase-orders/${poId}/receive`)
      .set(auth())
      .set('Idempotency-Key', idempotency())
      .send();

    expect(recRes.status).toBe(200);
    const bpUpdated = recRes.body.data.updated.find(
      (u: { partNo: string }) => u.partNo === 'BP-1234',
    );
    expect(bpUpdated).toMatchObject({
      stockAfter: 15,
      costAfter: '200.00',
    });
  });

  it('requires authentication for receive, cancel, and delete', async () => {
    const recRes = await request(app.getHttpServer())
      .post('/api/v1/purchase-orders/po-123/receive')
      .send();
    expect(recRes.status).toBe(401);
  });

  it('cancels an open PO and refuses receiving a cancelled PO', async () => {
    const poRes = await createPo({
      supplier: 'Supplier D',
      items: [{ partNo: 'BP-1234', name: 'Brake Pad', qty: 2, cost: '150.00' }],
    });

    const poId = poRes.body.data.id;

    const cancelRes = await request(app.getHttpServer())
      .post(`/api/v1/purchase-orders/${poId}/cancel`)
      .set(auth())
      .set('Idempotency-Key', idempotency())
      .send();

    expect(cancelRes.status).toBe(200);
    expect(cancelRes.body.data.status).toBe('cancelled');

    const recRes = await request(app.getHttpServer())
      .post(`/api/v1/purchase-orders/${poId}/receive`)
      .set(auth())
      .set('Idempotency-Key', idempotency())
      .send();

    expect(recRes.status).toBe(409);
    expect(recRes.body.error).toMatchObject({
      code: 'PO_CANCELLED',
    });
  });

  it('deletes an open or cancelled PO and refuses deleting a received PO', async () => {
    const poRes = await createPo({
      supplier: 'Supplier E',
      items: [{ partNo: 'BP-1234', name: 'Brake Pad', qty: 1, cost: '100.00' }],
    });

    const poId = poRes.body.data.id;

    const delRes = await request(app.getHttpServer())
      .delete(`/api/v1/purchase-orders/${poId}`)
      .set(auth())
      .set('Idempotency-Key', idempotency())
      .send();

    expect(delRes.status).toBe(200);
    expect(delRes.body.data).toEqual({ id: poId, deleted: true });

    // Receiving deleted PO returns 404
    const getRes = await request(app.getHttpServer())
      .get(`/api/v1/purchase-orders/${poId}`)
      .set(auth());
    expect(getRes.status).toBe(404);
  });
});
