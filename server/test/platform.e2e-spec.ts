import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import type { Redis } from 'ioredis';
import { randomUUID } from 'node:crypto';
import { signJwt } from '../src/common/jwt.js';
import { hashPassword } from '../src/common/password.js';
import { APP_CONFIG, type AppConfig } from '../src/config/config.js';
import { platformAdminCacheKey } from '../src/platform/platform-auth.guard.js';
import { createTestApp, seedOpenShift, TENANT_TABLES_DEPTH_FIRST } from './support/fixture.js';
import { activateOwner, OWNER_CHOSEN_PASSWORD } from './support/owner-password.js';

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
    await cache.del(platformAdminCacheKey(adminId));
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
      const cached = await cache.get(platformAdminCacheKey(adminId));
      expect(cached).toBe('1');
      const ttl = await cache.ttl(platformAdminCacheKey(adminId));
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
      const cached = await cache.get(platformAdminCacheKey(nonExistentAdminId));
      expect(cached).toBe('0');
      await cache.del(platformAdminCacheKey(nonExistentAdminId));
    });

    it('rejects a tenant create with 401 once the admin is deleted, and writes no tenant', async () => {
      await adminDs.query(`DELETE FROM platform_admins WHERE id = $1`, [adminId]);
      await cache.del(platformAdminCacheKey(adminId));
      const code = `gone-${randomUUID().slice(0, 8)}`;

      const res = await request(app.getHttpServer())
        .post('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${adminToken}`)
        .send({ code, shopName: 'ร้านทดสอบ', ownerUsername: `owner_${code}` });

      expect(res.status).toBe(401);
      const tenantRows = await adminDs.query(`SELECT id FROM tenants WHERE code = $1`, [code]);
      expect(tenantRows.length).toBe(0);
    });

    it('rejects with 401 when platform admin is marked inactive', async () => {
      await adminDs.query(`UPDATE platform_admins SET is_active = false WHERE id = $1`, [adminId]);
      await cache.del(platformAdminCacheKey(adminId));

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
      await cache.setex(platformAdminCacheKey(deletedAdminId), 60, '1');

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
          ownerDisplayName: 'เจ้าของร้าน',
        });

      // Audit insertion must fail on foreign key constraint `audit_log_platform_admin_id_fkey`
      expect(res.status).toBe(500);

      // Ground-truth check: Ensure NO tenant was created and the code is NOT reserved
      const tenantRows = await adminDs.query(`SELECT id FROM tenants WHERE code = $1`, [code]);
      expect(tenantRows.length).toBe(0);

      const userRows = await adminDs.query(`SELECT id FROM users WHERE username = $1`, [`owner_${code}`]);
      expect(userRows.length).toBe(0);

      await cache.del(platformAdminCacheKey(deletedAdminId));
    });
  });

  // #443 PR3 (owner decision 2026-09-27, Q6): the admin never chooses the owner's password.
  // A caller still sending `ownerPassword` — any value, even a strong one — is on the old
  // contract and gets a loud 400 before argon2 and before the transaction, so nothing is left.
  describe('ownerPassword is refused (#443 PR3, supersedes the #364 length policy)', () => {
    for (const [label, password] of [
      ['a strong password', 'password-123456'],
      ['a short password', '1234'],
      ['an empty password', ''],
      ['a non-string password', 1234],
    ] as const) {
      it(`refuses ${label} with 400 OWNER_PASSWORD_NOT_ACCEPTED and creates nothing`, async () => {
        const code = `legacypw-${randomUUID().slice(0, 8)}`;
        const res = await request(app.getHttpServer())
          .post('/api/v1/platform/tenants')
          .set('Authorization', `Bearer ${adminToken}`)
          .send({
            code,
            shopName: 'ร้านทดสอบ สัญญาเก่า',
            ownerUsername: `owner_${code}`,
            ownerDisplayName: 'เจ้าของร้าน',
            ownerPassword: password,
          });

        expect(res.status).toBe(400);
        expect(res.body.error.code).toBe('OWNER_PASSWORD_NOT_ACCEPTED');
        expect(await adminDs.query(`SELECT id FROM tenants WHERE code = $1`, [code])).toEqual([]);
        expect(
          await adminDs.query(`SELECT id FROM users WHERE username = $1`, [`owner_${code}`]),
        ).toEqual([]);
      });
    }
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
        .send({ code, shopName: 'ร้านทดสอบ โรลแบ็ค', ownerUsername: `owner_${code}` });
      expect(createRes.status).toBe(201);
      tenantId = createRes.body.data.tenantId;

      ghostAdminId = randomUUID();
      await cache.setex(platformAdminCacheKey(ghostAdminId), 60, '1');
      ghostToken = signJwt(
        { iss: 'srisurart-pos', aud: 'platform', sub: ghostAdminId, username: 'ghost-admin' },
        config.jwtPlatformSecret,
      );
    });

    afterEach(async () => {
      await cache.del(platformAdminCacheKey(ghostAdminId));
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
      const ownerPassword = OWNER_CHOSEN_PASSWORD;

      // 1. POST /platform/tenants: platform admin provisions tenant (#443 PR3: the server
      //    generates the owner's temporary password and returns it once)
      const provisionRes = await request(app.getHttpServer())
        .post('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${adminToken}`)
        .send({
          code,
          shopName: 'ร้านทดสอบ ลูปเต็ม',
          ownerUsername,
          ownerDisplayName: 'เจ้าของร้าน',
        });

      expect(provisionRes.status).toBe(201);
      const { tenantId, enrolCode, tempPassword } = provisionRes.body.data;
      expect(tenantId).toBeDefined();
      expect(enrolCode).toBeDefined();
      expect(tempPassword).toBeDefined();

      try {
        // 2. The owner replaces the temporary password (forced at first login), which
        //    yields the full backoffice session.
        const ownerSession = await activateOwner(app, ownerUsername, tempPassword, ownerPassword);
        const ownerToken = ownerSession.accessToken;
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

  // #443 PR2: the answer to "the shop's first device's 7-day enrolCode expired and it
  // never enrolled" — a platform admin can reissue one, but only for a device that has
  // never been enrolled, and `GET /platform/tenants/:id` so the CLI/UI has device ids and
  // import-job status to work from without touching psql.
  describe('Enrol-code reissue + tenant detail (#443 PR2)', () => {
    let tenantId: string;
    let ownerUsername: string;
    let ownerPassword: string;
    let provisioningEnrolCode: string;

    beforeEach(async () => {
      const code = `pr2-${randomUUID().slice(0, 8)}`;
      ownerUsername = `owner_${code}`;
      ownerPassword = OWNER_CHOSEN_PASSWORD;
      const provisionRes = await request(app.getHttpServer())
        .post('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${adminToken}`)
        .send({
          code,
          shopName: 'ร้านทดสอบ ออกโค้ดใหม่',
          ownerUsername,
          ownerDisplayName: 'เจ้าของร้าน',
        });
      expect(provisionRes.status).toBe(201);
      tenantId = provisionRes.body.data.tenantId;
      provisioningEnrolCode = provisionRes.body.data.enrolCode;
      await activateOwner(app, ownerUsername, provisionRes.body.data.tempPassword, ownerPassword);
    });

    afterEach(async () => {
      for (const table of ['audit_log', 'devices', 'categories', 'settings', 'users']) {
        await adminDs.query(`DELETE FROM ${table} WHERE tenant_id = $1`, [tenantId]);
      }
      await adminDs.query(`DELETE FROM tenants WHERE id = $1`, [tenantId]);
      await cache.del(`t:${tenantId}:status`);
    });

    it('reissues a code for the never-enrolled first device, kills the old code, and the new one enrols', async () => {
      // The old code (from provisioning) still works before reissue.
      const reissueRes = await request(app.getHttpServer())
        .post(`/api/v1/platform/tenants/${tenantId}/devices/pos1/enrol-code`)
        .set('Authorization', `Bearer ${adminToken}`)
        .send();

      expect(reissueRes.status).toBe(200);
      expect(reissueRes.body.data.deviceId).toBe('pos1');
      expect(reissueRes.body.data.enrolCode).toMatch(/^[0-9A-F]{8}$/);
      expect(reissueRes.body.data.enrolExpiresAt).toBeDefined();
      const newCode = reissueRes.body.data.enrolCode;

      // The provisioning-time code is dead: `auth_enrol_device` no longer matches its hash.
      const oldCodeRes = await request(app.getHttpServer())
        .post('/api/v1/auth/device')
        .send({ code: provisioningEnrolCode });
      expect(oldCodeRes.status).toBe(401);

      // The new code enrols.
      const newCodeRes = await request(app.getHttpServer())
        .post('/api/v1/auth/device')
        .send({ code: newCode });
      expect(newCodeRes.status).toBe(200);
      expect(newCodeRes.body.data.deviceToken).toBeDefined();

      // Audit row carries platform_admin_id and never the code.
      const auditRows = await adminDs.query(
        `SELECT * FROM audit_log WHERE tenant_id = $1 AND action = 'platform.device.enrol_code_reissued'`,
        [tenantId],
      );
      expect(auditRows.length).toBe(1);
      expect(auditRows[0].platform_admin_id).toBe(adminId);
      expect(auditRows[0].entity_id).toBe('pos1');
      const auditJson = JSON.stringify(auditRows[0]);
      expect(auditJson).not.toContain(newCode);
      expect(auditJson).not.toContain(provisioningEnrolCode);
    });

    it('refuses to reissue for a device that is already enrolled (409)', async () => {
      const enrolCode = provisioningEnrolCode;
      const enrolRes = await request(app.getHttpServer())
        .post('/api/v1/auth/device')
        .send({ code: enrolCode });
      expect(enrolRes.status).toBe(200);

      const reissueRes = await request(app.getHttpServer())
        .post(`/api/v1/platform/tenants/${tenantId}/devices/pos1/enrol-code`)
        .set('Authorization', `Bearer ${adminToken}`)
        .send();

      expect(reissueRes.status).toBe(409);
      expect(reissueRes.body.error.code).toBe('DEVICE_ALREADY_ENROLLED');
    });

    it('refuses to reissue for a retired device (409)', async () => {
      // A never-enrolled second device can still be retired directly (retire only requires
      // the *caller's* session to carry a device id, not that the target is enrolled).
      const ownerLoginRes = await request(app.getHttpServer())
        .post('/api/v1/auth/token')
        .send({ username: ownerUsername, password: ownerPassword });
      const enrolRes = await request(app.getHttpServer())
        .post('/api/v1/auth/device')
        .send({ code: provisioningEnrolCode });
      const deviceToken = enrolRes.body.data.deviceToken;
      const posLoginRes = await request(app.getHttpServer())
        .post('/api/v1/auth/token')
        .send({ username: ownerUsername, password: ownerPassword, deviceToken });
      const posToken = posLoginRes.body.data.accessToken;

      const createRes = await request(app.getHttpServer())
        .post('/api/v1/devices')
        .set('Authorization', `Bearer ${posToken}`)
        .set('Idempotency-Key', `k-dev-${randomUUID()}`)
        .send({ label: 'สำรอง', role: 'backoffice' });
      expect(createRes.status).toBe(201);
      const secondDeviceId = createRes.body.data.device.id;

      const retireRes = await request(app.getHttpServer())
        .post(`/api/v1/devices/${secondDeviceId}/retire`)
        .set('Authorization', `Bearer ${posToken}`)
        .set('Idempotency-Key', `k-ret-${randomUUID()}`)
        .send({});
      expect(retireRes.status).toBe(200);

      const reissueRes = await request(app.getHttpServer())
        .post(`/api/v1/platform/tenants/${tenantId}/devices/${secondDeviceId}/enrol-code`)
        .set('Authorization', `Bearer ${adminToken}`)
        .send();

      expect(reissueRes.status).toBe(409);
      expect(reissueRes.body.error.code).toBe('DEVICE_ALREADY_ENROLLED');
      void ownerLoginRes; // login is exercised only to obtain the device/pos tokens above
    });

    it('answers 404 for a device id that does not belong to (or exist for) the tenant', async () => {
      const reissueRes = await request(app.getHttpServer())
        .post(`/api/v1/platform/tenants/${tenantId}/devices/does-not-exist/enrol-code`)
        .set('Authorization', `Bearer ${adminToken}`)
        .send();

      expect(reissueRes.status).toBe(404);
      expect(reissueRes.body.error.code).toBe('DEVICE_NOT_FOUND');
    });

    it("answers 404 for another tenant's device id, and never touches that tenant's row", async () => {
      const otherCode = `pr2o-${randomUUID().slice(0, 8)}`;
      const otherRes = await request(app.getHttpServer())
        .post('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${adminToken}`)
        .send({
          code: otherCode,
          shopName: 'ร้านอื่น',
          ownerUsername: `owner_${otherCode}`,
          ownerDisplayName: 'เจ้าของร้านอื่น',
        });
      expect(otherRes.status).toBe(201);
      const otherTenantId: string = otherRes.body.data.tenantId;
      try {
        await adminDs.query(
          `INSERT INTO devices (tenant_id, id, label, device_no, role) VALUES ($1, 'only-in-other', 'x', 2, 'backoffice')`,
          [otherTenantId],
        );
        const before = await adminDs.query(
          `SELECT id, enrol_code_hash, enrol_expires_at FROM devices WHERE tenant_id = $1 ORDER BY id`,
          [otherTenantId],
        );

        const res = await request(app.getHttpServer())
          .post(`/api/v1/platform/tenants/${tenantId}/devices/only-in-other/enrol-code`)
          .set('Authorization', `Bearer ${adminToken}`)
          .send();
        expect(res.status).toBe(404);
        expect(res.body.error.code).toBe('DEVICE_NOT_FOUND');

        // Reissuing `pos1` here must not reach the other tenant's `pos1` either.
        const ok = await request(app.getHttpServer())
          .post(`/api/v1/platform/tenants/${tenantId}/devices/pos1/enrol-code`)
          .set('Authorization', `Bearer ${adminToken}`)
          .send();
        expect(ok.status).toBe(200);

        const after = await adminDs.query(
          `SELECT id, enrol_code_hash, enrol_expires_at FROM devices WHERE tenant_id = $1 ORDER BY id`,
          [otherTenantId],
        );
        expect(after).toEqual(before);
      } finally {
        for (const table of ['audit_log', 'devices', 'categories', 'settings', 'users']) {
          await adminDs.query(`DELETE FROM ${table} WHERE tenant_id = $1`, [otherTenantId]);
        }
        await adminDs.query(`DELETE FROM tenants WHERE id = $1`, [otherTenantId]);
        await cache.del(`t:${otherTenantId}:status`);
      }
    });

    it('refuses both new routes with 403 PLATFORM_IP_FORBIDDEN from an IP outside the allowlist', async () => {
      const reissueRes = await request(app.getHttpServer())
        .post(`/api/v1/platform/tenants/${tenantId}/devices/pos1/enrol-code`)
        .set('Authorization', `Bearer ${adminToken}`)
        .set('X-Forwarded-For', '203.0.113.195')
        .send();
      expect(reissueRes.status).toBe(403);
      expect(reissueRes.body.error.code).toBe('PLATFORM_IP_FORBIDDEN');

      const detailRes = await request(app.getHttpServer())
        .get(`/api/v1/platform/tenants/${tenantId}`)
        .set('Authorization', `Bearer ${adminToken}`)
        .set('X-Forwarded-For', '203.0.113.195');
      expect(detailRes.status).toBe(403);
      expect(detailRes.body.error.code).toBe('PLATFORM_IP_FORBIDDEN');

      // Refused at the guard: the code was not rotated.
      const rows = await adminDs.query(
        `SELECT 1 FROM audit_log WHERE tenant_id = $1 AND action = 'platform.device.enrol_code_reissued'`,
        [tenantId],
      );
      expect(rows).toHaveLength(0);
    });

    it('GET /platform/tenants/:id still shows an expired enrolExpiresAt (the case reissue exists for)', async () => {
      await adminDs.query(
        `UPDATE devices SET enrol_expires_at = now() - interval '1 day' WHERE tenant_id = $1 AND id = 'pos1'`,
        [tenantId],
      );
      const res = await request(app.getHttpServer())
        .get(`/api/v1/platform/tenants/${tenantId}`)
        .set('Authorization', `Bearer ${adminToken}`);
      expect(res.status).toBe(200);
      const device = res.body.data.devices[0];
      expect(device.enrolled).toBe(false);
      expect(new Date(device.enrolExpiresAt).getTime()).toBeLessThan(Date.now());
    });

    it('answers 400 INVALID_TENANT_ID for a non-UUID tenant id, on both the reissue and detail routes', async () => {
      const reissueRes = await request(app.getHttpServer())
        .post('/api/v1/platform/tenants/not-a-uuid/devices/pos1/enrol-code')
        .set('Authorization', `Bearer ${adminToken}`)
        .send();
      expect(reissueRes.status).toBe(400);
      expect(reissueRes.body.error.code).toBe('INVALID_TENANT_ID');

      const detailRes = await request(app.getHttpServer())
        .get('/api/v1/platform/tenants/not-a-uuid')
        .set('Authorization', `Bearer ${adminToken}`);
      expect(detailRes.status).toBe(400);
      expect(detailRes.body.error.code).toBe('INVALID_TENANT_ID');

      const statusRes = await request(app.getHttpServer())
        .patch('/api/v1/platform/tenants/not-a-uuid/status')
        .set('Authorization', `Bearer ${adminToken}`)
        .send({ status: 'suspended' });
      expect(statusRes.status).toBe(400);
      expect(statusRes.body.error.code).toBe('INVALID_TENANT_ID');
    });

    it('answers 400 for a malformed UUID even when the request body itself is fine', async () => {
      const res = await request(app.getHttpServer())
        .post(`/api/v1/platform/tenants/${tenantId}xx/devices/pos1/enrol-code`)
        .set('Authorization', `Bearer ${adminToken}`)
        .send();
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('INVALID_TENANT_ID');
    });

    it('GET /platform/tenants/:id answers 404 for an unknown (but well-formed) tenant id', async () => {
      const res = await request(app.getHttpServer())
        .get(`/api/v1/platform/tenants/${randomUUID()}`)
        .set('Authorization', `Bearer ${adminToken}`);
      expect(res.status).toBe(404);
    });

    it('GET /platform/tenants/:id returns the tenant, its devices with no secrets, and its import jobs', async () => {
      const res = await request(app.getHttpServer())
        .get(`/api/v1/platform/tenants/${tenantId}`)
        .set('Authorization', `Bearer ${adminToken}`);

      expect(res.status).toBe(200);
      expect(res.body.data.tenant.id).toBe(tenantId);
      expect(res.body.data.devices).toHaveLength(1);
      const device = res.body.data.devices[0];
      expect(device).toEqual({
        id: 'pos1',
        label: 'POS #1',
        role: 'pos',
        enrolled: false,
        enrolExpiresAt: expect.any(String),
        retiredAt: null,
      });
      // No hash of any kind leaves this endpoint.
      const bodyJson = JSON.stringify(res.body);
      expect(bodyJson).not.toContain('enrol_code_hash');
      expect(bodyJson).not.toContain('token_hash');
      expect(bodyJson.toLowerCase()).not.toMatch(/[0-9a-f]{64}/); // a sha256 hex hash

      expect(res.body.data.importJobs).toEqual([]);

      // Owner panel (#443 UX pass): beforeEach already replaced the temp password.
      expect(res.body.data.owner).toEqual({
        username: ownerUsername,
        displayName: 'เจ้าของร้าน',
        mustChangePassword: false,
        tempPasswordExpiresAt: null,
        passwordChangedAt: expect.any(String),
      });
      expect(bodyJson).not.toContain('password_hash');
      expect(bodyJson).not.toContain('argon2');

      // Reading the detail is itself audited.
      const auditRows = await adminDs.query(
        `SELECT * FROM audit_log WHERE tenant_id = $1 AND action = 'platform.tenant.read'`,
        [tenantId],
      );
      expect(auditRows.length).toBe(1);
      expect(auditRows[0].platform_admin_id).toBe(adminId);
    });

    it('owner panel shows a pending temp password after a reset, never the password itself', async () => {
      const resetRes = await request(app.getHttpServer())
        .post(`/api/v1/platform/tenants/${tenantId}/owner/temp-password`)
        .set('Authorization', `Bearer ${adminToken}`)
        .send();
      expect(resetRes.status).toBe(200);
      const tempPassword: string = resetRes.body.data.tempPassword;

      const res = await request(app.getHttpServer())
        .get(`/api/v1/platform/tenants/${tenantId}`)
        .set('Authorization', `Bearer ${adminToken}`);
      expect(res.status).toBe(200);
      expect(res.body.data.owner).toMatchObject({
        username: ownerUsername,
        mustChangePassword: true,
        tempPasswordExpiresAt: resetRes.body.data.tempPasswordExpiresAt,
      });
      expect(JSON.stringify(res.body)).not.toContain(tempPassword);
    });
  });

  // Owner decision 2026-10-03 (#443): `closed` is terminal.
  describe('Tenant status transitions — closed is terminal (#443)', () => {
    let tenantId: string;

    beforeEach(async () => {
      const code = `term-${randomUUID().slice(0, 8)}`;
      const res = await request(app.getHttpServer())
        .post('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${adminToken}`)
        .send({ code, shopName: 'ร้านทดสอบ ปิดถาวร', ownerUsername: `owner_${code}` });
      expect(res.status).toBe(201);
      tenantId = res.body.data.tenantId;
    });

    afterEach(async () => {
      for (const table of ['audit_log', 'devices', 'categories', 'settings', 'users']) {
        await adminDs.query(`DELETE FROM ${table} WHERE tenant_id = $1`, [tenantId]);
      }
      await adminDs.query(`DELETE FROM tenants WHERE id = $1`, [tenantId]);
      await cache.del(`t:${tenantId}:status`);
    });

    const patchStatus = (status: string) =>
      request(app.getHttpServer())
        .patch(`/api/v1/platform/tenants/${tenantId}/status`)
        .set('Authorization', `Bearer ${adminToken}`)
        .send({ status });

    it('allows active ↔ suspended and → closed', async () => {
      for (const status of ['suspended', 'active', 'suspended', 'closed']) {
        const res = await patchStatus(status);
        expect(res.status).toBe(200);
        expect(res.body.data.status).toBe(status);
      }
      const rows = await adminDs.query(`SELECT status FROM tenants WHERE id = $1`, [tenantId]);
      expect(rows[0].status).toBe('closed');
    });

    it.each(['active', 'suspended', 'closed'])(
      'refuses closed → %s with 409 TENANT_CLOSED, leaving the row and the audit log alone',
      async (target) => {
        expect((await patchStatus('closed')).status).toBe(200);
        await cache.setex(`t:${tenantId}:status`, 300, 'closed');

        const res = await patchStatus(target);
        expect(res.status).toBe(409);
        expect(res.body.error.code).toBe('TENANT_CLOSED');

        const rows = await adminDs.query(`SELECT status FROM tenants WHERE id = $1`, [tenantId]);
        expect(rows[0].status).toBe('closed');
        const audit = await adminDs.query(
          `SELECT 1 FROM audit_log WHERE tenant_id = $1 AND action = 'platform.tenant.update_status'`,
          [tenantId],
        );
        expect(audit).toHaveLength(1); // only the close itself
        // The refusal does not touch the status cache either.
        expect(await cache.get(`t:${tenantId}:status`)).toBe('closed');
      },
    );

    it('answers 404 for an unknown (but well-formed) tenant id', async () => {
      const res = await request(app.getHttpServer())
        .patch(`/api/v1/platform/tenants/${randomUUID()}/status`)
        .set('Authorization', `Bearer ${adminToken}`)
        .send({ status: 'suspended' });
      expect(res.status).toBe(404);
    });
  });

  // #476: the shop's only enrolled device is lost (browser wiped, machine gone). Its own
  // `/devices` routes need an enrolled session, and `enrol-code` refuses an enrolled row, so
  // this is the platform-admin escape hatch: retire it and create the replacement in one go.
  describe('Device replace — lost last enrolled device (#476)', () => {
    let tenantId: string;
    let ownerUsername: string;
    let oldDeviceToken: string;

    const replace = (tid: string, deviceId: string, body: Record<string, unknown> = {}) =>
      request(app.getHttpServer())
        .post(`/api/v1/platform/tenants/${tid}/devices/${deviceId}/replace`)
        .set('Authorization', `Bearer ${adminToken}`)
        .send(body);

    const provision = async (prefix: string) => {
      const code = `${prefix}-${randomUUID().slice(0, 8)}`;
      const res = await request(app.getHttpServer())
        .post('/api/v1/platform/tenants')
        .set('Authorization', `Bearer ${adminToken}`)
        .send({ code, shopName: 'ร้านเครื่องหาย', ownerUsername: `owner_${code}`, ownerDisplayName: 'เจ้าของ' });
      expect(res.status).toBe(201);
      return { ...res.body.data, ownerUsername: `owner_${code}` } as {
        tenantId: string;
        enrolCode: string;
        tempPassword: string;
        ownerUsername: string;
      };
    };

    const cleanup = async (tid: string) => {
      for (const table of TENANT_TABLES_DEPTH_FIRST) {
        await adminDs.query(`DELETE FROM ${table} WHERE tenant_id = $1::uuid`, [tid]);
      }
      await adminDs.query(`DELETE FROM tenants WHERE id = $1`, [tid]);
      for (const key of await cache.keys(`t:${tid}:*`)) await cache.del(key);
    };

    beforeEach(async () => {
      const p = await provision('rpl');
      tenantId = p.tenantId;
      ownerUsername = p.ownerUsername;
      await activateOwner(app, ownerUsername, p.tempPassword, OWNER_CHOSEN_PASSWORD);
      const enrol = await request(app.getHttpServer())
        .post('/api/v1/auth/device')
        .send({ code: p.enrolCode });
      expect(enrol.status).toBe(200);
      oldDeviceToken = enrol.body.data.deviceToken;
    });

    afterEach(async () => {
      await cleanup(tenantId);
    });

    it('retires the lost device, creates a new device_no, and the one-time code enrols a working POS', async () => {
      // A retired row higher than pos1: device_no is max + 1 over every row (F8).
      await adminDs.query(
        `INSERT INTO devices (tenant_id, id, label, device_no, role, retired_at)
         VALUES ($1, 'old-bo', 'เก่า', 5, 'backoffice', now())`,
        [tenantId],
      );

      const res = await replace(tenantId, 'pos1');
      expect(res.status).toBe(200);
      const data = res.body.data;
      expect(data.retiredDeviceId).toBe('pos1');
      expect(data.device).toEqual({ id: expect.any(String), label: 'POS #6', role: 'pos', deviceNo: 6 });
      expect(data.enrolCode).toMatch(/^[0-9A-F]{8}$/);
      expect(new Date(data.enrolExpiresAt).getTime()).toBeGreaterThan(Date.now() + 6 * 86400_000);

      const old = await adminDs.query(
        `SELECT retired_at, enrol_code_hash FROM devices WHERE tenant_id = $1 AND id = 'pos1'`,
        [tenantId],
      );
      expect(old[0].retired_at).not.toBeNull();
      expect(old[0].enrol_code_hash).toBeNull();

      // The lost browser's token is dead.
      const oldLogin = await request(app.getHttpServer())
        .post('/api/v1/auth/token')
        .send({ username: ownerUsername, password: OWNER_CHOSEN_PASSWORD, deviceToken: oldDeviceToken });
      expect(oldLogin.status).toBe(401);

      // The code enrols exactly once, and the login it unlocks carries the new device.
      const enrol = await request(app.getHttpServer()).post('/api/v1/auth/device').send({ code: data.enrolCode });
      expect(enrol.status).toBe(200);
      const again = await request(app.getHttpServer()).post('/api/v1/auth/device').send({ code: data.enrolCode });
      expect(again.status).toBe(401);
      const login = await request(app.getHttpServer())
        .post('/api/v1/auth/token')
        .send({ username: ownerUsername, password: OWNER_CHOSEN_PASSWORD, deviceToken: enrol.body.data.deviceToken });
      expect(login.status).toBe(200);
      const devices = await request(app.getHttpServer())
        .get('/api/v1/devices')
        .set('Authorization', `Bearer ${login.body.data.accessToken}`);
      expect(devices.status).toBe(200);
      const fresh = devices.body.data.find((d: { id: string }) => d.id === data.device.id);
      expect(fresh).toMatchObject({ deviceNo: 6, role: 'pos', enrolled: true, retiredAt: null });

      // Both audit rows name the platform admin; neither carries the code.
      const audit = await adminDs.query(
        `SELECT action, platform_admin_id, user_id, entity_id, before, after FROM audit_log
          WHERE tenant_id = $1 AND action IN ('device.retire', 'device.create') ORDER BY id`,
        [tenantId],
      );
      expect(audit.map((a: { action: string; entity_id: string }) => [a.action, a.entity_id])).toEqual([
        ['device.retire', 'pos1'],
        ['device.create', data.device.id],
      ]);
      for (const a of audit) {
        expect(a.platform_admin_id).toBe(adminId);
        expect(a.user_id).toBeNull();
        expect(JSON.stringify(a)).not.toContain(data.enrolCode);
      }
      expect(audit[0].after).toMatchObject({ replacedBy: data.device.id });
      expect(audit[0].after.forced).toBeUndefined();
      expect(audit[1].after).toMatchObject({ deviceNo: 6, role: 'pos', replaces: 'pos1' });
    });

    it('names the replacement by its new device_no when the label is omitted', async () => {
      const res = await replace(tenantId, 'pos1');
      expect(res.status).toBe(200);
      expect(res.body.data.device).toMatchObject({ label: 'POS #2', deviceNo: 2 });
    });

    it('takes a custom label', async () => {
      const res = await replace(tenantId, 'pos1', { label: 'เครื่องใหม่' });
      expect(res.status).toBe(200);
      expect(res.body.data.device.label).toBe('เครื่องใหม่');
    });

    it('refuses an open shift with 409 and changes nothing; force + note archives it uncounted', async () => {
      const shiftId = await seedOpenShift(adminDs, tenantId, 'pos1', { startingCash: 500 });

      const refused = await replace(tenantId, 'pos1');
      expect(refused.status).toBe(409);
      expect(refused.body.error.code).toBe('DEVICE_HAS_OPEN_SHIFT');
      const untouched = await adminDs.query(
        `SELECT retired_at FROM devices WHERE tenant_id = $1 AND id = 'pos1'`,
        [tenantId],
      );
      expect(untouched[0].retired_at).toBeNull();
      const count = await adminDs.query(
        `SELECT count(*)::int AS n FROM devices WHERE tenant_id = $1`,
        [tenantId],
      );
      expect(count[0].n).toBe(1);

      const forced = await replace(tenantId, 'pos1', { force: true, note: 'เครื่องหายระหว่างกะ' });
      expect(forced.status).toBe(200);
      const shift = await adminDs.query(
        `SELECT is_active, auto_archived, archived_at, closed_at FROM shifts WHERE tenant_id = $1 AND id = $2`,
        [tenantId, shiftId],
      );
      expect(shift[0]).toMatchObject({ is_active: false, auto_archived: true, closed_at: null });
      expect(shift[0].archived_at).not.toBeNull();
      const review = await adminDs.query(
        `SELECT kind, ref_id FROM owner_review_items WHERE tenant_id = $1`,
        [tenantId],
      );
      expect(review).toEqual([{ kind: 'shift_uncounted', ref_id: shiftId }]);
      const audit = await adminDs.query(
        `SELECT after FROM audit_log WHERE tenant_id = $1 AND action = 'device.retire'`,
        [tenantId],
      );
      expect(audit[0].after).toMatchObject({ forced: true, note: 'เครื่องหายระหว่างกะ', shiftId });
    });

    it('refuses unsent offline ops with 409; force + note leaves a device_force_retired review item', async () => {
      await adminDs.query(
        `UPDATE devices SET unsynced_ops = 3, unsynced_reported_at = now() WHERE tenant_id = $1 AND id = 'pos1'`,
        [tenantId],
      );
      const refused = await replace(tenantId, 'pos1');
      expect(refused.status).toBe(409);
      expect(refused.body.error.code).toBe('DEVICE_HAS_UNSYNCED_OPS');
      expect(refused.body.error.details).toMatchObject({ unsyncedOps: 3 });

      const forced = await replace(tenantId, 'pos1', { force: true, note: 'ล้างเบราว์เซอร์' });
      expect(forced.status).toBe(200);
      const review = await adminDs.query(
        `SELECT kind, ref_id, details FROM owner_review_items WHERE tenant_id = $1`,
        [tenantId],
      );
      expect(review).toHaveLength(1);
      expect(review[0]).toMatchObject({ kind: 'device_force_retired', ref_id: 'pos1' });
      expect(review[0].details).toMatchObject({ unsyncedOps: 3, note: 'ล้างเบราว์เซอร์' });
    });

    it('refuses a never-enrolled device (409 DEVICE_NOT_ENROLLED — reissue its code instead)', async () => {
      await adminDs.query(
        `INSERT INTO devices (tenant_id, id, label, device_no, role) VALUES ($1, 'bo-new', 'x', 2, 'backoffice')`,
        [tenantId],
      );
      const res = await replace(tenantId, 'bo-new');
      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('DEVICE_NOT_ENROLLED');
    });

    it('refuses a second replace of the same device and an unknown id; a lost reply is recoverable', async () => {
      const first = await replace(tenantId, 'pos1');
      expect(first.status).toBe(200);
      const second = await replace(tenantId, 'pos1');
      expect(second.status).toBe(409);
      expect(second.body.error.code).toBe('DEVICE_ALREADY_RETIRED');
      expect(second.body.error.details.retiredAt).toBe(first.body.data.retiredAt);

      const unknown = await replace(tenantId, 'nope');
      expect(unknown.status).toBe(404);
      expect(unknown.body.error.code).toBe('DEVICE_NOT_FOUND');

      // Had `first`'s reply been lost: the replacement was never enrolled, so reissue works.
      const reissue = await request(app.getHttpServer())
        .post(`/api/v1/platform/tenants/${tenantId}/devices/${first.body.data.device.id}/enrol-code`)
        .set('Authorization', `Bearer ${adminToken}`)
        .send();
      expect(reissue.status).toBe(200);
    });

    it('answers 400 for force without a note, and for a non-UUID tenant id', async () => {
      const noNote = await replace(tenantId, 'pos1', { force: true });
      expect(noNote.status).toBe(400);
      const badTenant = await replace('not-a-uuid', 'pos1');
      expect(badTenant.status).toBe(400);
      expect(badTenant.body.error.code).toBe('INVALID_TENANT_ID');
    });

    it("never reaches another tenant's device of the same id", async () => {
      const other = await provision('rplo');
      try {
        const otherEnrol = await request(app.getHttpServer())
          .post('/api/v1/auth/device')
          .send({ code: other.enrolCode });
        expect(otherEnrol.status).toBe(200);
        const before = await adminDs.query(
          `SELECT id, device_no, retired_at FROM devices WHERE tenant_id = $1 ORDER BY id`,
          [other.tenantId],
        );

        const res = await replace(tenantId, 'pos1');
        expect(res.status).toBe(200);

        const after = await adminDs.query(
          `SELECT id, device_no, retired_at FROM devices WHERE tenant_id = $1 ORDER BY id`,
          [other.tenantId],
        );
        expect(after).toEqual(before);
        const otherAudit = await adminDs.query(
          `SELECT 1 FROM audit_log WHERE tenant_id = $1 AND action IN ('device.retire', 'device.create')`,
          [other.tenantId],
        );
        expect(otherAudit).toHaveLength(0);
      } finally {
        await cleanup(other.tenantId);
      }
    });

    it('is refused with 403 PLATFORM_IP_FORBIDDEN from an IP outside the allowlist', async () => {
      const res = await request(app.getHttpServer())
        .post(`/api/v1/platform/tenants/${tenantId}/devices/pos1/replace`)
        .set('Authorization', `Bearer ${adminToken}`)
        .set('X-Forwarded-For', '203.0.113.195')
        .send({});
      expect(res.status).toBe(403);
      expect(res.body.error.code).toBe('PLATFORM_IP_FORBIDDEN');
      const rows = await adminDs.query(
        `SELECT retired_at FROM devices WHERE tenant_id = $1 AND id = 'pos1'`,
        [tenantId],
      );
      expect(rows[0].retired_at).toBeNull();
    });
  });
});
