import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import type { Redis } from 'ioredis';
import { randomUUID } from 'node:crypto';
import { signJwt } from '../src/common/jwt.js';
import { hashPassword } from '../src/common/password.js';
import { APP_CONFIG, type AppConfig } from '../src/config/config.js';
import { createTestApp } from './support/fixture.js';

describe('Platform Realm E2E & Atomic Audit Invariants (#123)', () => {
  let app: INestApplication;
  let adminDs: DataSource;
  let cache: Redis;
  let config: AppConfig;
  let adminId: string;
  let adminToken: string;

  beforeAll(async () => {
    ({ app, admin: adminDs, cache } = await createTestApp());
    config = app.get<AppConfig>(APP_CONFIG);
  });

  afterAll(async () => {
    await app?.close();
  });

  beforeEach(async () => {
    adminId = randomUUID();
    const passHash = await hashPassword('platform-secret-123');

    // Seed platform admin into platform_admins
    await adminDs.query(
      `INSERT INTO platform_admins (id, username, password_hash, display_name, is_active)
       VALUES ($1, $2, $3, $4, true)`,
      [adminId, `admin-${adminId.slice(0, 8)}`, passHash, 'Super Admin'],
    );

    adminToken = signJwt(
      {
        iss: 'srisurart-pos',
        aud: 'platform',
        sub: adminId,
        username: `admin-${adminId.slice(0, 8)}`,
      },
      config.jwtPlatformSecret,
    );
  });

  afterEach(async () => {
    // Clean up cached keys and admin
    await cache.del(`pa:${adminId}:exists`);
    await adminDs.query(`DELETE FROM audit_log WHERE platform_admin_id = $1`, [adminId]);
    await adminDs.query(`DELETE FROM platform_admins WHERE id = $1`, [adminId]);
  });

  describe('PlatformAuthGuard DB validation & Redis caching (AC3)', () => {
    it('allows requests when platform admin exists and caches result in Redis with 60s TTL', async () => {
      const res = await request(app.getHttpServer())
        .get('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${adminToken}`);

      expect(res.status).toBe(200);

      // Verify cached in Redis
      const cached = await cache.get(`pa:${adminId}:exists`);
      expect(cached).toBe('1');
      const ttl = await cache.ttl(`pa:${adminId}:exists`);
      expect(ttl).toBeGreaterThan(0);
      expect(ttl).toBeLessThanOrEqual(60);
    });

    it('rejects with 401 when platform admin does not exist in platform_admins', async () => {
      const nonExistentAdminId = randomUUID();
      const orphanToken = signJwt(
        {
          iss: 'srisurart-pos',
          aud: 'platform',
          sub: nonExistentAdminId,
          username: 'ghost-admin',
        },
        config.jwtPlatformSecret,
      );

      const res = await request(app.getHttpServer())
        .get('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${orphanToken}`);

      expect(res.status).toBe(401);
      expect(res.body.error.message).toContain('Platform admin does not exist or is inactive');

      // Redis should have cached '0'
      const cached = await cache.get(`pa:${nonExistentAdminId}:exists`);
      expect(cached).toBe('0');
      await cache.del(`pa:${nonExistentAdminId}:exists`);
    });

    it('rejects a tenant create with 401 once the admin is deleted, and writes no tenant', async () => {
      await adminDs.query(`DELETE FROM platform_admins WHERE id = $1`, [adminId]);
      await cache.del(`pa:${adminId}:exists`);
      const code = `gone-${randomUUID().slice(0, 8)}`;

      const res = await request(app.getHttpServer())
        .post('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${adminToken}`)
        .send({ code, shopName: 'ร้านทดสอบ', ownerUsername: `owner_${code}`, ownerPassword: 'password-123456' });

      expect(res.status).toBe(401);
      const tenantRows = await adminDs.query(`SELECT id FROM tenants WHERE code = $1`, [code]);
      expect(tenantRows.length).toBe(0);
    });

    it('rejects with 401 when platform admin is marked inactive', async () => {
      await adminDs.query(`UPDATE platform_admins SET is_active = false WHERE id = $1`, [adminId]);
      await cache.del(`pa:${adminId}:exists`);

      const res = await request(app.getHttpServer())
        .get('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${adminToken}`);

      expect(res.status).toBe(401);
      expect(res.body.error.message).toContain('Platform admin does not exist or is inactive');
    });
  });

  describe('PlatformAuthGuard IP allowlist (Slice 24 / #270)', () => {
    it('rejects with 403 when hitting API directly from an IP outside the allowlist', async () => {
      const res = await request(app.getHttpServer())
        .get('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${adminToken}`)
        .set('X-Forwarded-For', '203.0.113.195');

      expect(res.status).toBe(403);
      expect(res.body.error.code).toBe('PLATFORM_IP_FORBIDDEN');
      expect(res.body.error.message).toContain('IP not allowed for platform admin access');
    });

    it('allows request from loopback IP', async () => {
      const res = await request(app.getHttpServer())
        .get('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${adminToken}`)
        .set('X-Forwarded-For', '127.0.0.1');

      expect(res.status).toBe(200);
    });

    it('allows request from configured admin IP', async () => {
      config.platformAdminIps = ['198.51.100.50'];
      try {
        const res = await request(app.getHttpServer())
          .get('/api/v1/platform/tenants')
          .set('Authorization', `Bearer ${adminToken}`)
          .set('X-Forwarded-For', '198.51.100.50');

        expect(res.status).toBe(200);
      } finally {
        delete config.platformAdminIps;
      }
    });
  });

  describe('Atomic Audit Logging in createTenant (AC2)', () => {
    it('creates tenant and writes audit log atomically inside the same transaction', async () => {
      const code = `t-${randomUUID().slice(0, 8)}`;
      const res = await request(app.getHttpServer())
        .post('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${adminToken}`)
        .send({
          code,
          shopName: 'ร้านทดสอบ อะตอมมิก',
          ownerUsername: `owner_${code}`,
          ownerPassword: 'password-123456',
          ownerDisplayName: 'เจ้าของร้าน',
        });

      expect(res.status).toBe(201);
      expect(res.body.data.tenantId).toBeDefined();
      const tenantId = res.body.data.tenantId;

      // Verify audit_log entry was written
      const auditRows = await adminDs.query(
        `SELECT * FROM audit_log WHERE tenant_id = $1 AND action = 'platform.tenant.create'`,
        [tenantId],
      );
      expect(auditRows.length).toBe(1);
      expect(auditRows[0].platform_admin_id).toBe(adminId);

      // Clean up tenant
      await adminDs.query(`DELETE FROM audit_log WHERE tenant_id = $1`, [tenantId]);
      await adminDs.query(`DELETE FROM devices WHERE tenant_id = $1`, [tenantId]);
      await adminDs.query(`DELETE FROM categories WHERE tenant_id = $1`, [tenantId]);
      await adminDs.query(`DELETE FROM settings WHERE tenant_id = $1`, [tenantId]);
      await adminDs.query(`DELETE FROM users WHERE tenant_id = $1`, [tenantId]);
      await adminDs.query(`DELETE FROM tenants WHERE id = $1`, [tenantId]);
    });

    it('rolls back tenant creation completely when audit log fails (e.g. FK violation on platform_admin_id)', async () => {
      // In this test, we verify that if the audit log query fails inside the transaction,
      // the entire transaction rolls back and no tenant or user remains.
      const code = `rollback-${randomUUID().slice(0, 8)}`;

      // Use a token with a deleted platform admin, but bypass the guard check by pre-populating the Redis cache with '1'
      const deletedAdminId = randomUUID();
      await cache.setex(`pa:${deletedAdminId}:exists`, 60, '1');

      const deletedAdminToken = signJwt(
        {
          iss: 'srisurart-pos',
          aud: 'platform',
          sub: deletedAdminId,
          username: 'deleted-admin',
        },
        config.jwtPlatformSecret,
      );

      const res = await request(app.getHttpServer())
        .post('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${deletedAdminToken}`)
        .send({
          code,
          shopName: 'ร้านทดสอบ โรลแบ็ค',
          ownerUsername: `owner_${code}`,
          ownerPassword: 'password-123456',
          ownerDisplayName: 'เจ้าของร้าน',
        });

      // Audit insertion must fail on foreign key constraint `audit_log_platform_admin_id_fkey`
      expect(res.status).toBe(500);

      // Ground-truth check: Ensure NO tenant was created and the code is NOT reserved
      const tenantRows = await adminDs.query(`SELECT id FROM tenants WHERE code = $1`, [code]);
      expect(tenantRows.length).toBe(0);

      const userRows = await adminDs.query(`SELECT id FROM users WHERE username = $1`, [`owner_${code}`]);
      expect(userRows.length).toBe(0);

      await cache.del(`pa:${deletedAdminId}:exists`);
    });
  });

  // #364 — `ownerPassword` used to be checked only for presence, so `1234` provisioned a
  // shop `owner` (the highest-privileged login in that tenant). The floor is now the one
  // `bootstrap:admin` uses, from the same function (`common/password.ts`), and it is
  // applied before the argon2 hash and before the transaction opens — so a refusal must
  // leave nothing behind at all.
  describe('ownerPassword length policy (#364)', () => {
    const provision = (code: string, ownerPassword: unknown) =>
      request(app.getHttpServer())
        .post('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${adminToken}`)
        .send({
          code,
          shopName: 'ร้านทดสอบ รหัสผ่าน',
          ownerUsername: `owner_${code}`,
          ownerDisplayName: 'เจ้าของร้าน',
          // `undefined` is dropped by supertest's JSON encoder, which is exactly the
          // "field absent" case we want to cover.
          ...(ownerPassword === undefined ? {} : { ownerPassword }),
        });

    /** Ground truth: a refusal may not leave a tenant, an owner row or an audit row. */
    const expectNothingPersisted = async (code: string) => {
      const tenants = await adminDs.query(`SELECT id FROM tenants WHERE code = $1`, [code]);
      expect(tenants.length).toBe(0);
      const users = await adminDs.query(`SELECT id FROM users WHERE username = $1`, [
        `owner_${code}`,
      ]);
      expect(users.length).toBe(0);
      const audit = await adminDs.query(
        `SELECT id FROM audit_log WHERE platform_admin_id = $1 AND action = 'platform.tenant.create'`,
        [adminId],
      );
      expect(audit.length).toBe(0);
    };

    // One case per way a password can be unacceptable. `1234` is the one from the issue.
    for (const [label, password] of [
      ['a short numeric password (the one from the issue)', '1234'],
      ['an 11-character password, one under the floor', 'password123'],
      ['an empty password', ''],
      ['a whitespace-only password', '            '],
      ['an absent password', undefined],
      // A JSON number reached `argon2.hash` before #364 and blew up inside the
      // transaction as a 500; it must be an ordinary 400 verdict.
      ['a non-string password', 1234],
    ] as const) {
      it(`refuses ${label} and creates nothing`, async () => {
        const code = `weakpw-${randomUUID().slice(0, 8)}`;
        const res = await provision(code, password);

        expect(res.status).toBe(400);
        expect(res.body.error.code).toBe('WEAK_PASSWORD');
        await expectNothingPersisted(code);
      });
    }

    it('accepts a password of exactly the minimum length', async () => {
      const code = `okpw-${randomUUID().slice(0, 8)}`;
      // Exactly MIN_PASSWORD_LENGTH (12) — the boundary must be inclusive.
      const res = await provision(code, 'aaaabbbbcccc');

      expect(res.status).toBe(201);
      const tenantId = res.body.data.tenantId;
      expect(tenantId).toBeDefined();

      await adminDs.query(`DELETE FROM audit_log WHERE tenant_id = $1`, [tenantId]);
      await adminDs.query(`DELETE FROM devices WHERE tenant_id = $1`, [tenantId]);
      await adminDs.query(`DELETE FROM categories WHERE tenant_id = $1`, [tenantId]);
      await adminDs.query(`DELETE FROM settings WHERE tenant_id = $1`, [tenantId]);
      await adminDs.query(`DELETE FROM users WHERE tenant_id = $1`, [tenantId]);
      await adminDs.query(`DELETE FROM tenants WHERE id = $1`, [tenantId]);
    });
  });

  describe('Atomic updateStatus and cache purge (AC3)', () => {
    it('updates status and purges cache atomically', async () => {
      // Create a tenant first
      const code = `status-${randomUUID().slice(0, 8)}`;
      const createRes = await request(app.getHttpServer())
        .post('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${adminToken}`)
        .send({
          code,
          shopName: 'ร้านทดสอบ สเตตัส',
          ownerUsername: `owner_${code}`,
          ownerPassword: 'password-123456',
        });
      const tenantId = createRes.body.data.tenantId;

      // Prime tenant status cache
      await cache.setex(`t:${tenantId}:status`, 300, 'active');

      const patchRes = await request(app.getHttpServer())
        .patch(`/api/v1/platform/tenants/${tenantId}/status`)
        .set('Authorization', `Bearer ${adminToken}`)
        .send({ status: 'suspended' });

      expect(patchRes.status).toBe(200);
      expect(patchRes.body.data.status).toBe('suspended');

      // Redis cache must be purged
      const cached = await cache.get(`t:${tenantId}:status`);
      expect(cached).toBeNull();

      // Audit log entry must exist
      const auditRows = await adminDs.query(
        `SELECT * FROM audit_log WHERE tenant_id = $1 AND action = 'platform.tenant.update_status'`,
        [tenantId],
      );
      expect(auditRows.length).toBe(1);

      // Clean up
      await adminDs.query(`DELETE FROM audit_log WHERE tenant_id = $1`, [tenantId]);
      await adminDs.query(`DELETE FROM devices WHERE tenant_id = $1`, [tenantId]);
      await adminDs.query(`DELETE FROM categories WHERE tenant_id = $1`, [tenantId]);
      await adminDs.query(`DELETE FROM settings WHERE tenant_id = $1`, [tenantId]);
      await adminDs.query(`DELETE FROM users WHERE tenant_id = $1`, [tenantId]);
      await adminDs.query(`DELETE FROM tenants WHERE id = $1`, [tenantId]);
    });
  });

  // Same trick as the createTenant rollback test: a cached '1' lets a token for an admin
  // that is not in platform_admins past the guard, so the audit INSERT fails its FK.
  describe('Audit failure rolls back status change and import (AC2)', () => {
    let tenantId: string;
    let ghostAdminId: string;
    let ghostToken: string;

    beforeEach(async () => {
      const code = `rb-${randomUUID().slice(0, 8)}`;
      const createRes = await request(app.getHttpServer())
        .post('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${adminToken}`)
        .send({ code, shopName: 'ร้านทดสอบ โรลแบ็ค', ownerUsername: `owner_${code}`, ownerPassword: 'password-123456' });
      expect(createRes.status).toBe(201);
      tenantId = createRes.body.data.tenantId;

      ghostAdminId = randomUUID();
      await cache.setex(`pa:${ghostAdminId}:exists`, 60, '1');
      ghostToken = signJwt(
        { iss: 'srisurart-pos', aud: 'platform', sub: ghostAdminId, username: 'ghost-admin' },
        config.jwtPlatformSecret,
      );
    });

    afterEach(async () => {
      await cache.del(`pa:${ghostAdminId}:exists`);
      for (const table of ['audit_log', 'products', 'devices', 'categories', 'settings', 'users']) {
        await adminDs.query(`DELETE FROM ${table} WHERE tenant_id = $1`, [tenantId]);
      }
      await adminDs.query(`DELETE FROM tenants WHERE id = $1`, [tenantId]);
    });

    it('leaves tenants.status unchanged when the status-change audit fails', async () => {
      const res = await request(app.getHttpServer())
        .patch(`/api/v1/platform/tenants/${tenantId}/status`)
        .set('Authorization', `Bearer ${ghostToken}`)
        .send({ status: 'suspended' });

      expect(res.status).toBe(500);
      const rows = await adminDs.query(`SELECT status FROM tenants WHERE id = $1`, [tenantId]);
      expect(rows[0].status).toBe('active');
    });

    it('writes no imported rows when the import audit fails', async () => {
      const categoryName = `import-cat-${randomUUID().slice(0, 8)}`;
      const res = await request(app.getHttpServer())
        .post(`/api/v1/platform/tenants/${tenantId}/import`)
        .set('Authorization', `Bearer ${ghostToken}`)
        .send({ __meta: {}, sa_categories: [{ name: categoryName, position: 99 }] });

      expect(res.status).toBe(500);
      const rows = await adminDs.query(
        `SELECT 1 FROM categories WHERE tenant_id = $1 AND name = $2`,
        [tenantId, categoryName],
      );
      expect(rows.length).toBe(0);
    });
  });

  describe('Full loop: Provision -> Login -> Enrol -> Sell without psql (DoD line 6, ADR-0001)', () => {
    it('creates tenant, logs in as owner, creates product, enrols POS device, logs in on POS, opens shift, and sells', async () => {
      const code = `loop-${randomUUID().slice(0, 8)}`;
      const ownerUsername = `owner_${code}`;
      const ownerPassword = 'password-123456';

      // 1. POST /platform/tenants: platform admin provisions tenant
      const provisionRes = await request(app.getHttpServer())
        .post('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${adminToken}`)
        .send({
          code,
          shopName: 'ร้านทดสอบ ลูปเต็ม',
          ownerUsername,
          ownerPassword,
          ownerDisplayName: 'เจ้าของร้าน',
        });

      expect(provisionRes.status).toBe(201);
      const { tenantId, enrolCode } = provisionRes.body.data;
      expect(tenantId).toBeDefined();
      expect(enrolCode).toBeDefined();

      try {
        // 2. POST /auth/token: Owner logs in without device token (backoffice session)
        const ownerLoginRes = await request(app.getHttpServer())
          .post('/api/v1/auth/token')
          .send({ username: ownerUsername, password: ownerPassword });

        expect(ownerLoginRes.status).toBe(200);
        const ownerToken = ownerLoginRes.body.data.accessToken;
        expect(ownerToken).toBeDefined();

        // 3. POST /products: Owner adds a product to inventory via backoffice session
        const prodRes = await request(app.getHttpServer())
          .post('/api/v1/products')
          .set('Authorization', `Bearer ${ownerToken}`)
          .set('Idempotency-Key', `k-prod-${randomUUID()}`)
          .send({
            partNo: 'PART-NEW-01',
            name: 'ผ้าเบรคหน้า',
            category: 'เบรก',
            price: '450.00',
            cost: '300.00',
            stock: 20,
          });

        expect(prodRes.status).toBe(201);
        const productId = prodRes.body.data.id;
        expect(productId).toBeDefined();

        // 4. POST /auth/device: Device enrols using the server-issued enrolCode
        const enrolRes = await request(app.getHttpServer())
          .post('/api/v1/auth/device')
          .send({ code: enrolCode });

        expect(enrolRes.status).toBe(200);
        const deviceToken = enrolRes.body.data.deviceToken;
        expect(deviceToken).toBeDefined();

        // 5. POST /auth/token: Cashier/Owner logs in with deviceToken to obtain POS token
        const posLoginRes = await request(app.getHttpServer())
          .post('/api/v1/auth/token')
          .send({
            username: ownerUsername,
            password: ownerPassword,
            deviceToken,
          });

        expect(posLoginRes.status).toBe(200);
        const posToken = posLoginRes.body.data.accessToken;
        expect(posToken).toBeDefined();

        // 6. POST /shifts/open: POS opens the cash drawer
        const openRes = await request(app.getHttpServer())
          .post('/api/v1/shifts/open')
          .set('Authorization', `Bearer ${posToken}`)
          .set('Idempotency-Key', `k-shift-${randomUUID()}`)
          .send({ startingCash: '1000.00' });

        expect(openRes.status).toBe(200);
        const shiftId = openRes.body.data.id;
        expect(shiftId).toBeDefined();

        // 7. POST /sales: POS rings up a sale
        const saleId = `s-${randomUUID()}`;
        const saleRes = await request(app.getHttpServer())
          .post('/api/v1/sales')
          .set('Authorization', `Bearer ${posToken}`)
          .set('Idempotency-Key', `k-sale-${randomUUID()}`)
          .send({
            id: saleId,
            subtotal: '450.00',
            discount: '0.00',
            total: '450.00',
            paymentMethod: 'เงินสด',
            items: [
              {
                lineNo: 1,
                productId,
                name: 'ผ้าเบรคหน้า',
                qty: 1,
                price: '450.00',
              },
            ],
          });

        expect(saleRes.status).toBe(201);
        expect(saleRes.body.status).toBe('success');
        expect(saleRes.body.data.shiftId).toBe(shiftId);
        expect(saleRes.body.data.receiptNo).toMatch(/^RC01-\d{4}-\d{2}-\d{4}$/);
        expect(saleRes.body.data.total).toBe('450.00');
      } finally {
        // Cleanup created tenant
        await adminDs.query(`DELETE FROM audit_log WHERE tenant_id = $1`, [tenantId]);
        await adminDs.query(`DELETE FROM movements WHERE tenant_id = $1`, [tenantId]);
        await adminDs.query(`DELETE FROM sale_items WHERE tenant_id = $1`, [tenantId]);
        await adminDs.query(`DELETE FROM sales WHERE tenant_id = $1`, [tenantId]);
        await adminDs.query(`DELETE FROM drawer_entries WHERE tenant_id = $1`, [tenantId]);
        await adminDs.query(`DELETE FROM shifts WHERE tenant_id = $1`, [tenantId]);
        await adminDs.query(`DELETE FROM products WHERE tenant_id = $1`, [tenantId]);
        await adminDs.query(`DELETE FROM devices WHERE tenant_id = $1`, [tenantId]);
        await adminDs.query(`DELETE FROM categories WHERE tenant_id = $1`, [tenantId]);
        await adminDs.query(`DELETE FROM settings WHERE tenant_id = $1`, [tenantId]);
        await adminDs.query(`DELETE FROM users WHERE tenant_id = $1`, [tenantId]);
        await adminDs.query(`DELETE FROM tenants WHERE id = $1`, [tenantId]);
        await cache.del(`t:${tenantId}:status`);
        await cache.del(`t:${tenantId}:plan`);
      }
    });
  });
});
