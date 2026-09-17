import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import type { Redis } from 'ioredis';
import { randomUUID } from 'node:crypto';
import {
  createTestApp,
  resetTenant,
  accessToken,
  seedProduct,
  seedOpenShift,
  type TenantFixture,
} from './support/fixture.js';
import { TENANT_SCOPED_TABLES } from '../src/db/migrations/1788652800001-RowLevelSecurity.js';

describe('Cross-Tenant Data Isolation E2E (DoD line 2, 03_ARCHITECTURE.md §8)', () => {
  const TENANT_A = '11111111-aaaa-4aaa-8aaa-111111111111';
  const TENANT_B = '22222222-bbbb-4bbb-8bbb-222222222222';

  let app: INestApplication;
  let ds: DataSource;
  let admin: DataSource;
  let cache: Redis;
  let fixtureA: TenantFixture;
  let fixtureB: TenantFixture;
  let tokenA: string;
  let tokenB: string;

  beforeAll(async () => {
    ({ app, ds, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixtureA = await resetTenant(admin, TENANT_A, { cache });
    fixtureB = await resetTenant(admin, TENANT_B, { cache });

    tokenA = accessToken({
      tenantId: TENANT_A,
      userId: fixtureA.userId,
      role: 'owner',
      deviceId: fixtureA.posDeviceId,
      deviceRole: 'pos',
    });

    tokenB = accessToken({
      tenantId: TENANT_B,
      userId: fixtureB.userId,
      role: 'owner',
      deviceId: fixtureB.posDeviceId,
      deviceRole: 'pos',
    });
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT_A, { cache });
    await resetTenant(admin, TENANT_B, { cache });
    await admin.query(`DELETE FROM tenants WHERE id IN ($1::uuid, $2::uuid)`, [
      TENANT_A,
      TENANT_B,
    ]);
    await app?.close();
  });

  const http = () => request(app.getHttpServer());

  describe('Database RLS Policy Sweep (All 25 tables in TENANT_SCOPED_TABLES)', () => {
    it('with app.tenant_id = TENANT_A, pos_app reads ZERO rows for TENANT_B across ALL tables', async () => {
      const qr = ds.createQueryRunner();
      await qr.connect();
      try {
        await qr.startTransaction();
        await qr.query(`SELECT set_config('app.tenant_id', $1, true)`, [TENANT_A]);

        for (const table of TENANT_SCOPED_TABLES) {
          const rows = await qr.query(
            `SELECT count(*)::int AS n FROM ${table} WHERE tenant_id = $1::uuid`,
            [TENANT_B],
          );
          expect(rows[0].n, `table ${table} leaked rows from Tenant B`).toBe(0);
        }

        await qr.rollbackTransaction();
      } finally {
        await qr.release();
      }
    });

    it('with app.tenant_id unset, pos_app reads ZERO rows across ALL tables in TENANT_SCOPED_TABLES', async () => {
      const qr = ds.createQueryRunner();
      await qr.connect();
      try {
        for (const table of TENANT_SCOPED_TABLES) {
          const rows = await qr.query(`SELECT count(*)::int AS n FROM ${table}`);
          expect(rows[0].n, `table ${table} returned rows with unset tenant`).toBe(0);
        }
      } finally {
        await qr.release();
      }
    });
  });

  describe('HTTP API Cross-Tenant Isolation (0 rows / 404 in every domain read)', () => {
    it('products: Tenant A cannot read Tenant B products in list or by ID (404)', async () => {
      await seedProduct(admin, TENANT_B, {
        id: 'p-tb-1',
        partNo: 'TB-01',
        name: 'Tenant B Part',
        price: 200,
        cost: 100,
        stock: 15,
      });

      // Tenant A list
      const listRes = await http().get('/api/v1/products').set('Authorization', `Bearer ${tokenA}`);
      expect(listRes.status).toBe(200);
      const foundInList = (listRes.body.data as { id: string }[]).find((p) => p.id === 'p-tb-1');
      expect(foundInList).toBeUndefined();

      // Tenant A get by ID -> 404
      const getRes = await http().get('/api/v1/products/p-tb-1').set('Authorization', `Bearer ${tokenA}`);
      expect(getRes.status).toBe(404);
    });

    it('categories: Tenant A list does not include Tenant B custom categories', async () => {
      await admin.query(
        `INSERT INTO categories (tenant_id, name, position) VALUES ($1::uuid, $2, 99)`,
        [TENANT_B, 'หมวดเฉพาะร้านบี'],
      );

      const res = await http().get('/api/v1/categories').set('Authorization', `Bearer ${tokenA}`);
      expect(res.status).toBe(200);
      const found = (res.body.data as { name: string }[]).find((c) => c.name === 'หมวดเฉพาะร้านบี');
      expect(found).toBeUndefined();
    });

    it('customers: Tenant A cannot list or read Tenant B customers (404)', async () => {
      const custRes = await http()
        .post('/api/v1/customers')
        .set('Authorization', `Bearer ${tokenB}`)
        .set('Idempotency-Key', `k-cust-b-${randomUUID()}`)
        .send({ name: 'Walk-in B', nameTH: 'ลูกค้า B', phone: '0812345678' });
      expect(custRes.status).toBe(201);
      const custIdB = custRes.body.data.id;

      // Tenant A list
      const listRes = await http().get('/api/v1/customers').set('Authorization', `Bearer ${tokenA}`);
      expect(listRes.status).toBe(200);
      const foundInList = (listRes.body.data as { id: string }[]).find((c) => c.id === custIdB);
      expect(foundInList).toBeUndefined();

      // Tenant A get by ID -> 404
      const getRes = await http().get(`/api/v1/customers/${custIdB}`).set('Authorization', `Bearer ${tokenA}`);
      expect(getRes.status).toBe(404);
    });

    it('mechanics: Tenant A cannot list or read Tenant B mechanics (404)', async () => {
      const mechRes = await http()
        .post('/api/v1/mechanics')
        .set('Authorization', `Bearer ${tokenB}`)
        .set('Idempotency-Key', `k-mech-b-${randomUUID()}`)
        .send({ name: 'ช่าง B', phone: '0899999999' });
      expect(mechRes.status).toBe(201);
      const mechIdB = mechRes.body.data.id;

      // Tenant A list
      const listRes = await http().get('/api/v1/mechanics').set('Authorization', `Bearer ${tokenA}`);
      expect(listRes.status).toBe(200);
      const foundInList = (listRes.body.data as { id: string }[]).find((m) => m.id === mechIdB);
      expect(foundInList).toBeUndefined();

      // Tenant A get by ID -> 404
      const getRes = await http().get(`/api/v1/mechanics/${mechIdB}`).set('Authorization', `Bearer ${tokenA}`);
      expect(getRes.status).toBe(404);
    });

    it('sales: Tenant A cannot list or read Tenant B sales (404)', async () => {
      await seedProduct(admin, TENANT_B, {
        id: 'p-sale-b',
        partNo: 'PS-B',
        name: 'Sale Part B',
        price: 300,
        cost: 150,
        stock: 10,
      });
      await seedOpenShift(admin, TENANT_B, fixtureB.posDeviceId, { userId: fixtureB.userId });

      const saleIdB = `sale-b-${randomUUID()}`;
      const saleRes = await http()
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${tokenB}`)
        .set('Idempotency-Key', `k-sale-b-${randomUUID()}`)
        .send({
          id: saleIdB,
          subtotal: '300.00',
          discount: '0.00',
          total: '300.00',
          paymentMethod: 'เงินสด',
          items: [
            {
              lineNo: 1,
              productId: 'p-sale-b',
              name: 'Sale Part B',
              qty: 1,
              price: '300.00',
            },
          ],
        });
      expect(saleRes.status).toBe(201);

      // Tenant A list
      const listRes = await http().get('/api/v1/sales').set('Authorization', `Bearer ${tokenA}`);
      expect(listRes.status).toBe(200);
      const foundInList = (listRes.body.data as { id: string }[]).find((s) => s.id === saleIdB);
      expect(foundInList).toBeUndefined();

      // Tenant A get by ID -> 404
      const getRes = await http().get(`/api/v1/sales/${saleIdB}`).set('Authorization', `Bearer ${tokenA}`);
      expect(getRes.status).toBe(404);
    });

    it('returns: Tenant A cannot list or read Tenant B returns (404)', async () => {
      await seedProduct(admin, TENANT_B, {
        id: 'p-ret-b',
        partNo: 'PR-B',
        name: 'Return Part B',
        price: 200,
        cost: 100,
        stock: 10,
      });
      await seedOpenShift(admin, TENANT_B, fixtureB.posDeviceId, { userId: fixtureB.userId });

      const saleIdB = `sale-for-ret-b-${randomUUID()}`;
      await http()
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${tokenB}`)
        .set('Idempotency-Key', `k-sale-ret-b-${randomUUID()}`)
        .send({
          id: saleIdB,
          subtotal: '200.00',
          discount: '0.00',
          total: '200.00',
          paymentMethod: 'เงินสด',
          items: [{ lineNo: 1, productId: 'p-ret-b', name: 'Return Part B', qty: 1, price: '200.00' }],
        });

      const retRes = await http()
        .post('/api/v1/returns')
        .set('Authorization', `Bearer ${tokenB}`)
        .set('Idempotency-Key', `k-ret-b-${randomUUID()}`)
        .send({
          saleId: saleIdB,
          refundMethod: 'เงินสด',
          items: [{ productId: 'p-ret-b', name: 'Return Part B', qty: 1, price: '200.00' }],
        });
      expect(retRes.status).toBe(201);
      const returnIdB = retRes.body.data.id;

      // Tenant A list
      const listRes = await http().get('/api/v1/returns').set('Authorization', `Bearer ${tokenA}`);
      expect(listRes.status).toBe(200);
      const foundInList = (listRes.body.data as { id: string }[]).find((r) => r.id === returnIdB);
      expect(foundInList).toBeUndefined();

      // Tenant A get by ID -> 404
      const getRes = await http().get(`/api/v1/returns/${returnIdB}`).set('Authorization', `Bearer ${tokenA}`);
      expect(getRes.status).toBe(404);
    });

    it('purchase_orders: Tenant A cannot list or read Tenant B purchase orders (404)', async () => {
      const poRes = await http()
        .post('/api/v1/purchase-orders')
        .set('Authorization', `Bearer ${tokenB}`)
        .set('Idempotency-Key', `k-po-b-${randomUUID()}`)
        .send({
          supplier: 'Acme B',
          items: [{ partNo: 'TEST-B', name: 'Widget B', qty: 5, cost: '50.00' }],
        });
      expect(poRes.status).toBe(201);
      const poIdB = poRes.body.data.id;

      // Tenant A list
      const listRes = await http().get('/api/v1/purchase-orders').set('Authorization', `Bearer ${tokenA}`);
      expect(listRes.status).toBe(200);
      const foundInList = (listRes.body.data as { id: string }[]).find((po) => po.id === poIdB);
      expect(foundInList).toBeUndefined();

      // Tenant A get by ID -> 404
      const getRes = await http().get(`/api/v1/purchase-orders/${poIdB}`).set('Authorization', `Bearer ${tokenA}`);
      expect(getRes.status).toBe(404);
    });

    it('quotes: Tenant A cannot list or read Tenant B quotes (404)', async () => {
      const qtRes = await http()
        .post('/api/v1/quotes')
        .set('Authorization', `Bearer ${tokenB}`)
        .set('Idempotency-Key', `k-qt-b-${randomUUID()}`)
        .send({
          customerName: 'ลูกค้าใบเสนอราคา B',
          subtotal: '500.00',
          discount: '0.00',
          total: '500.00',
          items: [{ lineNo: 1, partNo: 'Q-01', name: 'Quote Part B', qty: 1, price: '500.00' }],
        });
      expect(qtRes.status).toBe(201);
      const quoteIdB = qtRes.body.data.id;

      // Tenant A list
      const listRes = await http().get('/api/v1/quotes').set('Authorization', `Bearer ${tokenA}`);
      expect(listRes.status).toBe(200);
      const foundInList = (listRes.body.data as { id: string }[]).find((q) => q.id === quoteIdB);
      expect(foundInList).toBeUndefined();

      // Tenant A get by ID -> 404
      const getRes = await http().get(`/api/v1/quotes/${quoteIdB}`).set('Authorization', `Bearer ${tokenA}`);
      expect(getRes.status).toBe(404);
    });

    it('parked_sales: Tenant A cannot list or read Tenant B parked sales (404)', async () => {
      const pkRes = await http()
        .post('/api/v1/parked-sales')
        .set('Authorization', `Bearer ${tokenB}`)
        .set('Idempotency-Key', `k-pk-b-${randomUUID()}`)
        .send({
          payload: {
            label: 'พักบิล B',
            subtotal: '250.00',
            discount: '0.00',
            total: '250.00',
            items: [{ lineNo: 1, partNo: 'PK-01', name: 'Parked Part B', qty: 1, price: '250.00' }],
          },
        });
      expect(pkRes.status).toBe(201);
      const parkedIdB = pkRes.body.data.id;

      // Tenant A list
      const listRes = await http().get('/api/v1/parked-sales').set('Authorization', `Bearer ${tokenA}`);
      expect(listRes.status).toBe(200);
      const foundInList = (listRes.body.data as { id: string }[]).find((p) => p.id === parkedIdB);
      expect(foundInList).toBeUndefined();

      // Tenant A delete -> 404
      const delRes = await http()
        .delete(`/api/v1/parked-sales/${parkedIdB}`)
        .set('Authorization', `Bearer ${tokenA}`)
        .set('Idempotency-Key', `k-del-pk-${randomUUID()}`);
      expect(delRes.status).toBe(404);
    });

    it('shifts: Tenant A cannot see Tenant B shifts in history', async () => {
      await seedOpenShift(admin, TENANT_B, fixtureB.posDeviceId, { userId: fixtureB.userId });

      const res = await http().get('/api/v1/shifts/history').set('Authorization', `Bearer ${tokenA}`);
      expect(res.status).toBe(200);
      const found = (res.body.data as { tenantId?: string }[]).find((s) => s.tenantId === TENANT_B);
      expect(found).toBeUndefined();
    });

    it('devices: Tenant A cannot see Tenant B devices', async () => {
      const res = await http().get('/api/v1/devices').set('Authorization', `Bearer ${tokenA}`);
      expect(res.status).toBe(200);
      const found = (res.body.data as { id: string }[]).find((d) => d.id === fixtureB.posDeviceId);
      expect(found).toBeUndefined();
    });

    it('settings: Tenant A reads only its own shop settings', async () => {
      const res = await http().get('/api/v1/settings').set('Authorization', `Bearer ${tokenA}`);
      expect(res.status).toBe(200);
      expect(res.body.data.shopName).not.toBe('ร้าน B');
    });
  });
});
