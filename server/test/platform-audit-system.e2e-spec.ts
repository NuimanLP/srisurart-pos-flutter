import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import type { Redis } from 'ioredis';
import { randomUUID } from 'node:crypto';
import { signJwt } from '../src/common/jwt.js';
import { APP_CONFIG, type AppConfig } from '../src/config/config.js';
import { platformAdminCacheKey } from '../src/platform/platform-auth.guard.js';
import { encodeAuditCursor } from '../src/platform/platform-audit.service.js';
import { ALL_QUEUES } from '../src/queue/queue.constants.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  TENANT_TABLES_DEPTH_FIRST,
  type TenantFixture,
} from './support/fixture.js';

/**
 * #443: GET /platform/tenants/:id/audit (keyset-paged, tenant-isolated, itself audited) and
 * GET /platform/system (SHA, readiness, queue counts, honest backup statement).
 */
describe('Platform audit viewer + system panel (#443)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: Redis;
  let config: AppConfig;
  let adminId: string;
  let adminUsername: string;
  let token: string;
  let shopA: TenantFixture;
  let shopB: TenantFixture;

  const tenantA = randomUUID();
  const tenantB = randomUUID();
  const http = () => request(app.getHttpServer());
  const auditUrl = (tid: string, qs = '') => `/api/v1/platform/tenants/${tid}/audit${qs}`;

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
    config = app.get<AppConfig>(APP_CONFIG);
    adminId = randomUUID();
    adminUsername = `audit-admin-${adminId.slice(0, 8)}`;
    await admin.query(
      `INSERT INTO platform_admins (id, username, password_hash, display_name, is_active)
       VALUES ($1, $2, 'x', 'Audit Admin', true)`,
      [adminId, adminUsername],
    );
    token = signJwt(
      { iss: 'srisurart-pos', aud: 'platform', sub: adminId, username: adminUsername },
      config.jwtPlatformSecret,
    );
    shopA = await resetTenant(admin, tenantA, { cache });
    shopB = await resetTenant(admin, tenantB, { cache });
  });

  afterAll(async () => {
    for (const tid of [tenantA, tenantB]) {
      for (const table of TENANT_TABLES_DEPTH_FIRST) {
        await admin.query(`DELETE FROM ${table} WHERE tenant_id = $1::uuid`, [tid]);
      }
      await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [tid]);
    }
    await admin.query(`DELETE FROM audit_log WHERE platform_admin_id = $1`, [adminId]);
    await admin.query(`DELETE FROM platform_admins WHERE id = $1`, [adminId]);
    await cache.del(platformAdminCacheKey(adminId));
    await app?.close();
  });

  beforeEach(async () => {
    await admin.query(`DELETE FROM audit_log WHERE tenant_id = ANY($1::uuid[])`, [[tenantA, tenantB]]);
  });

  /** Seeds rows; `ts` lets several rows share one created_at (one transaction's `now()`). */
  async function seed(tid: string, rows: Array<{ action: string; ts: string; userId?: string; deviceId?: string; adminId?: string; before?: object; after?: object }>) {
    for (const r of rows) {
      await admin.query(
        `INSERT INTO audit_log (tenant_id, user_id, platform_admin_id, device_id, action, entity, entity_id, before, after, ip, created_at)
         VALUES ($1, $2, $3, $4, $5, 'sales', 'S-1', $6, $7, '10.0.0.9', $8::timestamptz)`,
        [
          tid,
          r.userId ?? null,
          r.adminId ?? null,
          r.deviceId ?? null,
          r.action,
          r.before ? JSON.stringify(r.before) : null,
          r.after ? JSON.stringify(r.after) : null,
          r.ts,
        ],
      );
    }
  }

  async function walk(tid: string, limit: number) {
    const seen: Array<{ id: string; action: string; createdAt: string }> = [];
    let before: string | null = null;
    for (let i = 0; i < 50; i++) {
      const qs: string = `?limit=${limit}${before ? `&before=${before}` : ''}`;
      const res: request.Response = await http().get(auditUrl(tid, qs)).set('Authorization', `Bearer ${token}`);
      expect(res.status).toBe(200);
      seen.push(...res.body.data.items);
      expect(res.body.data.items.length).toBeLessThanOrEqual(limit);
      before = res.body.data.nextCursor;
      if (!before) return seen;
    }
    throw new Error('pager did not terminate');
  }

  it('pages newest-first across created_at ties with no skip and no repeat', async () => {
    const tie = '2026-10-01T03:00:00.123456Z';
    await seed(tenantA, [
      { action: 'test.oldest', ts: '2026-10-01T02:00:00.000001Z', userId: shopA.userId },
      ...Array.from({ length: 5 }, (_, i) => ({ action: `test.tie${i}`, ts: tie, userId: shopA.userId })),
      { action: 'test.newest', ts: '2026-10-01T04:00:00Z', userId: shopA.userId },
    ]);
    const expected = await admin.query(
      `SELECT id::text FROM audit_log WHERE tenant_id = $1 ORDER BY created_at DESC, id DESC`,
      [tenantA],
    );

    for (const limit of [1, 2, 3, 7, 200]) {
      // Each walk's own read rows are newer than every seeded row: they are written after the
      // page query, so they never enter the walk that wrote them — clear them for the next one.
      await admin.query(
        `DELETE FROM audit_log WHERE tenant_id = $1 AND action = 'platform.tenant.audit.read'`,
        [tenantA],
      );
      const seen = await walk(tenantA, limit);
      expect(seen.map((r) => r.id)).toEqual(expected.map((r: { id: string }) => r.id));
    }
  });

  it('keeps microseconds in createdAt (a millisecond cursor would skip tie rows)', async () => {
    await seed(tenantA, [{ action: 'test.us', ts: '2026-10-01T03:00:00.123456Z', userId: shopA.userId }]);
    const res = await http().get(auditUrl(tenantA)).set('Authorization', `Bearer ${token}`);
    expect(res.body.data.items[0].createdAt).toBe('2026-10-01T03:00:00.123456Z');
  });

  it('never returns another tenant\'s rows, even through a cursor', async () => {
    await seed(tenantA, [{ action: 'test.mine', ts: '2026-10-01T03:00:00Z', userId: shopA.userId }]);
    await seed(tenantB, [
      { action: 'test.other', ts: '2026-10-01T02:00:00Z', userId: shopB.userId },
      { action: 'test.other', ts: '2026-10-01T01:00:00Z', userId: shopB.userId },
    ]);
    const all = await walk(tenantA, 1);
    expect(all.map((r) => r.action)).toEqual(['test.mine']);

    // A cursor minted from tenant B's newest row, replayed against tenant A: still only A.
    const [bRow] = await admin.query(
      `SELECT id::text FROM audit_log WHERE tenant_id = $1 ORDER BY id DESC LIMIT 1`,
      [tenantB],
    );
    const before = encodeAuditCursor({ createdAt: '2027-01-01T00:00:00.000000Z', id: bRow.id });
    const res = await http()
      .get(auditUrl(tenantA, `?before=${before}`))
      .set('Authorization', `Bearer ${token}`);
    expect(res.body.data.items.every((i: { action: string }) => i.action !== 'test.other')).toBe(true);
  });

  it('resolves actors and never returns before/after payloads', async () => {
    await seed(tenantA, [
      { action: 'test.user', ts: '2026-10-01T05:00:00Z', userId: shopA.userId, deviceId: shopA.posDeviceId, after: { pin: 'SECRET-1234' } },
      { action: 'test.admin', ts: '2026-10-01T04:00:00Z', adminId, before: { tempPassword: 'SECRET-xyz' } },
      { action: 'device.enrol', ts: '2026-10-01T03:00:00Z', deviceId: shopA.posDeviceId },
      { action: 'system.job', ts: '2026-10-01T02:00:00Z' },
    ]);
    const res = await http().get(auditUrl(tenantA)).set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(JSON.stringify(res.body)).not.toContain('SECRET');
    const [u, a, d, s] = res.body.data.items;
    expect(u).toMatchObject({
      action: 'test.user',
      entity: 'sales',
      entityId: 'S-1',
      ip: '10.0.0.9',
      actor: { type: 'user', id: shopA.userId, username: shopA.username },
      device: { id: shopA.posDeviceId, label: 'เครื่องขาย', deviceNo: 1 },
    });
    expect(u).not.toHaveProperty('before');
    expect(u).not.toHaveProperty('after');
    expect(a.actor).toEqual({ type: 'platform_admin', id: adminId, username: adminUsername });
    expect(d.actor).toEqual({ type: 'device', id: shopA.posDeviceId, label: 'เครื่องขาย', deviceNo: 1 });
    expect(s.actor).toEqual({ type: 'system' });
  });

  it('the read itself writes one platform.tenant.audit.read row', async () => {
    const res = await http().get(auditUrl(tenantA, '?limit=5')).set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    const rows = await admin.query(
      `SELECT platform_admin_id, entity, after FROM audit_log
        WHERE tenant_id = $1 AND action = 'platform.tenant.audit.read'`,
      [tenantA],
    );
    expect(rows).toHaveLength(1);
    expect(rows[0].platform_admin_id).toBe(adminId);
    expect(rows[0].after).toMatchObject({ limit: 5, paged: false });

    // …and it shows up in the next read, attributed to the admin.
    const next = await http().get(auditUrl(tenantA)).set('Authorization', `Bearer ${token}`);
    expect(next.body.data.items[0]).toMatchObject({
      action: 'platform.tenant.audit.read',
      actor: { type: 'platform_admin', username: adminUsername },
    });
  });

  it.each([
    ['?limit=0', 'INVALID_AUDIT_LIMIT'],
    ['?limit=abc', 'INVALID_AUDIT_LIMIT'],
    ['?limit=1&limit=2', 'INVALID_AUDIT_LIMIT'],
    ['?before=***', 'INVALID_AUDIT_CURSOR'],
    [`?before=${Buffer.from('2026-02-30T00:00:00.000000Z|1').toString('base64url')}`, 'INVALID_AUDIT_CURSOR'],
  ])('refuses %s with 400 %s', async (qs, code) => {
    const res = await http().get(auditUrl(tenantA, qs)).set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe(code);
  });

  it('clamps a large well-formed limit to 200', async () => {
    const res = await http().get(auditUrl(tenantA, '?limit=5000')).set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    const [row] = await admin.query(
      `SELECT after FROM audit_log WHERE tenant_id = $1 AND action = 'platform.tenant.audit.read'`,
      [tenantA],
    );
    expect(row.after.limit).toBe(200);
  });

  it('400 on a non-UUID tenant id, 404 on an unknown tenant', async () => {
    const bad = await http().get(auditUrl('not-a-uuid')).set('Authorization', `Bearer ${token}`);
    expect(bad.status).toBe(400);
    expect(bad.body.error.code).toBe('INVALID_TENANT_ID');
    const missing = await http().get(auditUrl(randomUUID())).set('Authorization', `Bearer ${token}`);
    expect(missing.status).toBe(404);
  });

  describe.each([
    ['audit', () => auditUrl(tenantA)],
    ['system', () => '/api/v1/platform/system'],
  ])('%s: PlatformAuthGuard', (_name, url) => {
    it('401 without a token', async () => {
      expect((await http().get(url())).status).toBe(401);
    });

    it('401 with a tenant (owner) token', async () => {
      const res = await http()
        .get(url())
        .set('Authorization', `Bearer ${accessToken({ tenantId: tenantA, userId: shopA.userId })}`);
      expect(res.status).toBe(401);
    });

    it('403 PLATFORM_IP_FORBIDDEN from an IP outside the allowlist', async () => {
      const res = await http()
        .get(url())
        .set('Authorization', `Bearer ${token}`)
        .set('X-Forwarded-For', '203.0.113.195');
      expect(res.status).toBe(403);
      expect(res.body.error.code).toBe('PLATFORM_IP_FORBIDDEN');
    });
  });

  describe('GET /platform/system', () => {
    afterEach(() => {
      config.gitSha = null;
    });

    it('reports gitSha null when GIT_SHA is unset, readiness, every queue, and no backup claim', async () => {
      config.gitSha = null;
      const res = await http().get('/api/v1/platform/system').set('Authorization', `Bearer ${token}`);
      expect(res.status).toBe(200);
      const body = res.body.data;
      expect(body.gitSha).toBeNull();
      expect(body.ready).toBe(true);
      expect(body.checks).toEqual({ postgres: 'up', redisCache: 'up', redisQueue: 'up' });
      expect(body.queues.map((q: { name: string }) => q.name)).toEqual([...ALL_QUEUES]);
      for (const q of body.queues) {
        expect(Object.keys(q.counts).sort()).toEqual(
          ['active', 'completed', 'delayed', 'failed', 'prioritized', 'waiting'],
        );
      }
      expect(body.backup.offsite).toBe('not_configured');
      expect(JSON.stringify(body.backup).toLowerCase()).not.toContain('ready');
      expect(Number.isNaN(Date.parse(body.checkedAt))).toBe(false);
    });

    it('reports the baked SHA when set, and audits the read', async () => {
      config.gitSha = 'e191755';
      const res = await http().get('/api/v1/platform/system').set('Authorization', `Bearer ${token}`);
      expect(res.body.data.gitSha).toBe('e191755');
      const rows = await admin.query(
        `SELECT tenant_id FROM audit_log WHERE platform_admin_id = $1 AND action = 'platform.system.read'`,
        [adminId],
      );
      expect(rows.length).toBeGreaterThanOrEqual(1);
      expect(rows[0].tenant_id).toBe('00000000-0000-0000-0000-000000000000');
    });
  });
});
