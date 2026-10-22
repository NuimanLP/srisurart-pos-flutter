import type { INestApplication } from '@nestjs/common';
import * as jwt from 'jsonwebtoken';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import {
  createTestApp,
  refreshToken,
  resetTenant,
  type TenantFixture,
} from './support/fixture.js';

// `POST /auth/refresh` had no e2e coverage at all: its unit tests mock
// `DataSource.query`, so a mock happily accepted `SET LOCAL app.tenant_id = $1` —
// a statement Postgres rejects outright (42601, `syntax error at or near "$1"`),
// because SET is a utility statement and takes no bind parameter. It was the first
// statement in the handler's transaction and the catch rethrows, so every refresh
// was a 500 and ADR-0009's `auth.refresh_rejected` trail was never written.
// These cases only pass against a real Postgres.
const TENANT = '33333333-9999-4999-8999-333333333333';

describe('POST /auth/refresh (e2e)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;

  /** The `auth.refresh_rejected` reasons recorded for this tenant. */
  const rejectionReasons = async (): Promise<string[]> => {
    const rows = await admin.query(
      `SELECT before->>'reason' AS reason FROM audit_log
        WHERE tenant_id = $1::uuid AND action = 'auth.refresh_rejected'
        ORDER BY id`,
      [TENANT],
    );
    return rows.map((r: { reason: string }) => r.reason);
  };

  const post = (token: string) =>
    request(app.getHttpServer()).post('/api/v1/auth/refresh').send({ refreshToken: token });

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { cache });
  });

  afterAll(async () => {
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  it('reissues a pair and carries the original refresh expiry forward (ADR-0009)', async () => {
    const exp = Math.floor(Date.now() / 1000) + 3 * 3600;
    const res = await post(
      refreshToken({
        tenantId: TENANT,
        userId: fixture.userId,
        role: 'owner',
        deviceId: fixture.posDeviceId,
        deviceRole: 'pos',
        exp,
      }),
    );

    expect(res.status).toBe(200);
    const access = jwt.decode(res.body.data.accessToken) as jwt.JwtPayload;
    const reissued = jwt.decode(res.body.data.refreshToken) as jwt.JwtPayload;
    expect(access.typ).toBe('access');
    expect(access.tid).toBe(TENANT);
    expect(access.did).toBe(fixture.posDeviceId);
    expect(reissued.typ).toBe('refresh');
    // Not "another 8 hours from now": the refresh window ends at the tenant's 04:00
    // whatever time the device happens to reconnect.
    expect(reissued.exp).toBe(exp);
  });

  it('refuses a suspended shop and records why', async () => {
    await admin.query(`UPDATE tenants SET status = 'suspended' WHERE id = $1::uuid`, [TENANT]);

    const res = await post(refreshToken({ tenantId: TENANT, userId: fixture.userId }));

    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('TENANT_SUSPENDED');
    expect(res.body.error.message).toBe('ร้านนี้ถูกระงับการใช้งาน');
    // The audit row is written in the same transaction and must survive its commit.
    expect(await rejectionReasons()).toEqual(['tenant_inactive']);
  });

  it('refuses a deactivated user and records why', async () => {
    await admin.query(
      `UPDATE users SET is_active = false WHERE tenant_id = $1::uuid AND id = $2::uuid`,
      [TENANT, fixture.userId],
    );

    const res = await post(refreshToken({ tenantId: TENANT, userId: fixture.userId }));

    expect(res.status).toBe(401);
    expect(await rejectionReasons()).toEqual(['user_inactive']);
  });

  it('refuses a retired device and records why', async () => {
    await admin.query(
      `UPDATE devices SET retired_at = now() WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, fixture.posDeviceId],
    );

    const res = await post(
      refreshToken({
        tenantId: TENANT,
        userId: fixture.userId,
        deviceId: fixture.posDeviceId,
        deviceRole: 'pos',
      }),
    );

    expect(res.status).toBe(401);
    expect(await rejectionReasons()).toEqual(['device_retired']);
  });

  it('refuses a user who no longer exists, without writing an audit row', async () => {
    const res = await post(refreshToken({ tenantId: TENANT }));

    expect(res.status).toBe(401);
    expect(await rejectionReasons()).toEqual([]);
  });

  // Security review 2026-10-21 / ADR-0009 addendum 2026-10-22: refresh tokens are single-use.
  describe('rotation with reuse detection', () => {
    const login = () =>
      refreshToken({
        tenantId: TENANT,
        userId: fixture.userId,
        deviceId: fixture.posDeviceId,
        deviceRole: 'pos',
      });
    const claims = (token: string) => jwt.decode(token) as jwt.JwtPayload;
    const rotate = async (token: string): Promise<string> => {
      const res = await post(token);
      expect(res.status).toBe(200);
      return res.body.data.refreshToken as string;
    };
    /** Moves the chain's last rotation past the grace window, instead of sleeping 30 s. */
    const ageRotation = () =>
      admin.query(
        `UPDATE refresh_families SET rotated_at = now() - interval '1 minute' WHERE tenant_id = $1::uuid`,
        [TENANT],
      );

    it('every reissued token has a new jti and names the chain (fid) of the first one', async () => {
      const t0 = login();
      const t1 = await rotate(t0);
      const t2 = await rotate(t1);
      expect(new Set([claims(t0).jti, claims(t1).jti, claims(t2).jti]).size).toBe(3);
      expect(claims(t1).fid).toBe(claims(t0).jti);
      expect(claims(t2).fid).toBe(claims(t0).jti);
    });

    it('the token just replaced, sent again within the grace window, gets the current jti back — no fork', async () => {
      const t0 = login();
      const t1 = await rotate(t0);
      const again = await rotate(t0);
      expect(claims(again).jti).toBe(claims(t1).jti);
      // Both holders now carry the one current token, and it still rotates.
      expect((await post(t1)).status).toBe(200);
    });

    it('two refreshes of the same token at once both succeed and converge on one jti', async () => {
      const t0 = login();
      const [a, b] = await Promise.all([post(t0), post(t0)]);
      expect([a.status, b.status]).toEqual([200, 200]);
      expect(claims(a.body.data.refreshToken).jti).toBe(claims(b.body.data.refreshToken).jti);
    });

    it('a token older than the one just replaced is a reuse: 401, and the whole chain is revoked', async () => {
      const t0 = login();
      const t1 = await rotate(t0);
      const t2 = await rotate(t1);

      expect((await post(t0)).status).toBe(401);
      // The legitimate holder's current token dies with the chain.
      expect((await post(t2)).status).toBe(401);
      expect(await rejectionReasons()).toEqual(['refresh_reused', 'refresh_revoked']);
    });

    it('the token just replaced, sent after the grace window, is a reuse too', async () => {
      const t0 = login();
      const t1 = await rotate(t0);
      await ageRotation();

      expect((await post(t0)).status).toBe(401);
      expect((await post(t1)).status).toBe(401);
      expect(await rejectionReasons()).toEqual(['refresh_reused', 'refresh_revoked']);
    });

    it('revoking one chain leaves another login of the same user and device alone', async () => {
      const a0 = login();
      const b0 = login();
      const a1 = await rotate(a0);
      await rotate(a1);
      expect((await post(a0)).status).toBe(401);

      expect((await post(b0)).status).toBe(200);
    });
  });
});
