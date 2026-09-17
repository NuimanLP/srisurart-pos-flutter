import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import { DocNumberService } from '../src/documents/doc-number.service.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  type TenantFixture,
} from './support/fixture.js';

// #188 acceptance suite — `GET /doc-counters` (ADR-0007 "ช่องพังที่ต้องปิดก่อนเฟส 2" item 1).
// Real Postgres as `pos_app` with RLS on: tenant isolation is the thing under test.
const TENANT = '18818818-1888-4188-8188-188188188188';
const OTHER = '18800880-1880-4188-8188-188008800880';

describe('GET /doc-counters (e2e)', () => {
  let app: INestApplication;
  let ds: DataSource;
  let admin: DataSource;
  let cache: import('ioredis').Redis;
  let fixture: TenantFixture;
  let other: TenantFixture;

  const tokenFor = (
    f: TenantFixture,
    device: 'pos' | 'backoffice' | 'none' = 'pos',
  ): string =>
    accessToken({
      tenantId: f.tenantId,
      userId: f.userId,
      role: 'owner',
      ...(device === 'pos'
        ? { deviceId: f.posDeviceId, deviceRole: 'pos' }
        : device === 'backoffice'
          ? { deviceId: f.backofficeDeviceId, deviceRole: 'backoffice' }
          : {}),
    });

  const get = (token: string, query = '') =>
    request(app.getHttpServer())
      .get(`/api/v1/doc-counters${query}`)
      .set('Authorization', `Bearer ${token}`);

  const seedCounter = (
    tenantId: string,
    deviceId: string,
    docType: string,
    period: string,
    lastNo: number,
  ) =>
    admin.query(
      `INSERT INTO doc_counters (tenant_id, device_id, doc_type, period, last_no)
            VALUES ($1::uuid, $2, $3, $4, $5)`,
      [tenantId, deviceId, docType, period, lastNo],
    );

  /**
   * Issues one real receipt number for this tenant's pos device, as a sale would, and
   * returns the period printed on it. The period is read off an issued number — never
   * re-derived here — so the suite goes red if `GET /doc-counters` and the issuer ever
   * disagree about which month it is.
   */
  const issuedPeriod = async (): Promise<string> => {
    const qr = ds.createQueryRunner();
    await qr.connect();
    await qr.startTransaction();
    try {
      await qr.query(`SELECT set_config('app.tenant_id', $1, true)`, [TENANT]);
      const no = await new DocNumberService().issue(qr.manager, {
        tenantId: TENANT,
        deviceId: fixture.posDeviceId,
        docType: 'receipt',
      });
      await qr.commitTransaction();
      // RC03-2569-09-0001 → 2569-09
      return no.split('-').slice(1, 3).join('-');
    } catch (err) {
      await qr.rollbackTransaction();
      throw err;
    } finally {
      await qr.release();
    }
  };

  beforeAll(async () => {
    ({ app, ds, admin, cache } = await createTestApp());
  });

  beforeEach(async () => {
    fixture = await resetTenant(admin, TENANT, { posDeviceNo: 3, cache });
    other = await resetTenant(admin, OTHER, { posDeviceNo: 3, cache });
  });

  afterAll(async () => {
    for (const t of [TENANT, OTHER]) {
      await resetTenant(admin, t);
      await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [t]);
    }
    await app.close();
  });

  it('returns the calling device’s high-water marks for every period, with its id and device_no', async () => {
    const period = await issuedPeriod(); // receipt 0001, written by the real issuer
    await seedCounter(TENANT, fixture.posDeviceId, 'cn', period, 3);
    await seedCounter(TENANT, fixture.posDeviceId, 'receipt', '2500-01', 9000);

    const res = await get(tokenFor(fixture));
    expect(res.status).toBe(200);
    expect(res.body.data).toEqual({
      deviceId: fixture.posDeviceId,
      deviceNo: 3,
      // The period the issuer just numbered into — not a second derivation of it.
      period,
      counters: [
        { docType: 'receipt', period: '2500-01', lastNo: 9000 },
        { docType: 'cn', period, lastNo: 3 },
        { docType: 'receipt', period, lastNo: 1 },
      ],
    });
  });

  it('a device that never issued a number gets an empty list, not an error', async () => {
    const res = await get(tokenFor(fixture));
    expect(res.status).toBe(200);
    expect(res.body.data.counters).toEqual([]);
    expect(res.body.data.deviceNo).toBe(3);
  });

  it('never returns another device’s or another tenant’s counters', async () => {
    const period = await issuedPeriod();
    await admin.query(
      `UPDATE doc_counters SET last_no = 5 WHERE tenant_id = $1::uuid AND device_id = $2`,
      [TENANT, fixture.posDeviceId],
    );
    // Same tenant, the backoffice machine's series.
    await seedCounter(TENANT, fixture.backofficeDeviceId, 'po', period, 77);
    // Another shop whose pos device has the same device_no.
    await seedCounter(OTHER, other.posDeviceId, 'receipt', period, 888);
    // Another shop's row stored under THIS tenant's device id: RLS and the tenant filter
    // both have to hold for it to stay invisible.
    await seedCounter(OTHER, fixture.posDeviceId, 'cn', period, 999);

    const mine = await get(tokenFor(fixture));
    expect(mine.status).toBe(200);
    expect(mine.body.data.counters).toEqual([
      { docType: 'receipt', period, lastNo: 5 },
    ]);

    // A query parameter naming another device is ignored — `did` comes from the token.
    const smuggled = await get(
      tokenFor(fixture),
      `?deviceId=${fixture.backofficeDeviceId}&device_id=${fixture.backofficeDeviceId}`,
    );
    expect(smuggled.body.data.counters).toEqual(mine.body.data.counters);

    const theirs = await get(tokenFor(other));
    expect(theirs.body.data.counters).toEqual([
      { docType: 'receipt', period, lastNo: 888 },
    ]);
  });

  it('is pos only: a backoffice device and a token with no device are refused', async () => {
    for (const token of [tokenFor(fixture, 'backoffice'), tokenFor(fixture, 'none')]) {
      const res = await get(token);
      expect(res.status).toBe(403);
      expect(res.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');
    }
  });

  it('a retired pos device is refused, as the issuer refuses it', async () => {
    await admin.query(
      `UPDATE devices SET retired_at = now() WHERE tenant_id = $1::uuid AND id = $2`,
      [TENANT, fixture.posDeviceId],
    );
    // Its access token still verifies for up to 15 minutes after retirement.
    const res = await get(tokenFor(fixture));
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');
  });

  it('a pos token whose device is not in this tenant is refused', async () => {
    const res = await get(
      accessToken({
        tenantId: TENANT,
        userId: fixture.userId,
        role: 'owner',
        deviceId: other.posDeviceId,
        deviceRole: 'pos',
      }),
    );
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');
  });

  it('needs a token', async () => {
    const res = await request(app.getHttpServer()).get('/api/v1/doc-counters');
    expect(res.status).toBe(401);
  });
});
