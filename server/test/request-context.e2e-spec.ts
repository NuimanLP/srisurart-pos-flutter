import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import { accessToken, createTestApp, resetTenant, type TenantFixture } from './support/fixture.js';

// The seam itself: which routes get a request transaction, and what happens on the
// paths that never reach the interceptor that commits it.
const TENANT = '22222222-8888-4888-8888-222222222222';

describe('the request-context seam (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let ds: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;
  let token: string;

  /** Connections `pos_app` currently holds. A leak shows up here and nowhere else. */
  const openConnections = async (): Promise<number> => {
    const rows = await admin.query(
      `SELECT count(*)::int AS n FROM pg_stat_activity
        WHERE usename = 'pos_app' AND datname = current_database()`,
    );
    return rows[0].n as number;
  };

  beforeAll(async () => {
    ({ app, admin, ds, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { cache });
    token = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'manager',
      deviceId: fixture.posDeviceId,
      deviceRole: 'pos',
    });
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it('serves GET /auth/me, which is the one auth route that carries the guard', async () => {
    // The middleware is registered for this path by name, not by controller — a
    // mistyped path would leave the guard with no transaction and 500 every call.
    const res = await request(app.getHttpServer())
      .get('/api/v1/auth/me')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.data.tenantId).toBe(TENANT);
    expect(res.body.data.deviceRole).toBe('pos');
  });

  it('serves POST /auth/token, which has no guard and needs no transaction', async () => {
    // Wrong credentials on purpose: what is under test is that the route answers at
    // all without a request transaction, not that a login succeeds.
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/token')
      .send({ username: 'tester', password: 'wrong' });

    expect(res.status).toBe(401);
    expect(res.body.status).toBe('error');

    // ADR-0009: every `/auth/*` endpoint writes `audit_log`, failures included. That
    // write goes through its own `set_config('app.tenant_id', …)` — `SET LOCAL … = $1`
    // takes no bind parameter and was failing silently into a catch, so the auth trail
    // was empty.
    const rows = await admin.query(
      `SELECT count(*)::int AS n FROM audit_log
        WHERE tenant_id = $1::uuid AND action LIKE 'auth.%'`,
      [TENANT],
    );
    expect(rows[0].n).toBeGreaterThan(0);
  });

  it('returns every connection it takes, including on the paths that never reach the handler', async () => {
    const before = await openConnections();

    for (let i = 0; i < 12; i++) {
      // A guard that throws returns before any interceptor runs, so nothing in the
      // interceptor chain ends the transaction the middleware opened. If the
      // response-close backstop did not, this loop would drain the pool.
      await request(app.getHttpServer()).get('/api/v1/sales').expect(401);
      await request(app.getHttpServer())
        .get('/api/v1/sales')
        .set('Authorization', 'Bearer not-a-token')
        .expect(401);
      // And the ordinary path, which the interceptor does end.
      await request(app.getHttpServer())
        .get('/api/v1/sales')
        .set('Authorization', `Bearer ${token}`)
        .expect(200);
    }

    // Give the backstop's async rollback a moment to land — it runs off the response's
    // own `close` event, after the response has been written.
    await new Promise((resolve) => setTimeout(resolve, 250));
    // The pool keeps idle connections, so this is not "back to zero"; what matters is
    // that 36 requests did not each strand one.
    expect(await openConnections()).toBeLessThanOrEqual(before + 4);
  });

  it('a suspended shop is refused before its tenant is ever named on a transaction', async () => {
    await admin.query(`UPDATE tenants SET status = 'suspended' WHERE id = $1::uuid`, [
      TENANT,
    ]);
    const res = await request(app.getHttpServer())
      .get('/api/v1/sales')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('TENANT_SUSPENDED');
    await admin.query(`UPDATE tenants SET status = 'active' WHERE id = $1::uuid`, [TENANT]);
  });

  it('rolls the whole request back when the handler throws after writing', async () => {
    // A bill that passes validation and stock, then dies on the foreign key: the
    // deduction and the receipt number are already written when it does.
    const before = await admin.query(
      `SELECT last_no FROM doc_counters WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    await admin.query(
      `INSERT INTO products (tenant_id, id, part_no, name, name_th, category, brand, price, cost, stock)
            VALUES ($1::uuid, 'p1', 'X-1', 'Widget', 'วิดเจ็ต', 'อื่นๆ', 'T', 10, 5, 9)`,
      [TENANT],
    );

    const res = await request(app.getHttpServer())
      .post('/api/v1/sales')
      .set('Authorization', `Bearer ${token}`)
      .set('Idempotency-Key', `k-rollback-${Date.now()}`)
      .send({
        id: `s-rollback-${Date.now()}`,
        subtotal: '10.00',
        discount: '0.00',
        total: '10.00',
        paymentMethod: 'เงินสด',
        customerId: 'nobody',
        items: [{ lineNo: 1, productId: 'p1', name: 'Widget', qty: 1, price: '10.00' }],
      });
    expect(res.status).toBe(400);

    const stock = await admin.query(
      `SELECT stock FROM products WHERE tenant_id = $1::uuid AND id = 'p1'`,
      [TENANT],
    );
    expect(stock[0].stock).toBe(9);
    const after = await admin.query(
      `SELECT last_no FROM doc_counters WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    // The receipt number went back too, so the printed series has no visible hole.
    expect(after).toEqual(before);
    const keys = await admin.query(
      `SELECT count(*)::int AS n FROM idempotency_keys WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    expect(keys[0].n).toBe(0);
  });

  it('shows a route nothing else can reach the tenant without the guard', async () => {
    // `pos_app` on a connection with no `app.tenant_id` reads zero rows rather than
    // erroring — the fail-closed property the whole seam rests on.
    const qr = ds.createQueryRunner();
    await qr.connect();
    try {
      const rows = await qr.query(`SELECT count(*)::int AS n FROM sales`);
      expect(rows[0].n).toBe(0);
    } finally {
      await qr.release();
    }
  });
});
