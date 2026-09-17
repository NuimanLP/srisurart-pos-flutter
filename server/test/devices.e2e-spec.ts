import type { INestApplication } from '@nestjs/common';
import { createHash } from 'node:crypto';
import * as jwt from 'jsonwebtoken';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import { hashPassword } from '../src/common/password.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  type TenantFixture,
} from './support/fixture.js';

// #144 — `/devices` (ADR-0004 "การผูกเครื่อง"): enrol, list, retire, and what a retired
// device can no longer do. The drawer side of retirement is in `shifts.e2e-spec.ts`.
const TENANT = '14414414-4444-4144-8144-144144144144';
const PASSWORD = 'device-flow-144';

describe('devices: enrol and retire (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;
  let keySeq = 0;
  // One address per run: the login IP bucket is shared by every suite on 127.0.0.1.
  const ip = `203.0.113.${Math.floor(Math.random() * 250) + 1}`;

  const token = (role = 'owner', deviceId?: string) =>
    accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role,
      deviceId: deviceId ?? fixture.backofficeDeviceId,
      deviceRole: deviceId === fixture?.posDeviceId ? 'pos' : 'backoffice',
    });

  const createDevice = (body: unknown, role = 'owner') =>
    request(app.getHttpServer())
      .post('/api/v1/devices')
      .set('Authorization', `Bearer ${token(role)}`)
      .set('Idempotency-Key', `k-dev-${++keySeq}-${Date.now()}`)
      .send(body as object);

  const retire = (
    id: string,
    body: unknown = {},
    role = 'owner',
  ) =>
    request(app.getHttpServer())
      .post(`/api/v1/devices/${encodeURIComponent(id)}/retire`)
      .set('Authorization', `Bearer ${token(role)}`)
      .set('Idempotency-Key', `k-ret-${++keySeq}-${Date.now()}`)
      .send(body as object);

  const login = (deviceToken?: string) =>
    request(app.getHttpServer())
      .post('/api/v1/auth/token')
      .set('X-Forwarded-For', ip)
      .send({ username: fixture.username, password: PASSWORD, deviceToken });

  const auditActions = async (): Promise<
    { action: string; entity_id: string | null; before: unknown; after: unknown }[]
  > =>
    admin.query(
      `SELECT action, entity_id, before, after FROM audit_log
        WHERE tenant_id = $1::uuid AND action LIKE 'device.%'
        ORDER BY id`,
      [TENANT],
    );

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { posDeviceNo: 7, cache });
    await admin.query(
      `UPDATE users SET password_hash = $3 WHERE tenant_id = $1::uuid AND id = $2::uuid`,
      [TENANT, fixture.userId, await hashPassword(PASSWORD)],
    );
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it('owner creates a device: the server picks the id and the next never-used device_no', async () => {
    const res = await createDevice({
      label: '  หลังร้าน 2  ',
      role: 'backoffice',
      // Neither may come from the body (ADR-0004); both are ignored.
      id: 'pos-hijack',
      deviceNo: 1,
    });

    expect(res.status).toBe(201);
    const { device, enrolCode } = res.body.data;
    expect(device.id).not.toBe('pos-hijack');
    // Fixture: pos = 7, backoffice = 57. max + 1, never a gap below it.
    expect(device.deviceNo).toBe(58);
    expect(device.label).toBe('หลังร้าน 2');
    expect(device.role).toBe('backoffice');
    expect(device.enrolled).toBe(false);
    expect(device.retiredAt).toBeNull();
    expect(Date.parse(device.enrolExpiresAt)).toBeGreaterThan(Date.now());
    expect(enrolCode).toMatch(/^[0-9A-F]{8}$/);

    // Only the hash is stored, and the audit row never carries the code.
    const rows = await admin.query(
      `SELECT enrol_code_hash, token_hash FROM devices WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, device.id],
    );
    expect(rows[0].enrol_code_hash).toBe(createHash('sha256').update(enrolCode).digest('hex'));
    expect(rows[0].token_hash).toBeNull();
    const audit = await auditActions();
    expect(audit).toHaveLength(1);
    expect(audit[0].action).toBe('device.create');
    expect(audit[0].entity_id).toBe(device.id);
    expect(JSON.stringify(audit[0])).not.toContain(enrolCode);

    // A retired device keeps its number: the next one is still max + 1.
    await retire(device.id);
    const next = await createDevice({ label: 'หลังร้าน 3', role: 'backoffice' });
    expect(next.status).toBe(201);
    expect(next.body.data.device.deviceNo).toBe(59);
  });

  it('refuses a second live pos device, and allows one once the old till is retired', async () => {
    const refused = await createDevice({ label: 'เครื่องขาย 2', role: 'pos' });
    expect(refused.status).toBe(409);
    expect(refused.body.error.code).toBe('POS_DEVICE_EXISTS');
    expect(refused.body.error.details).toEqual({ deviceId: fixture.posDeviceId });

    // Nothing was written, and the refused request consumed no device_no.
    const count = await admin.query(
      `SELECT count(*)::int AS n FROM devices WHERE tenant_id = $1::uuid`,
      [TENANT],
    );
    expect(count[0].n).toBe(2);

    expect((await retire(fixture.posDeviceId)).status).toBe(200);
    const allowed = await createDevice({ label: 'เครื่องขาย 2', role: 'pos' });
    expect(allowed.status).toBe(201);
    expect(allowed.body.data.device.deviceNo).toBe(58);
  });

  it('requires an enrolled device token (did), and validates the body (F6)', async () => {
    const tokenWithoutDevice = accessToken({
      tenantId: TENANT,
      userId: fixture.userId,
      role: 'owner',
    });

    const create = await request(app.getHttpServer())
      .post('/api/v1/devices')
      .set('Authorization', `Bearer ${tokenWithoutDevice}`)
      .set('Idempotency-Key', `k-dev-${++keySeq}-${Date.now()}`)
      .send({ label: 'x', role: 'backoffice' });
    expect(create.status).toBe(403);
    expect(create.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');

    const ret = await request(app.getHttpServer())
      .post(`/api/v1/devices/${encodeURIComponent(fixture.backofficeDeviceId)}/retire`)
      .set('Authorization', `Bearer ${tokenWithoutDevice}`)
      .set('Idempotency-Key', `k-ret-${++keySeq}-${Date.now()}`)
      .send({});
    expect(ret.status).toBe(403);
    expect(ret.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');

    const list = await request(app.getHttpServer())
      .get('/api/v1/devices')
      .set('Authorization', `Bearer ${tokenWithoutDevice}`);
    expect(list.status).toBe(403);
    expect(list.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');

    expect((await createDevice({ label: '', role: 'backoffice' })).status).toBe(400);
    expect((await createDevice({ label: 'x', role: 'admin' })).status).toBe(400);
    expect((await createDevice({ label: 'x'.repeat(101), role: 'pos' })).status).toBe(400);
    expect((await retire(fixture.posDeviceId, { physicalCash: '-1.00' })).status).toBe(400);

    const devices = await admin.query(
      `SELECT retired_at FROM devices WHERE tenant_id = $1::uuid AND retired_at IS NOT NULL`,
      [TENANT],
    );
    expect(devices).toHaveLength(0);
    expect(await auditActions()).toEqual([]);
  });

  it('lists every device, retired ones included, and never a hash', async () => {
    await retire(fixture.backofficeDeviceId);
    const res = await request(app.getHttpServer())
      .get('/api/v1/devices')
      .set('Authorization', `Bearer ${token('owner')}`);

    expect(res.status).toBe(200);
    expect(res.body.data.map((d: { id: string }) => d.id)).toEqual([
      fixture.posDeviceId,
      fixture.backofficeDeviceId,
    ]);
    expect(res.body.data[1].retiredAt).not.toBeNull();
    expect(JSON.stringify(res.body)).not.toMatch(/hash/i);
  });

  it('enrol → device token → login carries did/drole; retirement locks the token out of login and refresh', async () => {
    const created = await createDevice({ label: 'หลังร้าน 2', role: 'backoffice' });
    const { device, enrolCode } = created.body.data;

    // The browser exchanges the code (existing `POST /auth/device`) — single use.
    const enrol = await request(app.getHttpServer())
      .post('/api/v1/auth/device')
      .send({ code: enrolCode.toLowerCase() });
    expect(enrol.status).toBe(200);
    const deviceToken: string = enrol.body.data.deviceToken;
    const again = await request(app.getHttpServer())
      .post('/api/v1/auth/device')
      .send({ code: enrolCode });
    expect(again.status).toBe(401);

    const ok = await login(deviceToken);
    expect(ok.status).toBe(200);
    const access = jwt.decode(ok.body.data.accessToken) as jwt.JwtPayload;
    expect(access.did).toBe(device.id);
    expect(access.drole).toBe('backoffice');
    const refreshToken: string = ok.body.data.refreshToken;

    const retired = await retire(device.id);
    expect(retired.status).toBe(200);
    expect(retired.body.data.device.retiredAt).not.toBeNull();
    expect(retired.body.data.shift).toBeNull();

    // ADR-0004: a retired device token no longer logs in …
    const denied = await login(deviceToken);
    expect(denied.status).toBe(401);
    expect(denied.body.error.message).toBe('Device has been retired');
    // … and ADR-0009: the refresh it already holds stops working too.
    const refresh = await request(app.getHttpServer())
      .post('/api/v1/auth/refresh')
      .send({ refreshToken });
    expect(refresh.status).toBe(401);

    const audit = await auditActions();
    expect(audit.map((a) => a.action)).toEqual(['device.create', 'device.enrol', 'device.retire']);
  });

  it('an enrolment code outstanding at retirement can no longer be used', async () => {
    const created = await createDevice({ label: 'หลังร้าน 2', role: 'backoffice' });
    await retire(created.body.data.device.id);

    const enrol = await request(app.getHttpServer())
      .post('/api/v1/auth/device')
      .send({ code: created.body.data.enrolCode });
    expect(enrol.status).toBe(401);
  });

  it('retiring a pos with an open drawer needs the counted cash, and writes nothing without it', async () => {
    const posToken = token('owner', fixture.posDeviceId);
    const opened = await request(app.getHttpServer())
      .post('/api/v1/shifts/open')
      .set('Authorization', `Bearer ${posToken}`)
      .set('Idempotency-Key', `k-open-${++keySeq}-${Date.now()}`)
      .send({ startingCash: '500.00' });
    expect(opened.status).toBe(200);

    const refused = await retire(fixture.posDeviceId, {});
    expect(refused.status).toBe(409);
    expect(refused.body.error.code).toBe('PHYSICAL_CASH_REQUIRED');
    expect(refused.body.error.details).toEqual({ shiftId: opened.body.data.id });
    const untouched = await admin.query(
      `SELECT d.retired_at, s.closed_at, s.is_active
         FROM devices d JOIN shifts s ON s.tenant_id = d.tenant_id AND s.device_id = d.id
        WHERE d.tenant_id = $1::uuid AND d.id = $2`,
      [TENANT, fixture.posDeviceId],
    );
    expect(untouched[0]).toEqual({ retired_at: null, closed_at: null, is_active: true });
    expect(await auditActions()).toEqual([]);

    const done = await retire(fixture.posDeviceId, { physicalCash: '720.00' });
    expect(done.status).toBe(200);
    expect(done.body.data.shift.id).toBe(opened.body.data.id);
    expect(done.body.data.shift.physicalCash).toBe('720.00');
    const audit = await auditActions();
    expect(audit).toHaveLength(1);
    expect(audit[0]).toMatchObject({
      action: 'device.retire',
      entity_id: fixture.posDeviceId,
      after: { shiftId: opened.body.data.id, physicalCash: '720.00' },
    });
  });

  it('answers 404 for an unknown device — including another shop’s — and 409 on a second retirement', async () => {
    const missing = await retire('no-such-device');
    expect(missing.status).toBe(404);
    expect(missing.body.error.code).toBe('DEVICE_NOT_FOUND');

    // A different first eight characters: fixture device ids are `pos-<tenant prefix>`,
    // so a shared prefix would name this suite's own till and prove nothing.
    const OTHER = '41441441-5555-4555-8555-144144144144';
    const other = await resetTenant(admin, OTHER, { posDeviceNo: 3 });
    try {
      const crossTenant = await retire(other.posDeviceId);
      expect(crossTenant.status).toBe(404);
      const row = await admin.query(
        `SELECT retired_at FROM devices WHERE tenant_id = $1::uuid AND id = $2`,
        [OTHER, other.posDeviceId],
      );
      expect(row[0].retired_at).toBeNull();
    } finally {
      await resetTenant(admin, OTHER);
      await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [OTHER]);
    }

    expect((await retire(fixture.backofficeDeviceId)).status).toBe(200);
    const twice = await retire(fixture.backofficeDeviceId);
    expect(twice.status).toBe(409);
    expect(twice.body.error.code).toBe('DEVICE_ALREADY_RETIRED');
  });

  it('replays a retirement under the same Idempotency-Key instead of answering 409', async () => {
    const key = `k-ret-replay-${Date.now()}`;
    const send = () =>
      request(app.getHttpServer())
        .post(`/api/v1/devices/${fixture.backofficeDeviceId}/retire`)
        .set('Authorization', `Bearer ${token('owner')}`)
        .set('Idempotency-Key', key)
        .send({});

    const first = await send();
    const replay = await send();
    expect(first.status).toBe(200);
    expect(replay.status).toBe(200);
    expect(replay.body.data).toEqual(first.body.data);
    expect((await auditActions()).map((a) => a.action)).toEqual(['device.retire']);
  });
});
