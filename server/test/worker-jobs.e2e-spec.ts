import { getQueueToken } from '@nestjs/bullmq';
import { Queue } from 'bullmq';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import {
  JOB_IDEM_CLEANUP,
  JOB_INVENTORY_CHECK,
  JOB_QUOTES_PURGE,
  JOB_SALE_CREATED,
  QUEUE_INVENTORY,
  QUEUE_MAINTENANCE,
  QUEUE_SALE_POST,
} from '../src/queue/queue.constants.js';
import { QueueProcessorsModule } from '../src/queue/queue.module.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedOpenShift,
  seedProduct,
  type TenantFixture,
  type TestApp,
} from './support/fixture.js';

describe('Worker Jobs & Queue Integration (e2e)', () => {
  let fixture: TestApp;
  let tenantInfo: TenantFixture;
  let token: string;
  let salePostQueue: Queue;
  let inventoryQueue: Queue;
  let maintenanceQueue: Queue;

  const TENANT_ID = '33333333-3333-3333-3333-333333333333';

  async function waitFor(fn: () => Promise<boolean>, timeoutMs = 8000): Promise<void> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      if (await fn()) return;
      await new Promise((resolve) => setTimeout(resolve, 150));
    }
    throw new Error(`Timeout waiting for condition after ${timeoutMs}ms`);
  }

  beforeAll(async () => {
    fixture = await createTestApp([QueueProcessorsModule]);
    salePostQueue = fixture.app.get<Queue>(getQueueToken(QUEUE_SALE_POST));
    inventoryQueue = fixture.app.get<Queue>(getQueueToken(QUEUE_INVENTORY));
    maintenanceQueue = fixture.app.get<Queue>(getQueueToken(QUEUE_MAINTENANCE));
  });

  afterAll(async () => {
    await fixture.app.close();
  });

  beforeEach(async () => {
    tenantInfo = await resetTenant(fixture.admin, TENANT_ID, { cache: fixture.cache });
    token = accessToken({
      tenantId: tenantInfo.tenantId,
      userId: tenantInfo.userId,
      role: 'owner',
      deviceId: tenantInfo.posDeviceId,
      deviceRole: 'pos',
    });
    // `POST /sales` refuses with 409 NO_OPEN_SHIFT when the device has no open drawer
    // (owner's decision, 2026-09-13).
    await seedOpenShift(fixture.admin, TENANT_ID, tenantInfo.posDeviceId, {
      userId: tenantInfo.userId,
    });

    await salePostQueue.obliterate({ force: true });
    await inventoryQueue.obliterate({ force: true });
    await maintenanceQueue.obliterate({ force: true });
  });

  describe('AC2 & AC3: Post-commit enqueue and rollback guarantees', () => {
    it('AC2: enqueues sale.created strictly post-commit and cascades to inventory.check on low stock', async () => {
      const prodId = 'prod-ac2';
      await seedProduct(fixture.admin, TENANT_ID, {
        id: prodId,
        partNo: 'AC2-1',
        name: 'Oil Filter',
        price: 150,
        cost: 80,
        stock: 5, // min_stock is 0 by default, let's update min_stock to 5
      });
      await fixture.admin.query(
        `UPDATE products SET min_stock = 5 WHERE tenant_id = $1::uuid AND id = $2`,
        [TENANT_ID, prodId],
      );

      const saleId = `sale-post-commit-${Date.now()}`;
      const res = await request(fixture.app.getHttpServer())
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${token}`)
        .set('Idempotency-Key', `k-ac2-${Date.now()}`)
        .send({
          id: saleId,
          subtotal: '150.00',
          discount: '0.00',
          total: '150.00',
          paymentMethod: 'เงินสด',
          items: [{ lineNo: 1, productId: prodId, name: 'Oil Filter', qty: 1, price: '150.00' }],
        });

      expect(res.status).toBe(201);
      expect(res.body.data.id).toBe(saleId);

      // Verify job in salePostQueue
      await waitFor(async () => {
        const jobs = await salePostQueue.getJobs(['waiting', 'active', 'completed']);
        return jobs.some((j) => j.name === JOB_SALE_CREATED && j.data.saleId === saleId);
      });

      const saleJob = (await salePostQueue.getJobs(['waiting', 'active', 'completed'])).find(
        (j) => j.data.saleId === saleId,
      );
      expect(saleJob).toBeDefined();
      expect(saleJob?.data.tenantId).toBe(TENANT_ID);
      expect(saleJob?.data.productIds).toContain(prodId);

      // Stock is now 4 (5 - 1), which is <= min_stock (5), so SalePostProcessor enqueues inventory.check
      await waitFor(async () => {
        const invJobs = await inventoryQueue.getJobs(['waiting', 'active', 'completed']);
        return invJobs.some(
          (j) => j.name === JOB_INVENTORY_CHECK && j.data.productIds?.includes(prodId),
        );
      });
    });

    it('AC3: a rolled-back sale (e.g. insufficient stock) enqueues NOTHING', async () => {
      const prodId = 'prod-ac3';
      await seedProduct(fixture.admin, TENANT_ID, {
        id: prodId,
        partNo: 'AC3-1',
        name: 'Spark Plug',
        price: 80,
        cost: 40,
        stock: 2,
      });

      const failedSaleId = `sale-fail-${Date.now()}`;
      const res = await request(fixture.app.getHttpServer())
        .post('/api/v1/sales')
        .set('Authorization', `Bearer ${token}`)
        .set('Idempotency-Key', `k-ac3-${Date.now()}`)
        .send({
          id: failedSaleId,
          subtotal: '800.00',
          discount: '0.00',
          total: '800.00',
          paymentMethod: 'เงินสด',
          items: [{ lineNo: 1, productId: prodId, name: 'Spark Plug', qty: 10, price: '80.00' }],
        });

      expect(res.status).toBe(409); // INSUFFICIENT_STOCK

      // Allow a brief settling delay to ensure no asynchronous background enqueue leaked
      await new Promise((resolve) => setTimeout(resolve, 300));

      const jobs = await salePostQueue.getJobs(['waiting', 'active', 'completed', 'delayed']);
      const leakedJob = jobs.find((j) => j.data.saleId === failedSaleId);
      expect(leakedJob).toBeUndefined();
    });
  });

  describe('AC4: Expired idempotency keys cleanup (idem.cleanup)', () => {
    it('deletes keys older than TTL while preserving fresh keys', async () => {
      const expiredKey = `idem-exp-${Date.now()}`;
      const freshKey = `idem-fresh-${Date.now()}`;

      // Insert expired key (> 24 hours ago)
      await fixture.admin.query(
        `INSERT INTO idempotency_keys (tenant_id, key, endpoint, request_hash, status, response_code, response_body, created_at)
         VALUES ($1::uuid, $2, '/sales', 'hash-exp', 'done', 201, '{"ok":true}', now() - interval '25 hours')`,
        [TENANT_ID, expiredKey],
      );

      // Insert fresh key (1 hour ago)
      await fixture.admin.query(
        `INSERT INTO idempotency_keys (tenant_id, key, endpoint, request_hash, status, response_code, response_body, created_at)
         VALUES ($1::uuid, $2, '/sales', 'hash-fresh', 'done', 201, '{"ok":true}', now() - interval '1 hour')`,
        [TENANT_ID, freshKey],
      );

      // Trigger maintenance job for tenant
      await maintenanceQueue.add(JOB_IDEM_CLEANUP, {
        tenantId: TENANT_ID,
        correlationId: 'corr-clean-test',
        olderThanSeconds: 86400,
      });

      // Wait for expired key to be deleted
      await waitFor(async () => {
        const rows = await fixture.admin.query(
          `SELECT key FROM idempotency_keys WHERE tenant_id = $1::uuid AND key = $2`,
          [TENANT_ID, expiredKey],
        );
        return rows.length === 0;
      });

      // Fresh key must still be intact
      const freshRows = await fixture.admin.query(
        `SELECT key FROM idempotency_keys WHERE tenant_id = $1::uuid AND key = $2`,
        [TENANT_ID, freshKey],
      );
      expect(freshRows).toHaveLength(1);
    });
  });

  describe('#169: idem.cleanup with no tenantId sweeps every tenant under RLS', () => {
    const OTHER_TENANT_ID = '16916916-9169-4169-9169-169169169169';

    it('deletes expired keys in two tenants and keeps fresh ones', async () => {
      await resetTenant(fixture.admin, OTHER_TENANT_ID, { cache: fixture.cache });
      const stamp = Date.now();
      const seed = (tenantId: string, key: string, age: string) =>
        fixture.admin.query(
          `INSERT INTO idempotency_keys (tenant_id, key, endpoint, request_hash, status, response_code, response_body, created_at)
           VALUES ($1::uuid, $2, '/sales', 'hash', 'done', 201, '{"ok":true}', now() - $3::interval)`,
          [tenantId, key, age],
        );
      await seed(TENANT_ID, `g-exp-a-${stamp}`, '25 hours');
      await seed(OTHER_TENANT_ID, `g-exp-b-${stamp}`, '25 hours');
      await seed(TENANT_ID, `g-fresh-a-${stamp}`, '1 hour');
      await seed(OTHER_TENANT_ID, `g-fresh-b-${stamp}`, '1 hour');

      const job = await maintenanceQueue.add(JOB_IDEM_CLEANUP, {
        correlationId: `corr-global-${stamp}`,
        olderThanSeconds: 86400,
      });

      const remaining = async (): Promise<string[]> =>
        (
          await fixture.admin.query(
            `SELECT key FROM idempotency_keys WHERE key LIKE $1 ORDER BY key`,
            [`g-%-${stamp}`],
          )
        ).map((r: { key: string }) => r.key);

      // The old branch deleted 0 rows and still completed: wait on the rows, not the job.
      await waitFor(async () => (await remaining()).length === 2);
      expect(await remaining()).toEqual([`g-fresh-a-${stamp}`, `g-fresh-b-${stamp}`]);
      expect((await maintenanceQueue.getJob(job.id!))?.returnvalue).toMatchObject({
        fannedOut: expect.any(Number),
      });
    });
  });

  describe('AC5: POST /quotes/purge & quotes.purge background job', () => {
    it('answers 202 Accepted immediately and purges quotes older than olderThanDays in background', async () => {
      const oldQuoteId = `quote-old-${Date.now()}`;
      const freshQuoteId = `quote-fresh-${Date.now()}`;

      // Seed quote older than 90 days (100 days old, valid_until expired 95 days ago)
      await fixture.admin.query(
        `INSERT INTO quotes (tenant_id, id, quote_no, status, date, valid_until, subtotal, discount, total)
         VALUES ($1::uuid, $2, $3, 'open', now() - interval '100 days', now() - interval '95 days', 200, 0, 200)`,
        [TENANT_ID, oldQuoteId, `QT-OLD-${Date.now()}`],
      );
      await fixture.admin.query(
        `INSERT INTO quote_items (tenant_id, quote_id, line_no, name, qty, price)
         VALUES ($1::uuid, $2, 1, 'Old Gear', 2, 100)`,
        [TENANT_ID, oldQuoteId],
      );

      // Seed fresh quote (10 days old)
      await fixture.admin.query(
        `INSERT INTO quotes (tenant_id, id, quote_no, status, date, valid_until, subtotal, discount, total)
         VALUES ($1::uuid, $2, $3, 'open', now() - interval '10 days', now() + interval '20 days', 100, 0, 100)`,
        [TENANT_ID, freshQuoteId, `QT-FRESH-${Date.now()}`],
      );
      await fixture.admin.query(
        `INSERT INTO quote_items (tenant_id, quote_id, line_no, name, qty, price)
         VALUES ($1::uuid, $2, 1, 'Fresh Belt', 1, 100)`,
        [TENANT_ID, freshQuoteId],
      );

      // Call POST /quotes/purge
      const res = await request(fixture.app.getHttpServer())
        .post('/api/v1/quotes/purge')
        .set('Authorization', `Bearer ${token}`)
        .set('Idempotency-Key', `purge-mgr-${Date.now()}`)
        .send({ olderThanDays: 90 });

      expect(res.status).toBe(202);
      expect(res.body.data.queued).toBe(true);
      expect(res.body.data.olderThanDays).toBe(90);
      expect(res.body.data.jobId).toBeDefined();

      // Wait for background worker to purge old quote
      await waitFor(async () => {
        const rows = await fixture.admin.query(
          `SELECT id FROM quotes WHERE tenant_id = $1::uuid AND id = $2`,
          [TENANT_ID, oldQuoteId],
        );
        return rows.length === 0;
      });

      // Verify cascade deletion of quote_items
      const items = await fixture.admin.query(
        `SELECT line_no FROM quote_items WHERE tenant_id = $1::uuid AND quote_id = $2`,
        [TENANT_ID, oldQuoteId],
      );
      expect(items).toHaveLength(0);

      // Verify fresh quote is untouched
      const freshQuote = await fixture.admin.query(
        `SELECT id FROM quotes WHERE tenant_id = $1::uuid AND id = $2`,
        [TENANT_ID, freshQuoteId],
      );
      expect(freshQuote).toHaveLength(1);
    });

    it('preserves valid open quotes and recently converted quotes even if created > 90 days ago (#122)', async () => {
      const validOpenId = `quote-valid-open-${Date.now()}`;
      const recentConvertedId = `quote-recent-conv-${Date.now()}`;
      const oldConvertedId = `quote-old-conv-${Date.now()}`;

      // Open quote created 100 days ago, but valid_until is 10 days in the future
      await fixture.admin.query(
        `INSERT INTO quotes (tenant_id, id, quote_no, status, date, valid_until, subtotal, discount, total)
         VALUES ($1::uuid, $2, $3, 'open', now() - interval '100 days', now() + interval '10 days', 100, 0, 100)`,
        [TENANT_ID, validOpenId, `QT-VALID-${Date.now()}`],
      );

      // Quote created 120 days ago, converted 10 days ago
      await fixture.admin.query(
        `INSERT INTO quotes (tenant_id, id, quote_no, status, date, valid_until, converted_at, subtotal, discount, total)
         VALUES ($1::uuid, $2, $3, 'converted', now() - interval '120 days', now() - interval '100 days', now() - interval '10 days', 100, 0, 100)`,
        [TENANT_ID, recentConvertedId, `QT-RCONV-${Date.now()}`],
      );

      // Quote created 150 days ago, converted 95 days ago
      await fixture.admin.query(
        `INSERT INTO quotes (tenant_id, id, quote_no, status, date, valid_until, converted_at, subtotal, discount, total)
         VALUES ($1::uuid, $2, $3, 'converted', now() - interval '150 days', now() - interval '130 days', now() - interval '95 days', 100, 0, 100)`,
        [TENANT_ID, oldConvertedId, `QT-OCONV-${Date.now()}`],
      );

      const res = await request(fixture.app.getHttpServer())
        .post('/api/v1/quotes/purge')
        .set('Authorization', `Bearer ${token}`)
        .set('Idempotency-Key', `purge-invariants-${Date.now()}`)
        .send({ olderThanDays: 90 });

      expect(res.status).toBe(202);

      await waitFor(async () => {
        const rows = await fixture.admin.query(
          `SELECT id FROM quotes WHERE tenant_id = $1::uuid AND id = $2`,
          [TENANT_ID, oldConvertedId],
        );
        return rows.length === 0;
      });

      // Valid open quote must be preserved
      const validOpenRows = await fixture.admin.query(
        `SELECT id FROM quotes WHERE tenant_id = $1::uuid AND id = $2`,
        [TENANT_ID, validOpenId],
      );
      expect(validOpenRows).toHaveLength(1);

      // Recently converted quote must be preserved
      const recentConvertedRows = await fixture.admin.query(
        `SELECT id FROM quotes WHERE tenant_id = $1::uuid AND id = $2`,
        [TENANT_ID, recentConvertedId],
      );
      expect(recentConvertedRows).toHaveLength(1);
    });

    it('requires authentication for quote purge', async () => {
      const res = await request(fixture.app.getHttpServer())
        .post('/api/v1/quotes/purge')
        .set('Idempotency-Key', `purge-unauth-${Date.now()}`)
        .send({ olderThanDays: 90 });

      expect(res.status).toBe(401);
    });
  });

  describe('AC1: Handler idempotency', () => {
    it('running quotes.purge repeatedly produces no error and deletes 0 additional rows', async () => {
      // Seed 1 old quote (expired 95 days ago)
      const oldQuoteId = `quote-idem-${Date.now()}`;
      await fixture.admin.query(
        `INSERT INTO quotes (tenant_id, id, quote_no, status, date, valid_until, subtotal, discount, total)
         VALUES ($1::uuid, $2, $3, 'open', now() - interval '100 days', now() - interval '95 days', 100, 0, 100)`,
        [TENANT_ID, oldQuoteId, `QT-IDEM-${Date.now()}`],
      );

      const runId = Date.now();
      const job1 = await maintenanceQueue.add(
        JOB_QUOTES_PURGE,
        {
          tenantId: TENANT_ID,
          correlationId: `corr-idem-q1-${runId}`,
          olderThanDays: 90,
        },
        { jobId: `quotes-purge-idem-1-${runId}` },
      );

      await waitFor(async () => {
        const state = await job1.getState();
        return state === 'completed';
      });

      const completedJob1 = await maintenanceQueue.getJob(job1.id!);
      const res1 = (completedJob1!.returnvalue as any)?.result ?? completedJob1!.returnvalue;
      expect(res1.purged).toBe(true);
      expect(res1.deletedCount).toBe(1);

      // Run second time with identical criteria
      const job2 = await maintenanceQueue.add(
        JOB_QUOTES_PURGE,
        {
          tenantId: TENANT_ID,
          correlationId: `corr-idem-q2-${runId}`,
          olderThanDays: 90,
        },
        { jobId: `quotes-purge-idem-2-${runId}` },
      );

      await waitFor(async () => {
        const state = await job2.getState();
        return state === 'completed';
      });

      const completedJob2 = await maintenanceQueue.getJob(job2.id!);
      const res2 = (completedJob2!.returnvalue as any)?.result ?? completedJob2!.returnvalue;
      expect(res2.purged).toBe(true);
      expect(res2.deletedCount).toBe(0);
    });
  });
});
