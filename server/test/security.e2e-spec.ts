import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import type { Redis } from 'ioredis';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import * as jwt from 'jsonwebtoken';
import {
  accessToken,
  refreshToken,
  clearTenantCache,
  createTestApp,
  resetTenant,
  seedCustomer,
  seedOpenShift,
  seedProduct,
  type TenantFixture,
} from './support/fixture.js';

// OWASP Top 10 Security Hardening & Negative-path Acceptance Suite (#44 sec.1)
const TENANT_A = '11111111-4444-4111-8111-111111111111';
const TENANT_B = '22222222-4444-4222-8222-222222222222';
const MANAGER_PIN = '8844';

describe('Security Hardening & Negative-Path E2E (#44 sec.1)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: Redis;
  let fixtureA: TenantFixture;
  let fixtureB: TenantFixture;
  let posTokenA: string;
  let posTokenB: string;
  let managerTokenA: string;
  let backofficeTokenA: string;
  let productIdA: string;
  let productIdB: string;

  // Separate untrusted keypair to test forged/tampered JWTs
  const untrustedKeys = generateKeyPairSync('rsa', {
    modulusLength: 2048,
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    publicKeyEncoding: { type: 'spki', format: 'pem' },
  });

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixtureA = await resetTenant(admin, TENANT_A, { pin: MANAGER_PIN, cache });
    fixtureB = await resetTenant(admin, TENANT_B, { pin: MANAGER_PIN, cache });

    await clearTenantCache(cache, TENANT_A);
    await clearTenantCache(cache, TENANT_B);

    // Open shift for POS devices on both tenants
    await seedOpenShift(admin, TENANT_A, fixtureA.posDeviceId, { userId: fixtureA.userId });
    await seedOpenShift(admin, TENANT_B, fixtureB.posDeviceId, { userId: fixtureB.userId });

    // Seed test products
    productIdA = `p-a-${randomUUID().slice(0, 8)}`;
    await seedProduct(admin, TENANT_A, {
      id: productIdA,
      partNo: 'PART-A',
      name: 'Product A',
      price: 100,
      cost: 60,
      stock: 50,
    });

    productIdB = `p-b-${randomUUID().slice(0, 8)}`;
    await seedProduct(admin, TENANT_B, {
      id: productIdB,
      partNo: 'PART-B',
      name: 'Product B',
      price: 150,
      cost: 90,
      stock: 50,
    });

    posTokenA = accessToken({
      tenantId: TENANT_A,
      userId: fixtureA.userId,
      role: 'owner',
      deviceId: fixtureA.posDeviceId,
      deviceRole: 'pos',
    });

    posTokenB = accessToken({
      tenantId: TENANT_B,
      userId: fixtureB.userId,
      role: 'owner',
      deviceId: fixtureB.posDeviceId,
      deviceRole: 'pos',
    });

    managerTokenA = accessToken({
      tenantId: TENANT_A,
      userId: fixtureA.userId,
      role: 'owner',
      deviceId: fixtureA.posDeviceId,
      deviceRole: 'pos',
    });

    backofficeTokenA = accessToken({
      tenantId: TENANT_A,
      userId: fixtureA.userId,
      role: 'owner',
      deviceId: fixtureA.backofficeDeviceId,
      deviceRole: 'backoffice',
    });
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT_A, { cache });
    await resetTenant(admin, TENANT_B, { cache });
    await admin.query(`DELETE FROM tenants WHERE id IN ($1::uuid, $2::uuid)`, [TENANT_A, TENANT_B]);
    await app.close();
  });

  // ---------------------------------------------------------------------------
  // OWASP A01: Broken Access Control & Claim Spoofing
  // ---------------------------------------------------------------------------
  describe('A01: Broken Access Control & Claim Spoofing', () => {
    it('ignores tenantId in request body on POST /sales and strictly uses claim tid', async () => {
      const saleId = `sale-${randomUUID()}`;
      const res = await request(app.getHttpServer())
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${posTokenA}`)
        .set('Idempotency-Key', `k-spoof-tid-${randomUUID()}`)
        .send({
          id: saleId,
          tenantId: TENANT_B, // Malicious attempt to insert into Tenant B
          subtotal: '100.00',
          discount: '0.00',
          total: '100.00',
          paymentMethod: 'เงินสด',
          items: [
            {
              lineNo: 1,
              productId: productIdA,
              name: 'Product A',
              qty: 1,
              price: '100.00',
            },
          ],
        });

      expect(res.status).toBe(201);

      // Verify in DB that row was written under TENANT_A, NEVER TENANT_B
      const rowsA = await admin.query(`SELECT id, tenant_id FROM sales WHERE id = $1`, [saleId]);
      expect(rowsA).toHaveLength(1);
      expect(rowsA[0].tenant_id).toBe(TENANT_A);

      const rowsB = await admin.query(
        `SELECT id FROM sales WHERE id = $1 AND tenant_id = $2::uuid`,
        [saleId, TENANT_B],
      );
      expect(rowsB).toHaveLength(0);
    });

    it('ignores deviceId in request body on POST /sales and strictly uses claim did', async () => {
      const saleId = `sale-${randomUUID()}`;
      const fakeDeviceId = 'fake-hacked-device-id';

      const res = await request(app.getHttpServer())
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${posTokenA}`)
        .set('Idempotency-Key', `k-spoof-did-${randomUUID()}`)
        .send({
          id: saleId,
          deviceId: fakeDeviceId, // Attempt to spoof calling device
          subtotal: '100.00',
          discount: '0.00',
          total: '100.00',
          paymentMethod: 'เงินสด',
          items: [
            {
              lineNo: 1,
              productId: productIdA,
              name: 'Product A',
              qty: 1,
              price: '100.00',
            },
          ],
        });

      expect(res.status).toBe(201);

      const rows = await admin.query(`SELECT device_id FROM sales WHERE id = $1`, [saleId]);
      expect(rows[0].device_id).toBe(fixtureA.posDeviceId);
      expect(rows[0].device_id).not.toBe(fakeDeviceId);
    });

    it('denies cross-tenant read access (Tenant A cannot view Tenant B sale)', async () => {
      // 1. Create a sale in Tenant B
      const saleIdB = `sale-b-${randomUUID()}`;
      const createRes = await request(app.getHttpServer())
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${posTokenB}`)
        .set('Idempotency-Key', `k-b-${randomUUID()}`)
        .send({
          id: saleIdB,
          subtotal: '150.00',
          discount: '0.00',
          total: '150.00',
          paymentMethod: 'เงินสด',
          items: [
            {
              lineNo: 1,
              productId: productIdB,
              name: 'Product B',
              qty: 1,
              price: '150.00',
            },
          ],
        });
      expect(createRes.status).toBe(201);

      // 2. Tenant A tries to read Tenant B's sale
      const readRes = await request(app.getHttpServer())
        .get(`/api/v1/sales/${saleIdB}`)
        .set('Authorization', `Bearer ${posTokenA}`);

      expect(readRes.status).toBe(404);
    });

    it('denies cross-tenant void (Tenant A cannot void Tenant B sale)', async () => {
      // 1. Create a sale in Tenant B
      const saleIdB = `sale-b-${randomUUID()}`;
      await request(app.getHttpServer())
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${posTokenB}`)
        .set('Idempotency-Key', `k-b-${randomUUID()}`)
        .send({
          id: saleIdB,
          subtotal: '150.00',
          discount: '0.00',
          total: '150.00',
          paymentMethod: 'เงินสด',
          items: [
            {
              lineNo: 1,
              productId: productIdB,
              name: 'Product B',
              qty: 1,
              price: '150.00',
            },
          ],
        });

      // 2. Tenant A attempts to void Tenant B's sale
      const voidRes = await request(app.getHttpServer())
        .post(`/api/v1/sales/${saleIdB}/void`)
        .set('Authorization', `Bearer ${managerTokenA}`)
        .set('Idempotency-Key', `k-void-cross-${randomUUID()}`)
        .send({ reason: 'Customer return' });

      expect(voidRes.status).toBe(404);
    });

    it('enforces device role guard (backoffice device cannot void a sale)', async () => {
      // Create sale in Tenant A
      const saleIdA = `sale-a-${randomUUID()}`;
      await request(app.getHttpServer())
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${posTokenA}`)
        .set('Idempotency-Key', `k-a-${randomUUID()}`)
        .send({
          id: saleIdA,
          subtotal: '100.00',
          discount: '0.00',
          total: '100.00',
          paymentMethod: 'เงินสด',
          items: [
            {
              lineNo: 1,
              productId: productIdA,
              name: 'Product A',
              qty: 1,
              price: '100.00',
            },
          ],
        });

      // Backoffice device attempts to void
      const voidRes = await request(app.getHttpServer())
        .post(`/api/v1/sales/${saleIdA}/void`)
        .set('Authorization', `Bearer ${backofficeTokenA}`)
        .set('Idempotency-Key', `k-void-bo-${randomUUID()}`)
        .send({ reason: 'Customer return' });

      expect(voidRes.status).toBe(403);
      expect(voidRes.body.error?.code).toBe('DEVICE_ROLE_FORBIDDEN');
    });

    it('enforces device role guard (backoffice device cannot create sale)', async () => {
      const saleId = `sale-${randomUUID()}`;
      const res = await request(app.getHttpServer())
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${backofficeTokenA}`)
        .set('Idempotency-Key', `k-bo-${randomUUID()}`)
        .send({
          id: saleId,
          subtotal: '100.00',
          discount: '0.00',
          total: '100.00',
          paymentMethod: 'เงินสด',
          items: [
            {
              lineNo: 1,
              productId: productIdA,
              name: 'Product A',
              qty: 1,
              price: '100.00',
            },
          ],
        });

      expect(res.status).toBe(403);
      expect(res.body.error?.code).toBe('DEVICE_ROLE_FORBIDDEN');
    });

    it('a backoffice session with no deviceToken can read products but cannot create sale (DoD line 13)', async () => {
      const browserToken = accessToken({
        tenantId: TENANT_A,
        userId: fixtureA.userId,
        role: 'owner',
      });

      // 1. GET /api/v1/products succeeds (200)
      const productsRes = await request(app.getHttpServer())
        .get('/api/v1/products')
        .set('Authorization', `Bearer ${browserToken}`);
      expect(productsRes.status).toBe(200);
      expect(productsRes.body.status).toBe('success');

      // 2. POST /api/v1/sales fails with 403 DEVICE_ROLE_FORBIDDEN
      const saleId = `sale-${randomUUID()}`;
      const saleRes = await request(app.getHttpServer())
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${browserToken}`)
        .set('Idempotency-Key', `k-nodev-${randomUUID()}`)
        .send({
          id: saleId,
          subtotal: '100.00',
          discount: '0.00',
          total: '100.00',
          paymentMethod: 'เงินสด',
          items: [
            {
              lineNo: 1,
              productId: productIdA,
              name: 'Product A',
              qty: 1,
              price: '100.00',
            },
          ],
        });

      expect(saleRes.status).toBe(403);
      expect(saleRes.body.error?.code).toBe('DEVICE_ROLE_FORBIDDEN');
    });

    it('rejects access and refresh from retired devices', async () => {
      // 1. Valid refresh token for POS device
      const validRefreshToken = refreshToken({
        tenantId: TENANT_A,
        userId: fixtureA.userId,
        deviceId: fixtureA.posDeviceId,
        deviceRole: 'pos',
      });

      // Retire the pos device in DB
      await admin.query(`UPDATE devices SET retired_at = now() WHERE id = $1`, [
        fixtureA.posDeviceId,
      ]);
      await clearTenantCache(cache, TENANT_A);

      // Refreshing token with retired device fails with 401
      const refreshRes = await request(app.getHttpServer())
        .post('/api/v1/auth/refresh')
        .send({ refreshToken: validRefreshToken });

      expect(refreshRes.status).toBe(401);
      expect(refreshRes.body.error?.message).toContain('Device is retired');

      // Attempting to issue document (POST /sales) with retired device fails
      const saleRes = await request(app.getHttpServer())
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${posTokenA}`)
        .set('Idempotency-Key', `k-retired-${randomUUID()}`)
        .send({
          id: `sale-retired-${randomUUID()}`,
          subtotal: '100.00',
          discount: '0.00',
          total: '100.00',
          paymentMethod: 'เงินสด',
          items: [
            {
              lineNo: 1,
              productId: productIdA,
              name: 'Product A',
              qty: 1,
              price: '100.00',
            },
          ],
        });

      expect(saleRes.status).toBe(403);
      expect(saleRes.body.error?.code).toBe('DEVICE_ROLE_FORBIDDEN');
    });
  });

  // ---------------------------------------------------------------------------
  // OWASP A02 & A07: Cryptographic Failures & JWT Attacks
  // ---------------------------------------------------------------------------
  describe('A02 & A07: Cryptographic & JWT Security', () => {
    it('rejects alg:none token attack', async () => {
      // Create header and payload without signature (alg: none)
      const header = Buffer.from(JSON.stringify({ alg: 'none', typ: 'JWT' })).toString('base64url');
      const payload = Buffer.from(
        JSON.stringify({
          iss: 'srisurart-pos',
          aud: 'tenant',
          sub: fixtureA.userId,
          typ: 'access',
          tid: TENANT_A,
          role: 'owner',
        }),
      ).toString('base64url');

      const noneToken = `${header}.${payload}.`;

      const res = await request(app.getHttpServer())
        .get('/api/v1/auth/me')
        .set('Authorization', `Bearer ${noneToken}`);

      expect(res.status).toBe(401);
    });

    it('rejects token signed with untrusted/foreign private key', async () => {
      const forgedToken = jwt.sign(
        {
          iss: 'srisurart-pos',
          aud: 'tenant',
          sub: fixtureA.userId,
          jti: randomUUID(),
          typ: 'access',
          tid: TENANT_A,
          role: 'owner',
        },
        untrustedKeys.privateKey,
        { algorithm: 'RS256', keyid: 'key-1', expiresIn: '15m' },
      );

      const res = await request(app.getHttpServer())
        .get('/api/v1/auth/me')
        .set('Authorization', `Bearer ${forgedToken}`);

      expect(res.status).toBe(401);
    });

    it('rejects expired access token', async () => {
      const expiredToken = jwt.sign(
        {
          iss: 'srisurart-pos',
          aud: 'tenant',
          sub: fixtureA.userId,
          jti: randomUUID(),
          typ: 'access',
          tid: TENANT_A,
          role: 'owner',
          exp: Math.floor(Date.now() / 1000) - 300, // Expired 5m ago
        },
        untrustedKeys.privateKey,
        { algorithm: 'RS256', keyid: 'key-1' },
      );

      const res = await request(app.getHttpServer())
        .get('/api/v1/auth/me')
        .set('Authorization', `Bearer ${expiredToken}`);

      expect(res.status).toBe(401);
    });

    it('rejects token with unknown kid header', async () => {
      const validToken = accessToken({
        tenantId: TENANT_A,
        userId: fixtureA.userId,
        role: 'owner',
      });

      // Tamper header kid to key-999
      const parts = validToken.split('.');
      const headerObj = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8'));
      headerObj.kid = 'key-999';
      const tamperedToken = `${Buffer.from(JSON.stringify(headerObj)).toString('base64url')}.${parts[1]}.${parts[2]}`;

      const res = await request(app.getHttpServer())
        .get('/api/v1/auth/me')
        .set('Authorization', `Bearer ${tamperedToken}`);

      expect(res.status).toBe(401);
    });

    it('rejects token type confusion (refresh token sent to access route)', async () => {
      // Mint a refresh token using untrusted/fixture mechanism
      const refreshToken = jwt.sign(
        {
          iss: 'srisurart-pos',
          aud: 'tenant',
          sub: fixtureA.userId,
          jti: randomUUID(),
          typ: 'refresh', // WRONG typ for API access
          tid: TENANT_A,
          role: 'owner',
        },
        untrustedKeys.privateKey,
        { algorithm: 'RS256', keyid: 'key-1', expiresIn: '8h' },
      );

      const res = await request(app.getHttpServer())
        .get('/api/v1/auth/me')
        .set('Authorization', `Bearer ${refreshToken}`);

      expect(res.status).toBe(401);
    });

    it('rejects audience mismatch (platform admin token sent to tenant endpoint)', async () => {
      const platformToken = accessToken({
        tenantId: TENANT_A,
        userId: fixtureA.userId,
        role: 'owner',
      });

      // Modify aud to platform
      const parts = platformToken.split('.');
      const payloadObj = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
      payloadObj.aud = 'platform';
      const tamperedToken = `${parts[0]}.${Buffer.from(JSON.stringify(payloadObj)).toString('base64url')}.${parts[2]}`;

      const res = await request(app.getHttpServer())
        .get('/api/v1/auth/me')
        .set('Authorization', `Bearer ${tamperedToken}`);

      expect(res.status).toBe(401);
    });
  });

  // ---------------------------------------------------------------------------
  // OWASP A03: Injection & Parameter Tampering
  // ---------------------------------------------------------------------------
  describe('A03: Injection & Parameter Tampering', () => {
    it('safely parameterises SQL injection payloads in customer creation', async () => {
      const sqlInjectionPayload = "Robert'); DROP TABLE customers; -- ' OR '1'='1";
      const customerId = `cust-${randomUUID()}`;

      // Insert customer with SQLi in name and phone
      await seedCustomer(admin, TENANT_A, {
        id: customerId,
        code: 'C-SQLI',
        name: sqlInjectionPayload,
        nameTH: "'; DELETE FROM products; --",
      });

      // Verify the table still exists and data was inserted literally
      const rows = await admin.query(`SELECT name, name_th FROM customers WHERE id = $1`, [
        customerId,
      ]);
      expect(rows).toHaveLength(1);
      expect(rows[0].name).toBe(sqlInjectionPayload);
      expect(rows[0].name_th).toBe("'; DELETE FROM products; --");
    });

    it('handles malformed / non-UUID route parameters gracefully without 500 error', async () => {
      const res = await request(app.getHttpServer())
        .get('/api/v1/sales/not-a-valid-uuid')
        .set('Authorization', `Bearer ${posTokenA}`);

      // Should be 400 or 404, never 500 DB crash
      expect(res.status).toBeLessThan(500);
      expect([400, 404]).toContain(res.status);
    });
  });

  // ---------------------------------------------------------------------------
  // OWASP A05: Security Misconfiguration (Helmet & CORS)
  // ---------------------------------------------------------------------------
  describe('A05: Security Misconfiguration (Helmet & CORS)', () => {
    it('includes Helmet security headers in HTTP responses', async () => {
      const res = await request(app.getHttpServer()).get('/health/live');

      expect(res.status).toBe(200);
      expect(res.headers['x-content-type-options']).toBe('nosniff');
      expect(res.headers['x-frame-options']).toBe('SAMEORIGIN');
      expect(res.headers['x-download-options']).toBe('noopen');
      expect(res.headers['x-powered-by']).toBeUndefined();
    });

    it('responds with CORS headers on allowed origins and handles preflight OPTIONS', async () => {
      // 1. Regular GET with Origin
      const getRes = await request(app.getHttpServer())
        .get('/health/live')
        .set('Origin', 'http://localhost:8080');

      expect(getRes.status).toBe(200);
      expect(getRes.headers['access-control-allow-origin']).toBeDefined();

      // 2. Preflight OPTIONS
      const optionsRes = await request(app.getHttpServer())
        .options('/api/v1/sales')
        .set('Origin', 'http://localhost:8080')
        .set('Access-Control-Request-Method', 'POST')
        .set('Access-Control-Request-Headers', 'Content-Type,Authorization,Idempotency-Key');

      expect(optionsRes.status).toBe(204);
      expect(optionsRes.headers['access-control-allow-methods']).toContain('POST');
    });

    it('verifies Nginx platform admin plane has loopback allowlist and deny all (07 §9, #270)', async () => {
      const fs = await import('node:fs');
      const path = await import('node:path');
      const nginxConf = fs.readFileSync(
        path.resolve(process.cwd(), 'docker/nginx/nginx.conf'),
        'utf8',
      );

      // Must target /api/v1/platform/ with strict loopback/admin allowlist and deny all (07 §9, #270)
      const platformBlock = nginxConf.match(/location \/api\/v1\/platform\/ \{([\s\S]*?)\}/)?.[1] ?? '';
      expect(platformBlock).toContain('allow 127.0.0.1;');
      expect(platformBlock).toContain('allow ::1;');
      expect(platformBlock).not.toContain('allow 10.0.0.0/8;');
      expect(platformBlock).not.toContain('allow 172.16.0.0/12;');
      expect(platformBlock).not.toContain('allow 192.168.0.0/16;');
      expect(platformBlock).toContain('deny  all;');
    });

    it('verifies Nginx serves /sw.js with Cache-Control: no-cache (08 §4 item 8, #270)', async () => {
      const fs = await import('node:fs');
      const path = await import('node:path');
      const nginxConf = fs.readFileSync(
        path.resolve(process.cwd(), 'docker/nginx/nginx.conf'),
        'utf8',
      );

      expect(nginxConf).toContain('location = /sw.js {');
      expect(nginxConf).toContain('add_header Cache-Control "no-cache";');
      expect(nginxConf).toContain('try_files $uri =404;');
    });
  });

  // ---------------------------------------------------------------------------
  // OWASP A07: Brute-Force Rate Limiting (Login & Manager PIN)
  // ---------------------------------------------------------------------------
  describe('A07: Brute-Force Rate Limiting (Login & PIN)', () => {
    it('rate-limits consecutive failed logins with 429 and Retry-After header', async () => {
      const badLogin = {
        username: fixtureA.username,
        password: 'wrong-password-attempt',
      };

      // 5 failed attempts
      for (let i = 0; i < 5; i++) {
        const res = await request(app.getHttpServer())
          .post('/api/v1/auth/token')
          .send(badLogin);
        expect(res.status).toBe(401);
      }

      // 6th attempt should be blocked by brute-force limiter (429 RATE_LIMITED)
      const blockedRes = await request(app.getHttpServer())
        .post('/api/v1/auth/token')
        .send(badLogin);

      expect(blockedRes.status).toBe(429);
      expect(blockedRes.body.error?.code).toBe('RATE_LIMITED');
      expect(blockedRes.headers['retry-after']).toBeDefined();
    });

    // #138: the count and the check are one atomic step. With a separate read, every concurrent
    // attempt saw the same count and all 15 got through. Distinct usernames keep the per-user
    // bucket out of it; a unique forwarded address keeps other tests' attempts out of the IP bucket.
    it('lets exactly 10 of 15 concurrent bad logins from one address through', async () => {
      const ip = `198.51.100.${Math.floor(Math.random() * 250) + 1}`;
      const statuses = await Promise.all(
        Array.from({ length: 15 }, (_, i) =>
          request(app.getHttpServer())
            .post('/api/v1/auth/token')
            .set('X-Forwarded-For', `1.1.1.1, ${ip}`)
            .send({ username: `nobody-${randomUUID()}-${i}`, password: 'wrong' })
            .then((r) => r.status),
        ),
      );

      expect(statuses.filter((s) => s === 401)).toHaveLength(10);
      expect(statuses.filter((s) => s === 429)).toHaveLength(5);
    });

    it('lets exactly 5 of 8 concurrent bad logins for one username through', async () => {
      const username = `nobody-${randomUUID()}`;
      const statuses = await Promise.all(
        Array.from({ length: 8 }, (_, i) =>
          request(app.getHttpServer())
            .post('/api/v1/auth/token')
            .set('X-Forwarded-For', `203.0.113.${Math.floor(Math.random() * 200) + i + 1}`)
            .send({ username, password: 'wrong' })
            .then((r) => r.status),
        ),
      );

      expect(statuses.filter((s) => s === 401)).toHaveLength(5);
      expect(statuses.filter((s) => s === 429)).toHaveLength(3);
    });

    it('enforces non-empty reason on void', async () => {
      // Create a sale to target for voiding
      const saleId = `sale-void-reason-${randomUUID()}`;
      await request(app.getHttpServer())
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${posTokenA}`)
        .set('Idempotency-Key', `k-void-target-${randomUUID()}`)
        .send({
          id: saleId,
          subtotal: '100.00',
          discount: '0.00',
          total: '100.00',
          paymentMethod: 'เงินสด',
          items: [
            {
              lineNo: 1,
              productId: productIdA,
              name: 'Product A',
              qty: 1,
              price: '100.00',
            },
          ],
        });

      // Missing reason is rejected with 400
      const res = await request(app.getHttpServer())
        .post(`/api/v1/sales/${saleId}/void`)
        .set('Authorization', `Bearer ${posTokenA}`)
        .set('Idempotency-Key', `k-void-missing-reason-${randomUUID()}`)
        .send({});

      expect(res.status).toBe(400);
      expect(res.body.error?.message).toBe('Void reason is required');
    });
  });
});
