import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import type { Redis } from 'ioredis';
import { randomUUID } from 'node:crypto';
import { signJwt } from '../src/common/jwt.js';
import { hashPassword } from '../src/common/password.js';
import { APP_CONFIG, type AppConfig } from '../src/config/config.js';
import { createTestApp } from './support/fixture.js';
import { OWNER_CHOSEN_PASSWORD } from './support/owner-password.js';

/**
 * #443 PR3 — owner password lifecycle v2, end to end against the real Postgres/Redis:
 * server-generated temporary password (7 d at provisioning, 24 h at reset) → login yields a
 * restricted `pwchange` token that only `POST /auth/change-password` accepts → the owner's
 * own password → full session. A reset kills the old password and every earlier refresh token.
 */
describe('owner password lifecycle v2 (#443 PR3)', () => {
  let app: INestApplication;
  let adminDs: DataSource;
  let cache: Redis;
  let config: AppConfig;
  let adminId: string;
  let adminToken: string;
  const tenants: string[] = [];

  const http = () => request(app.getHttpServer());

  beforeAll(async () => {
    ({ app, admin: adminDs, cache } = await createTestApp());
    config = app.get<AppConfig>(APP_CONFIG);
    adminId = randomUUID();
    await adminDs.query(
      `INSERT INTO platform_admins (id, username, password_hash, display_name, is_active)
       VALUES ($1, $2, $3, 'PR3 Admin', true)`,
      [adminId, `admin-${adminId.slice(0, 8)}`, await hashPassword('platform-secret-123')],
    );
    adminToken = signJwt(
      { iss: 'srisurart-pos', aud: 'platform', sub: adminId, username: `admin-${adminId.slice(0, 8)}` },
      config.jwtPlatformSecret,
    );
  });

  afterAll(async () => {
    for (const tid of tenants) {
      for (const t of ['audit_log', 'idempotency_keys', 'devices', 'categories', 'settings', 'users']) {
        await adminDs.query(`DELETE FROM ${t} WHERE tenant_id = $1`, [tid]);
      }
      await adminDs.query(`DELETE FROM tenants WHERE id = $1`, [tid]);
      await cache.del(`t:${tid}:status`);
    }
    await adminDs.query(`DELETE FROM audit_log WHERE platform_admin_id = $1`, [adminId]);
    await adminDs.query(`DELETE FROM platform_admins WHERE id = $1`, [adminId]);
    await cache.del(`pa:${adminId}:exists`);
    await app?.close();
  });

  const provision = async () => {
    const code = `pw3-${randomUUID().slice(0, 8)}`;
    const res = await http()
      .post('/api/v1/platform/tenants')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ code, shopName: 'ร้านทดสอบ รหัสชั่วคราว', ownerUsername: `owner_${code}`, ownerDisplayName: 'เจ้าของ' });
    expect(res.status).toBe(201);
    tenants.push(res.body.data.tenantId);
    return {
      tenantId: res.body.data.tenantId as string,
      username: `owner_${code}`,
      tempPassword: res.body.data.tempPassword as string,
      enrolCode: res.body.data.enrolCode as string,
      body: res.body,
    };
  };
  const login = (username: string, password: string, deviceToken?: string) =>
    http().post('/api/v1/auth/token').send({ username, password, ...(deviceToken ? { deviceToken } : {}) });
  const change = (token: string, newPassword: unknown) =>
    http().post('/api/v1/auth/change-password').set('Authorization', `Bearer ${token}`).send({ newPassword });
  const reset = (tenantId: string) =>
    http().post(`/api/v1/platform/tenants/${tenantId}/owner/temp-password`).set('Authorization', `Bearer ${adminToken}`).send();
  const userRow = async (tenantId: string) =>
    (await adminDs.query(
      `SELECT password_hash, must_change_password, temp_password_expires_at, password_changed_at
         FROM users WHERE tenant_id = $1`,
      [tenantId],
    ))[0];

  it('provisioning returns a 16-char temporary password once (7 days), stores only its hash, audits no secret', async () => {
    const t = await provision();
    expect(t.tempPassword).toMatch(/^[A-HJ-NP-Za-km-z2-9]{16}$/);
    const expires = Date.parse(t.body.data.tempPasswordExpiresAt);
    expect(expires - Date.now()).toBeGreaterThan(7 * 86400_000 - 120_000);
    expect(expires - Date.now()).toBeLessThanOrEqual(7 * 86400_000 + 60_000);

    const row = await userRow(t.tenantId);
    expect(row.must_change_password).toBe(true);
    expect(row.password_hash).toMatch(/^\$argon2id\$/);
    expect(row.password_hash).not.toContain(t.tempPassword);

    const audit = await adminDs.query(`SELECT * FROM audit_log WHERE tenant_id = $1`, [t.tenantId]);
    expect(audit.length).toBeGreaterThan(0);
    expect(JSON.stringify(audit)).not.toContain(t.tempPassword);

    // The read endpoint never shows it again.
    const detail = await http().get(`/api/v1/platform/tenants/${t.tenantId}`).set('Authorization', `Bearer ${adminToken}`);
    expect(detail.status).toBe(200);
    expect(JSON.stringify(detail.body)).not.toContain(t.tempPassword);
    expect(JSON.stringify(detail.body)).not.toMatch(/password/i);
  });

  it('a temporary password buys only a pwchange token, refused on every other route', async () => {
    const t = await provision();
    const res = await login(t.username, t.tempPassword);
    expect(res.status).toBe(200);
    expect(res.body.data.passwordChangeRequired).toBe(true);
    expect(res.body.data.accessToken).toBeUndefined();
    expect(res.body.data.refreshToken).toBeUndefined();
    const pwchange = res.body.data.passwordChangeToken as string;
    expect(JSON.parse(Buffer.from(pwchange.split('.')[1], 'base64url').toString()).typ).toBe('pwchange');

    const bearer = { Authorization: `Bearer ${pwchange}` };
    for (const [method, path] of [
      ['get', '/api/v1/products'],
      ['get', '/api/v1/auth/me'],
      ['get', '/api/v1/customers'],
      ['get', '/api/v1/devices'],
      ['post', '/api/v1/sales'],
      ['post', '/api/v1/shifts/open'],
      ['post', '/api/v1/devices'],
      ['post', '/api/v1/sync/discards'],
    ] as const) {
      const r = await http()[method](path).set(bearer).set('Idempotency-Key', `k-${randomUUID()}`).send({});
      expect({ path, status: r.status }).toEqual({ path, status: 401 });
    }
    // Nor does it refresh, in the body or as a bearer.
    expect((await http().post('/api/v1/auth/refresh').send({ refreshToken: pwchange })).status).toBe(401);
    expect((await http().post('/api/v1/auth/refresh').set(bearer).send({})).status).toBe(401);
    // Nor the platform plane.
    expect((await http().get('/api/v1/platform/tenants').set(bearer)).status).toBe(401);
    // An access token is refused by change-password (typ must be pwchange).
    const other = await provision();
    const session = await change(
      (await login(other.username, other.tempPassword)).body.data.passwordChangeToken,
      OWNER_CHOSEN_PASSWORD,
    );
    expect((await change(session.body.data.accessToken, 'another long passphrase')).status).toBe(401);
  });

  it('rejects weak / common / too long / same-as-temp new passwords and leaves the row untouched', async () => {
    const t = await provision();
    const token = (await login(t.username, t.tempPassword)).body.data.passwordChangeToken;
    const before = await userRow(t.tenantId);
    for (const [pw, reason] of [
      ['short', 'too_short'],
      ['x'.repeat(129), 'too_long'],
      ['unbelievable', 'common'],
      ['srisurart-owner-2569', 'common'],
      [t.tempPassword, 'same_as_temp'],
    ]) {
      const r = await change(token, pw);
      expect({ pw: pw.slice(0, 20), status: r.status, code: r.body.error?.code, reason: r.body.error?.details?.reason })
        .toEqual({ pw: pw.slice(0, 20), status: 400, code: 'WEAK_PASSWORD', reason });
    }
    expect(await userRow(t.tenantId)).toEqual(before);
  });

  it('change → full session; the token is single-use; the temp password is dead; banner field is set', async () => {
    const t = await provision();
    const token = (await login(t.username, t.tempPassword)).body.data.passwordChangeToken;
    const ok = await change(token, OWNER_CHOSEN_PASSWORD);
    expect(ok.status).toBe(200);
    expect(ok.body.data.accessToken).toBeDefined();
    expect(ok.body.data.refreshToken).toBeDefined();
    expect(JSON.stringify(ok.body)).not.toContain(OWNER_CHOSEN_PASSWORD);

    expect((await http().get('/api/v1/products').set('Authorization', `Bearer ${ok.body.data.accessToken}`)).status).toBe(200);
    // The refresh token change-password returned is valid (same-second iat survives).
    expect((await http().post('/api/v1/auth/refresh').send({ refreshToken: ok.body.data.refreshToken })).status).toBe(200);

    expect((await change(token, 'a second new passphrase')).status).toBe(401);
    expect((await login(t.username, t.tempPassword)).status).toBe(401);

    const again = await login(t.username, OWNER_CHOSEN_PASSWORD);
    expect(again.status).toBe(200);
    expect(again.body.data.passwordChangeRequired).toBeUndefined();
    expect(Date.parse(again.body.data.passwordChangedAt)).toBeGreaterThan(Date.now() - 60_000);

    const row = await userRow(t.tenantId);
    expect(row).toMatchObject({ must_change_password: false, temp_password_expires_at: null });
    expect(row.password_changed_at).not.toBeNull();

    const audit = await adminDs.query(
      `SELECT * FROM audit_log WHERE tenant_id = $1 AND action = 'auth.password_changed'`,
      [t.tenantId],
    );
    expect(audit).toHaveLength(1);
    const all = JSON.stringify(await adminDs.query(`SELECT * FROM audit_log WHERE tenant_id = $1`, [t.tenantId]));
    expect(all).not.toContain(OWNER_CHOSEN_PASSWORD);
    expect(all).not.toContain(t.tempPassword);
  });

  it('an expired temporary password is refused with TEMP_PASSWORD_EXPIRED (only with the right password)', async () => {
    const t = await provision();
    await adminDs.query(
      `UPDATE users SET temp_password_expires_at = now() - interval '1 second' WHERE tenant_id = $1`,
      [t.tenantId],
    );
    const r = await login(t.username, t.tempPassword);
    expect(r.status).toBe(401);
    expect(r.body.error.code).toBe('TEMP_PASSWORD_EXPIRED');
    const wrong = await login(t.username, 'not-the-temp-password');
    expect(wrong.status).toBe(401);
    expect(wrong.body.error.code).not.toBe('TEMP_PASSWORD_EXPIRED');
  });

  it('reset: new 24 h temp password, old password and old refresh tokens die at once, audited without the secret', async () => {
    const t = await provision();
    const first = await change((await login(t.username, t.tempPassword)).body.data.passwordChangeToken, OWNER_CHOSEN_PASSWORD);
    const oldRefresh = first.body.data.refreshToken as string;
    // `iat` is whole seconds and the rule is strict `<`: step past the second of the change.
    await new Promise((r) => setTimeout(r, 1100));

    const res = await reset(t.tenantId);
    expect(res.status).toBe(200);
    expect(res.body.data.ownerUsername).toBe(t.username);
    const newTemp = res.body.data.tempPassword as string;
    expect(newTemp).toMatch(/^[A-HJ-NP-Za-km-z2-9]{16}$/);
    const ttl = Date.parse(res.body.data.tempPasswordExpiresAt) - Date.now();
    expect(ttl).toBeGreaterThan(86400_000 - 120_000);
    expect(ttl).toBeLessThanOrEqual(86400_000 + 60_000);

    expect((await login(t.username, OWNER_CHOSEN_PASSWORD)).status).toBe(401);
    const refreshed = await http().post('/api/v1/auth/refresh').send({ refreshToken: oldRefresh });
    expect(refreshed.status).toBe(401);
    const rejected = await adminDs.query(
      `SELECT before FROM audit_log WHERE tenant_id = $1 AND action = 'auth.refresh_rejected'`,
      [t.tenantId],
    );
    expect(rejected.map((r: { before: unknown }) => r.before)).toContainEqual({ reason: 'password_changed' });

    const issued = await adminDs.query(
      `SELECT * FROM audit_log WHERE tenant_id = $1 AND action = 'platform.owner.temp_password_issued'`,
      [t.tenantId],
    );
    expect(issued).toHaveLength(1);
    expect(issued[0].platform_admin_id).toBe(adminId);
    expect(JSON.stringify(issued)).not.toContain(newTemp);

    const pw = await login(t.username, newTemp);
    expect(pw.body.data.passwordChangeRequired).toBe(true);
  });

  it('a pwchange token of a temp password that a reset replaced cannot change the password', async () => {
    const t = await provision();
    const staleToken = (await login(t.username, t.tempPassword)).body.data.passwordChangeToken;
    await new Promise((r) => setTimeout(r, 1100));
    expect((await reset(t.tenantId)).status).toBe(200);
    expect((await change(staleToken, OWNER_CHOSEN_PASSWORD)).status).toBe(401);
    expect((await userRow(t.tenantId)).must_change_password).toBe(true);
  });

  it('reset validates the tenant id and names a missing tenant', async () => {
    const bad = await reset('not-a-uuid');
    expect(bad.status).toBe(400);
    expect(bad.body.error.code).toBe('INVALID_TENANT_ID');
    expect((await reset(randomUUID())).status).toBe(404);
  });

  it('an owner on a temporary password cannot act through X-Device-Token, nor log in past the change with one', async () => {
    const t = await provision();
    const enrol = await http().post('/api/v1/auth/device').send({ code: t.enrolCode });
    expect(enrol.status).toBe(200);
    const deviceToken = enrol.body.data.deviceToken as string;

    const push = await http().post('/api/v1/sync/push').set('X-Device-Token', deviceToken).send({ ops: [] });
    expect(push.status).toBe(403);
    expect(push.body.error.code).toBe('PASSWORD_CHANGE_REQUIRED');
    const discards = await http().post('/api/v1/sync/discards').set('X-Device-Token', deviceToken).send({});
    expect(discards.status).toBe(403);
    expect(discards.body.error.code).toBe('PASSWORD_CHANGE_REQUIRED');

    const devLogin = await login(t.username, t.tempPassword, deviceToken);
    expect(devLogin.status).toBe(200);
    expect(devLogin.body.data.passwordChangeRequired).toBe(true);
    expect(devLogin.body.data.accessToken).toBeUndefined();

    // After the change the device path is open again (whatever the push itself answers, it is
    // no longer the password gate).
    expect((await change(devLogin.body.data.passwordChangeToken, OWNER_CHOSEN_PASSWORD)).status).toBe(200);
    const after = await http().post('/api/v1/sync/push').set('X-Device-Token', deviceToken).send({ ops: [] });
    expect(after.body.error?.code).not.toBe('PASSWORD_CHANGE_REQUIRED');
    expect(after.status).not.toBe(401);
  });
});
