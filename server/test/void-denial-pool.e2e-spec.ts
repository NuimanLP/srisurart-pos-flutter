import { randomUUID } from 'node:crypto';
import type { INestApplication } from '@nestjs/common';
import type { Redis } from 'ioredis';
import type { DataSource } from 'typeorm';
import request from 'supertest';
import { accessToken, createTestApp, resetTenant } from './support/fixture.js';

// The availability half of #23's refusal audit.
//
// `VoidService.auditDenial` has to write on a connection of its own — the 403 rolls the
// request transaction back and the row would go with it. Taking that connection from the
// **request** pool made every denial a request holding one connection while queuing for a
// second, which is the pool deadlock `README.md` rule 1 exists to forbid. Measured against
// the real stack at `DB_POOL_SIZE=2`, before the fix:
//
//   PROBE one denial:                403                 111 ms
//   PROBE four concurrent denials:   403,403,500,500    5112 ms
//   PROBE four concurrent reads:     200,200,200,200      20 ms
//
// The two 500s are not the denials. They are unrelated requests whose middleware
// `qr.connect()` timed out at `connectionTimeoutMillis: 5000`. Production runs
// `DB_POOL_SIZE ?? 5` and the first denial branch is the **role** check, so an
// authenticated cashier who knows no PIN can stall every sale in flight.
describe('void denials do not starve the request pool (e2e)', () => {
  const TENANT = 'cccccccc-3333-4333-8333-cccccccccccc';
  const PIN = '4242';

  let app: INestApplication;
  let admin: DataSource;
  let cache: Redis;
  let managerToken: string;
  let cashierToken: string;
  let keySeq = 0;

  beforeAll(async () => {
    // The fixture asks for 8, but spreads `process.env` after it — which is the seam
    // that lets this suite boot the same app on a pool small enough to contend.
    const before = process.env.DB_POOL_SIZE;
    process.env.DB_POOL_SIZE = '2';
    try {
      ({ app, admin, cache } = await createTestApp());
    } finally {
      if (before === undefined) delete process.env.DB_POOL_SIZE;
      else process.env.DB_POOL_SIZE = before;
    }

    const t = await resetTenant(admin, TENANT, { pin: PIN, cache });
    managerToken = accessToken({
      tenantId: TENANT,
      userId: t.userId,
      role: 'manager',
      deviceId: t.posDeviceId,
      deviceRole: 'pos',
    });
    cashierToken = accessToken({
      tenantId: TENANT,
      userId: t.userId,
      role: 'cashier',
      deviceId: t.posDeviceId,
      deviceRole: 'pos',
    });
  });

  afterAll(async () => {
    // The tenant goes too, not just its rows — a suite leaves nothing behind for the
    // next one to trip over.
    await resetTenant(admin, TENANT);
    await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [TENANT]);
    await app.close();
  });

  /** A void attempt that will be refused. The bill need not exist: both denial
   *  branches are reached before the sale is ever looked up. */
  const denial = (token: string, body: Record<string, unknown>) =>
    request(app.getHttpServer())
      .post(`/api/v1/sales/${randomUUID()}/void`)
      .set('Authorization', `Bearer ${token}`)
      .set('Idempotency-Key', `k-deny-${++keySeq}-${Date.now()}`)
      .send(body);

  /** An unrelated in-flight request: one connection, held for the length of a read. */
  const read = () =>
    request(app.getHttpServer())
      .get('/api/v1/sales?limit=1')
      .set('Authorization', `Bearer ${managerToken}`);

  const deniedRows = async (): Promise<number> => {
    const rows = (await admin.query(
      `SELECT count(*)::int AS n FROM audit_log
        WHERE tenant_id = $1::uuid AND action = 'sale.void.denied'`,
      [TENANT],
    )) as { n: number }[];
    return rows[0].n;
  };

  it('answers one denial with a 403 and an audit row', async () => {
    const before = await deniedRows();
    const started = Date.now();
    const res = await denial(cashierToken, { pin: PIN });
    console.log(`PROBE one denial:                ${res.status}                 ${Date.now() - started} ms`);

    expect(res.status).toBe(403);
    expect(await deniedRows()).toBe(before + 1);
  });

  // The measurement. Four denials and four unrelated reads at once, on a pool of two:
  // before the fix the denials took a second connection each and everything else timed
  // out behind them.
  it('answers four concurrent denials without 500ing the requests behind them', async () => {
    const before = await deniedRows();
    const started = Date.now();
    const [denials, reads] = await Promise.all([
      Promise.all([
        denial(cashierToken, { pin: PIN }),
        denial(cashierToken, { pin: PIN }),
        denial(cashierToken, { pin: PIN }),
        denial(cashierToken, { pin: PIN }),
      ]),
      Promise.all([read(), read(), read(), read()]),
    ]);
    const elapsed = Date.now() - started;
    const codes = denials.map((r) => r.status);
    const readCodes = reads.map((r) => r.status);
    console.log(`PROBE four concurrent denials:   ${codes.join(',')}    ${elapsed} ms`);
    console.log(`PROBE four concurrent reads:     ${readCodes.join(',')}`);

    expect(codes).toEqual([403, 403, 403, 403]);
    // The regression this file exists for: a 500 here is an unrelated request that
    // never got a connection, not a failed void.
    expect(readCodes).toEqual([200, 200, 200, 200]);
    // A denial is a role check plus one INSERT. Anything near `connectionTimeoutMillis`
    // means something is queuing for a connection again.
    expect(elapsed).toBeLessThan(2000);
    expect(await deniedRows()).toBe(before + 4);
  });

  // #23's behaviour, unchanged by moving the write to another pool: the role branch and
  // the PIN branch each still 403 with the same envelope and each still leaves a row.
  it('still refuses on the role branch and on the PIN branch, and records both', async () => {
    const before = await deniedRows();

    const byRole = await denial(cashierToken, { pin: PIN });
    expect(byRole.status).toBe(403);
    expect(byRole.body.error.code).toBe('FORBIDDEN');
    expect(byRole.body.error.message).toBe('Manager PIN required');

    const byPin = await denial(managerToken, { pin: 'not-the-pin' });
    expect(byPin.status).toBe(403);
    expect(byPin.body.error.code).toBe('FORBIDDEN');
    expect(byPin.body.error.message).toBe('Manager PIN required');

    const rows = (await admin.query(
      `SELECT after->>'reason' AS reason FROM audit_log
        WHERE tenant_id = $1::uuid AND action = 'sale.void.denied'
        ORDER BY id DESC LIMIT 2`,
      [TENANT],
    )) as { reason: string }[];
    expect(rows.map((r) => r.reason).sort()).toEqual(['pin', 'role']);
    expect(await deniedRows()).toBe(before + 2);
  });

  // The row is written on a `pos_app` connection that named the tenant, so RLS applied
  // to it exactly as it does to the request's own writes.
  it('lands the denial row under the acting tenant, visible under RLS', async () => {
    await denial(cashierToken, { pin: PIN });
    const rows = (await admin.query(
      `SELECT tenant_id::text AS tenant_id, user_id, entity FROM audit_log
        WHERE tenant_id = $1::uuid AND action = 'sale.void.denied'
        ORDER BY id DESC LIMIT 1`,
      [TENANT],
    )) as { tenant_id: string; user_id: string; entity: string }[];
    expect(rows[0].tenant_id).toBe(TENANT);
    expect(rows[0].entity).toBe('sales');
  });
});
