import type { INestApplication } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import request from 'supertest';
import type { DataSource } from 'typeorm';
import type { Redis } from 'ioredis';
import { signJwt } from '../src/common/jwt.js';
import { hashPassword } from '../src/common/password.js';
import { APP_CONFIG, type AppConfig } from '../src/config/config.js';
import { TenantImportService } from '../src/platform/tenant-import.service.js';
import { QueueProcessorsModule } from '../src/queue/queue.module.js';
import { generateSyntheticSnapshot } from './fixtures/synthetic-snapshot.js';
import { accessToken, clearTenantCache, createTestApp, TENANT_TABLES_DEPTH_FIRST } from './support/fixture.js';
import { checkSnapshotInvariants, reconcileImport, snapshotShifts } from './support/snapshot-checks.js';

/**
 * #185 / #239 — a shop snapshot through the tenant import path and `01_DATABASE.md §9`, end to
 * end: provision the tenant with `POST /platform/tenants` (step 1), pre-flight the file (step 2),
 * `POST /platform/tenants/:id/import` it over HTTP — `202 Accepted` + a `jobId` since #239, so the
 * suite polls `GET .../import/:jobId` for the worker (`TenantImportProcessor`, run in-process via
 * `QueueProcessorsModule` — same pattern as `backup.e2e-spec.ts`) to finish (steps 3–4), then the
 * six checks (step 5), and finally proves the tenant is usable: the imported drawer is archived and
 * visible, the closing report reads it, and a first new bill takes number 0001 against the imported
 * stock.
 *
 * By default the snapshot is the synthetic one (`test/fixtures/synthetic-snapshot.ts`). For the
 * shop's real file — never committed — run only this file:
 *
 *   SNAPSHOT_FILE=/path/backup.json KEEP_TENANT=1 RECONCILE_OUT=/tmp/evidence.json \
 *     corepack pnpm test:e2e test/import-snapshot.e2e-spec.ts
 *
 * `KEEP_TENANT=1` leaves the imported tenant in place as the demo tenant. `RECONCILE_OUT` writes
 * the evidence with counts and totals only — no customer/mechanic codes, no document numbers.
 */
const REAL_FILE = process.env.SNAPSHOT_FILE;
const KEEP = process.env.KEEP_TENANT === '1';
const REPORT = process.env.RECONCILE_OUT;

type Json = Record<string, any>;

async function waitFor(fn: () => Promise<boolean>, timeoutMs = 20000): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await fn()) return;
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  throw new Error(`Timeout waiting for condition after ${timeoutMs}ms`);
}

describe('tenant import of a shop snapshot through the 01 §9 checklist (#185, #239)', () => {
  let app: INestApplication;
  let admin: DataSource;
  let cache: Redis;
  let adminId: string;
  let adminToken: string;
  const tenants: string[] = [];

  beforeAll(async () => {
    ({ app, admin, cache } = await createTestApp([QueueProcessorsModule]));
    const config = app.get<AppConfig>(APP_CONFIG);
    adminId = randomUUID();
    await admin.query(
      `INSERT INTO platform_admins (id, username, password_hash, display_name, is_active)
       VALUES ($1, $2, $3, 'Import Admin', true)`,
      [adminId, `import-admin-${adminId.slice(0, 8)}`, await hashPassword('import-secret-185')],
    );
    adminToken = signJwt(
      { iss: 'srisurart-pos', aud: 'platform', sub: adminId, username: `import-admin-${adminId.slice(0, 8)}` },
      config.jwtPlatformSecret,
    );
  });

  afterAll(async () => {
    if (!KEEP) {
      for (const tid of tenants) {
        await clearTenantCache(cache, tid);
        for (const table of TENANT_TABLES_DEPTH_FIRST) {
          await admin.query(`DELETE FROM ${table} WHERE tenant_id = $1::uuid`, [tid]);
        }
        await admin.query(`DELETE FROM tenants WHERE id = $1::uuid`, [tid]);
      }
      await admin.query(`DELETE FROM audit_log WHERE platform_admin_id = $1`, [adminId]);
      await admin.query(`DELETE FROM platform_admins WHERE id = $1`, [adminId]);
    }
    await cache?.del(`pa:${adminId}:exists`);
    await app?.close();
  });

  /** §9 step 1: the tenant, its owner and its first device come from provisioning, never SQL. */
  const provision = async (): Promise<string> => {
    const code = `import-${randomUUID().slice(0, 8)}`;
    const res = await request(app.getHttpServer())
      .post('/api/v1/platform/tenants')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ code, shopName: 'ร้านสาธิตนำเข้าข้อมูล', shopNameEn: 'Import Demo', plan: 'demo', ownerUsername: `owner-${code}`, ownerPassword: 'import-owner-185' });
    expect(res.status).toBe(201);
    tenants.push(res.body.data.tenantId);
    return res.body.data.tenantId as string;
  };

  /** §9 steps 2-4: pre-flight, then enqueue — #239: 202 + jobId, never 201 any more. */
  const importFile = (tenantId: string, snapshot: Json) =>
    request(app.getHttpServer())
      .post(`/api/v1/platform/tenants/${tenantId}/import`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send(snapshot);

  const getImportJob = (tenantId: string, jobId: string) =>
    request(app.getHttpServer())
      .get(`/api/v1/platform/tenants/${tenantId}/import/${jobId}`)
      .set('Authorization', `Bearer ${adminToken}`);

  /** Polls the job status endpoint (not BullMQ's own `job.getState()`) until it leaves
   * `queued`/`running` — `import_jobs` is the single source of truth #239 establishes. */
  const waitForImportJob = async (tenantId: string, jobId: string): Promise<Json> => {
    let last: Json = {};
    await waitFor(async () => {
      const res = await getImportJob(tenantId, jobId);
      expect(res.status).toBe(200);
      last = res.body.data;
      return last.status === 'succeeded' || last.status === 'failed';
    });
    return last;
  };

  const count = async (tenantId: string, table: string) =>
    Number((await admin.query(`SELECT count(*)::int AS n FROM ${table} WHERE tenant_id = $1`, [tenantId]))[0].n);

  // `realistic` carries what a real Drift file does: history naming hard-deleted products,
  // customers and mechanics, which the import turns into tombstones (#238); and a customer and
  // a mechanic the shop *soft*-deleted (still present in the file) — imported soft-deleted, not
  // live (#239 item 4).
  const PROFILES = REAL_FILE ? ['SNAPSHOT_FILE'] : ['clean', 'realistic'];

  it.each(PROFILES)('imports the %s snapshot and passes all six post-import checks', async (profile) => {
    const label = REAL_FILE ? 'SNAPSHOT_FILE' : `synthetic full/${profile}`;
    const snapshot: Json = REAL_FILE
      ? JSON.parse(readFileSync(REAL_FILE, 'utf8'))
      : generateSyntheticSnapshot({ scale: 'full', profile: profile as 'clean' | 'realistic' });
    const bytes = Buffer.byteLength(JSON.stringify(snapshot));
    const evidence: Json = { snapshot: label, bytes };
    const report = (extra: Json) =>
      REPORT && writeFileSync(REAL_FILE ? REPORT : REPORT.replace(/(\.json)?$/, `.${profile}.json`), JSON.stringify(Object.assign(evidence, extra), null, 2));

    // §9 step 2: pre-flight on the JSON alone. A violation stops the run — §9 says stop and
    // decide, never import and hope. (The console output may name documents; the report does not.)
    const preflight = checkSnapshotInvariants(snapshot);
    console.info(`snapshot ${label}: ${(bytes / 1024).toFixed(0)} KiB`, preflight);
    report({ preflight: { violations: preflight.violations.length, orphans: preflight.orphans, tombstones: preflight.tombstones } });
    expect(preflight.violations).toEqual([]);
    if (profile === 'realistic') {
      expect(preflight.tombstones.products + preflight.tombstones.customers + preflight.tombstones.mechanics).toBeGreaterThan(0);
      // #252: a supplier row for a product neither live nor tombstoned — dropped, not refused.
      expect(preflight.tombstones.droppedSuppliers).toBeGreaterThan(0);
    }

    const tenantId = await provision();
    const started = Date.now();
    const res = await importFile(tenantId, snapshot);
    // #239: the server's own pre-flight (`snapshot-preflight.ts` + `snapshot-tombstones.ts`)
    // must agree with the client-side checker above — a real gap here means one of the two
    // disagrees with the other, not that either is wrong on its own.
    expect(res.status).toBe(202);
    expect(res.body.data).toMatchObject({ jobId: expect.any(String) });
    const jobId = res.body.data.jobId as string;

    const job = await waitForImportJob(tenantId, jobId);
    const importMs = Date.now() - started;
    console.info(`import job ${jobId} answered ${job.status} in ${importMs} ms`, job.status === 'failed' ? job.error : '');
    report({ importStatus: job.status, importMs, tenantId: KEEP ? tenantId : undefined });
    expect(job.status).toBe('succeeded');
    const { products, customers, mechanics, droppedSuppliers } = preflight.tombstones;
    expect(job.tombstones).toEqual({ products, customers, mechanics });
    expect(job.droppedSuppliers).toBe(droppedSuppliers);
    // Audited inside the import transaction, with the count per table.
    const [audit] = await admin.query(
      `SELECT after FROM audit_log WHERE tenant_id = $1 AND action = 'platform.tenant.import'`,
      [tenantId],
    );
    expect(audit.after).toEqual({ tombstones: { products, customers, mechanics }, droppedSuppliers });

    // §9 step 5.
    const rows = await reconcileImport(admin, tenantId, snapshot);
    console.table(rows);
    if (KEEP) console.info(`demo tenant kept: ${tenantId}`);
    report({ rows });
    expect(rows.filter((r) => !r.ok)).toEqual([]);

    // The file's drawer is archived, never left active with no device (review of #244):
    // nothing is "current", and the newest shift with its entries is in history.
    const latest = [...snapshotShifts(snapshot)].sort((a, b) => Date.parse(b.openedAt) - Date.parse(a.openedAt))[0];
    const owner = accessToken({ tenantId, role: 'owner' });
    const get = (path: string, token = owner) => request(app.getHttpServer()).get(`/api/v1${path}`).set('Authorization', `Bearer ${token}`);
    expect(await count(tenantId, 'shifts')).toBeGreaterThan(0);
    expect((await admin.query(`SELECT count(*)::int AS n FROM shifts WHERE tenant_id = $1 AND is_active`, [tenantId]))[0].n).toBe(0);
    expect((await get('/shifts/current')).body.data ?? null).toBeNull();
    const history = await get('/shifts/history?page=1&limit=1');
    expect(history.status).toBe(200);
    const newest = history.body.data[0];
    expect(newest.dateStr ?? newest.date_str).toBe(latest.date);
    expect(newest.entries).toHaveLength((latest.entries ?? []).length);

    // The same drawer, as the closing report reads it. Imported bills carry no `shift_id`
    // (the file does not link them), so only starting cash and entries count.
    const closing = await get(`/reports/closing?shiftId=${encodeURIComponent(newest.id)}`);
    expect(closing.status).toBe(200);
    report({ closing: closing.body.data });
    const entries = (latest.entries ?? []) as Json[];
    const flow = (type: string) => entries.filter((e) => e.type === type).reduce((t, e) => t + Math.round(Number(e.amount) * 100), 0);
    expect(closing.body.data.startingCash).toBe(Number(latest.startingCash).toFixed(2));
    expect(Math.round(Number(closing.body.data.drawerIn) * 100)).toBe(flow('in'));
    expect(Math.round(Number(closing.body.data.drawerOut) * 100)).toBe(flow('out'));

    // Document numbers: the import seeds no counter, and no imported number is in the
    // server's format, so the first new bill is 0001 and cannot collide.
    expect(await count(tenantId, 'doc_counters')).toBe(0);
    const serverFormat = /^(RC|CN|PO|QT|CP)\d{2}-\d{4}-\d{2}-\d{4}$/;
    const numbers = [
      ...(snapshot.sa_sales ?? []).map((x: Json) => x.receiptNo),
      ...(snapshot.sa_returns ?? []).map((x: Json) => x.cnNo),
      ...(snapshot.sa_pos ?? []).map((x: Json) => x.poNo),
      ...(snapshot.sa_quotes ?? []).map((x: Json) => x.quoteNo),
      ...(snapshot.sa_credit_payments ?? []).map((x: Json) => x.receiptNo),
    ];
    expect(numbers.filter((n) => serverFormat.test(String(n)))).toEqual([]);

    if (REAL_FILE) return; // never ring a bill into the shop's own data
    const pos = accessToken({ tenantId, role: 'owner', deviceId: 'pos1', deviceRole: 'pos' });
    const opened = await request(app.getHttpServer())
      .post('/api/v1/shifts/open')
      .set('Authorization', `Bearer ${pos}`)
      .set('Idempotency-Key', `k-open-${randomUUID()}`)
      .send({ startingCash: '1000.00' });
    expect(opened.status).toBe(200);
    // The imported drawer stays in history once a device has opened its own.
    expect((await get('/shifts/current')).body.data.id).toBe(opened.body.data.id);
    expect((await get('/shifts/history?page=1&limit=1')).body.data[0].id).toBe(newest.id);

    const [product] = await admin.query(
      `SELECT id, part_no, name, price, stock FROM products WHERE tenant_id = $1 AND stock > 0 ORDER BY id LIMIT 1`,
      [tenantId],
    );
    const sale = await request(app.getHttpServer())
      .post('/api/v1/sales')
      .set('Authorization', `Bearer ${pos}`)
      .set('Idempotency-Key', `k-sale-${randomUUID()}`)
      .send({
        id: `s-after-import-${randomUUID()}`, subtotal: product.price, discount: '0.00', total: product.price,
        paymentMethod: 'เงินสด', items: [{ lineNo: 1, productId: product.id, name: product.name, qty: 1, price: product.price }],
      });
    expect(sale.status).toBe(201);
    expect(sale.body.data.receiptNo).toMatch(/^RC01-\d{4}-\d{2}-0001$/);
    const [after] = await admin.query(`SELECT stock FROM products WHERE tenant_id = $1 AND id = $2`, [tenantId, product.id]);
    expect(after.stock).toBe(product.stock - 1);
    report({ firstBillAfterImport: { numberedFrom0001: true, stockBefore: product.stock, stockAfter: after.stock } });
  }, 60000);

  it.skipIf(Boolean(REAL_FILE))('fails the job and rolls the whole shop back when one row is refused (§9 step 4)', async () => {
    const snapshot = generateSyntheticSnapshot({ scale: 'small', profile: 'clean' }) as Json;
    // One of the last rows the import writes (after every sale, return, PO and movement):
    // a drawer entry with a `type` Postgres refuses (CHECK type IN ('in','out')). Pre-flight
    // does not catch this one — it validates the entry's *amount* (#239 item 3) but not its
    // `type`, which the importer writes as whatever string the file supplies — so it still
    // reaches the transaction and rolls back exactly as before, only now as a `failed` job
    // instead of a 4xx response. (A zero/negative `amount` here, the original poison, is now
    // refused in pre-flight itself — that path is `import-snapshot.e2e-spec.ts`'s
    // `positiveMoney` coverage, proved directly in `snapshot-preflight.spec.ts`.)
    const history = snapshot.sa_shift_history as Json[];
    history[history.length - 1].entries.push({ id: 'de-poison', type: 'sideways', amount: 100, note: 'poison', createdAt: '2026-05-01T03:00:00.000Z' });

    const tenantId = await provision();
    const res = await importFile(tenantId, snapshot);
    expect(res.status).toBe(202);
    const job = await waitForImportJob(tenantId, res.body.data.jobId);
    expect(job.status).toBe('failed');
    expect(typeof job.error).toBe('string');
    for (const table of ['products', 'sales', 'customers', 'mechanics', 'shifts', 'drawer_entries', 'movements']) {
      expect({ table, n: await count(tenantId, table) }).toEqual({ table, n: 0 });
    }
    // #239 review issue 2: the job's `succeeded` write lives inside the same transaction as
    // the business data (`writeSnapshot`'s last statement) — a rollback here must roll that
    // back too, so the row is never left `succeeded` with no data behind it, and it never
    // even reaches `result` (`markFailed`'s own UPDATE only ever sets `status`/`error`).
    const [row] = await admin.query(`SELECT status, result FROM import_jobs WHERE tenant_id = $1 AND id = $2`, [tenantId, res.body.data.jobId]);
    expect(row.status).toBe('failed');
    expect(row.result).toBeNull();
  }, 30000);

  it.skipIf(Boolean(REAL_FILE))('refuses a second import into a tenant that already has bills, synchronously', async () => {
    const snapshot = generateSyntheticSnapshot({ scale: 'small', profile: 'clean' });
    const tenantId = await provision();
    const first = await importFile(tenantId, snapshot);
    expect(first.status).toBe(202);
    const job = await waitForImportJob(tenantId, first.body.data.jobId);
    expect(job.status).toBe('succeeded');
    // §9's "tenant already has bills" refusal is pre-flight, synchronous — no job, no poll.
    const again = await importFile(tenantId, snapshot);
    expect(again.status).toBe(409);
  }, 30000);

  it.skipIf(Boolean(REAL_FILE))('refuses a second import while the first is still queued or running, with 409', async () => {
    const snapshot = generateSyntheticSnapshot({ scale: 'full', profile: 'clean' });
    const tenantId = await provision();
    const first = await importFile(tenantId, snapshot);
    expect(first.status).toBe(202);
    // The second attempt races the worker — it may find `queued` or `running`, but either
    // way `uq_import_jobs_active` refuses it before a second worker could ever start.
    const second = await importFile(tenantId, snapshot);
    expect(second.status).toBe(409);
    await waitForImportJob(tenantId, first.body.data.jobId);
  }, 30000);

  // #239 review issue 1(a): a worker crash or a BullMQ stall detection can leave a row
  // `queued`/`running` forever — nothing else ever transitions it — and `uq_import_jobs_active`
  // then refuses every later import for that tenant. `createJob` reclaims a row this stale
  // (`STALE_JOB_CEILING_MINUTES` = 30 minutes) before it tries to insert a new one, but a
  // genuinely fresh in-flight row must still win the 409, same as today.
  it.skipIf(Boolean(REAL_FILE))('reclaims a stale queued/running import job instead of refusing forever (#239 issue 1a)', async () => {
    const tenantId = await provision();
    const staleJobId = `imp_stale_${randomUUID()}`;
    await admin.query(
      `INSERT INTO import_jobs (tenant_id, id, status, payload, started_at, created_at)
       VALUES ($1, $2, 'running', '{}'::jsonb, now() - interval '31 minutes', now() - interval '31 minutes')`,
      [tenantId, staleJobId],
    );

    const snapshot = generateSyntheticSnapshot({ scale: 'small', profile: 'clean' });
    const res = await importFile(tenantId, snapshot);
    expect(res.status).toBe(202);
    expect(res.body.data.jobId).not.toBe(staleJobId);

    const [stale] = await admin.query(
      `SELECT status, error, payload FROM import_jobs WHERE tenant_id = $1 AND id = $2`,
      [tenantId, staleJobId],
    );
    expect(stale.status).toBe('failed');
    expect(stale.error).toBe('stale: worker lost');
    expect(stale.payload).toBeNull();

    const job = await waitForImportJob(tenantId, res.body.data.jobId);
    expect(job.status).toBe('succeeded');
  }, 30000);

  it.skipIf(Boolean(REAL_FILE))('never reclaims a running row that is still within the staleness ceiling — 409, same as today', async () => {
    const tenantId = await provision();
    const freshJobId = `imp_fresh_${randomUUID()}`;
    await admin.query(
      `INSERT INTO import_jobs (tenant_id, id, status, payload, started_at, created_at)
       VALUES ($1, $2, 'running', '{}'::jsonb, now() - interval '5 minutes', now() - interval '5 minutes')`,
      [tenantId, freshJobId],
    );

    const snapshot = generateSyntheticSnapshot({ scale: 'small', profile: 'clean' });
    const res = await importFile(tenantId, snapshot);
    expect(res.status).toBe(409);

    const [fresh] = await admin.query(`SELECT status FROM import_jobs WHERE tenant_id = $1 AND id = $2`, [tenantId, freshJobId]);
    expect(fresh.status).toBe('running'); // untouched — the reclaim never fired on it
  }, 15000);

  // #239 review issue 2: `writeSnapshot` writes `status = 'succeeded'` in the same transaction
  // as the business data, so a `processJob` retry that lands after the commit (the worker's
  // own acknowledgement lost, not the import) must answer the recorded result instead of
  // re-running the write — the tenant already has bills by then, so re-running would 409
  // in pre-flight if the short-circuit were missing.
  it.skipIf(Boolean(REAL_FILE))('processJob is idempotent once the job is already succeeded (#239 issue 2)', async () => {
    const snapshot = generateSyntheticSnapshot({ scale: 'small', profile: 'clean' });
    const tenantId = await provision();
    const first = await importFile(tenantId, snapshot);
    expect(first.status).toBe(202);
    const jobId = first.body.data.jobId as string;
    const job = await waitForImportJob(tenantId, jobId);
    expect(job.status).toBe('succeeded');
    const before = await count(tenantId, 'products');

    const importService = app.get(TenantImportService);
    const replay = await importService.processJob(jobId);
    expect(replay).toEqual({ tombstones: job.tombstones, droppedSuppliers: job.droppedSuppliers });

    // Not re-imported: same product count as right after the first (real) run.
    expect(await count(tenantId, 'products')).toBe(before);
  }, 30000);
});
