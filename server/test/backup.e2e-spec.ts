import { getQueueToken } from '@nestjs/bullmq';
import { Queue } from 'bullmq';
import { createHash } from 'node:crypto';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import {
  QUEUE_BACKUP,
} from '../src/queue/queue.constants.js';
import { QueueProcessorsModule } from '../src/queue/queue.module.js';
import {
  accessToken,
  createTestApp,
  resetTenant,
  seedCustomer,
  seedProduct,
  type TenantFixture,
  type TestApp,
} from './support/fixture.js';

describe('Tenant Backup & Data Portability (e2e)', () => {
  let fixture: TestApp;
  let tenantInfo: TenantFixture;
  let ownerToken: string;
  let nonOwnerToken: string;
  let backupQueue: Queue;

  const TENANT_ID = '44444444-4444-4444-4444-444444444444';
  const OTHER_TENANT_ID = '55555555-5555-5555-5555-555555555555';

  async function waitFor(fn: () => Promise<boolean>, timeoutMs = 8000): Promise<void> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      if (await fn()) return;
      await new Promise((r) => setTimeout(r, 100));
    }
    throw new Error(`Timeout waiting for condition after ${timeoutMs}ms`);
  }

  beforeAll(async () => {
    fixture = await createTestApp([QueueProcessorsModule]);
    backupQueue = fixture.app.get<Queue>(getQueueToken(QUEUE_BACKUP));
  });

  afterAll(async () => {
    await fixture.app.close();
  });

  beforeEach(async () => {
    tenantInfo = await resetTenant(fixture.admin, TENANT_ID, { cache: fixture.cache });
    await resetTenant(fixture.admin, OTHER_TENANT_ID, { cache: fixture.cache });

    ownerToken = accessToken({
      tenantId: tenantInfo.tenantId,
      userId: tenantInfo.userId,
      role: 'owner',
      deviceId: tenantInfo.posDeviceId,
      deviceRole: 'pos',
    });

    nonOwnerToken = accessToken({
      tenantId: tenantInfo.tenantId,
      userId: tenantInfo.userId,
      role: 'owner',
    });

    await backupQueue.obliterate({ force: true });
  });

  describe('AC1: Device Gate Authorization (F6)', () => {
    it('rejects token without deviceId on POST /backup/export with 403 DEVICE_ROLE_FORBIDDEN', async () => {
      const res = await request(fixture.app.getHttpServer())
        .post('/api/v1/backup/export')
        .set('Authorization', `Bearer ${nonOwnerToken}`);

      expect(res.status).toBe(403);
      expect(res.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');
    });

    it('rejects token without deviceId on GET /backup/jobs/:id with 403 DEVICE_ROLE_FORBIDDEN', async () => {
      const res = await request(fixture.app.getHttpServer())
        .get('/api/v1/backup/jobs/any-id')
        .set('Authorization', `Bearer ${nonOwnerToken}`);

      expect(res.status).toBe(403);
      expect(res.body.error.code).toBe('DEVICE_ROLE_FORBIDDEN');
    });
  });

  describe('AC2 & AC5: Enqueue, Processing, Status & Snapshot retrieval', () => {
    it('enqueues export job, processes snapshot with complete data and records audit log', async () => {
      // Seed rich test data
      const prodId = 'prod-bk-1';
      await seedProduct(fixture.admin, TENANT_ID, {
        id: prodId,
        partNo: 'BK-001',
        name: 'Brake Pad',
        category: 'เบรก',
        price: 850,
        cost: 500,
        stock: 20,
      });

      const custId = 'cust-bk-1';
      await seedCustomer(fixture.admin, TENANT_ID, {
        id: custId,
        code: 'CUS-BK-1',
        name: 'Prasert',
        points: 50,
        totalSpend: 1500,
      });

      // Insert an active shift with a drawer entry
      const shiftId = 'sh-bk-1';
      await fixture.admin.query(
        `INSERT INTO shifts (tenant_id, id, date_str, starting_cash, opened_at, is_active)
         VALUES ($1::uuid, $2, '2026-09-13', 2000.00, now(), true)`,
        [TENANT_ID, shiftId],
      );
      await fixture.admin.query(
        `INSERT INTO drawer_entries (tenant_id, id, shift_id, type, amount, note, created_at)
         VALUES ($1::uuid, 'de-bk-1', $2, 'in', 500.00, 'เงินสดย่อย', now())`,
        [TENANT_ID, shiftId],
      );

      // Insert a sale with sale_items
      const saleId = 'sale-bk-1';
      await fixture.admin.query(
        `INSERT INTO sales (tenant_id, id, receipt_no, subtotal, discount, total, payment_method, points_granted, date, voided)
         VALUES ($1::uuid, $2, 'RC-BK-1', 850.00, 0.00, 850.00, 'เงินสด', 85, now(), false)`,
        [TENANT_ID, saleId],
      );
      await fixture.admin.query(
        `INSERT INTO sale_items (tenant_id, sale_id, line_no, product_id, part_no, name, qty, price, cost_at_sale)
         VALUES ($1::uuid, $2, 1, $3, 'BK-001', 'Brake Pad', 1, 850.00, 500.00)`,
        [TENANT_ID, saleId, prodId],
      );

      // 1. AC2: POST /backup/export enqueues job and returns 202 Accepted
      const exportRes = await request(fixture.app.getHttpServer())
        .post('/api/v1/backup/export')
        .set('Authorization', `Bearer ${ownerToken}`);

      expect(exportRes.status).toBe(202);
      expect(exportRes.body.data).toMatchObject({
        jobId: expect.any(String),
        status: 'queued',
      });

      const jobId = exportRes.body.data.jobId;

      // 2. Poll GET /backup/jobs/:id until job completes
      await waitFor(async () => {
        const job = await backupQueue.getJob(jobId);
        if (!job) return false;
        const state = await job.getState();
        return state === 'completed';
      });

      // 3. AC5: GET /backup/jobs/:id returns status and data
      const jobRes = await request(fixture.app.getHttpServer())
        .get(`/api/v1/backup/jobs/${jobId}`)
        .set('Authorization', `Bearer ${ownerToken}`);

      expect(jobRes.status).toBe(200);
      expect(jobRes.body.data.id).toBe(jobId);
      expect(jobRes.body.data.status).toBe('completed');
      expect(jobRes.body.data.error).toBeNull();

      // The job (i.e. redis-queue) holds only the small descriptor, never the snapshot.
      const stored = await backupQueue.getJob(jobId);
      expect(JSON.stringify(stored!.returnvalue)).not.toContain('sa_products');
      const descriptor = jobRes.body.data.data;
      expect(descriptor).toMatchObject({
        sizeBytes: expect.any(Number),
        sha256: expect.stringMatching(/^[0-9a-f]{64}$/),
        downloadPath: `/api/v1/backup/jobs/${jobId}/download`,
      });

      // 4. AC4: download streams the standard snapshot JSON
      const dlRes = await request(fixture.app.getHttpServer())
        .get(descriptor.downloadPath)
        .set('Authorization', `Bearer ${ownerToken}`)
        .buffer(true)
        .parse((res, cb) => {
          const chunks: Buffer[] = [];
          res.on('data', (c: Buffer) => chunks.push(c));
          res.on('end', () => cb(null, Buffer.concat(chunks)));
        });
      expect(dlRes.status).toBe(200);
      expect(dlRes.headers['content-disposition']).toMatch(/^attachment; filename="backup-/);
      const bytes = dlRes.body as Buffer;
      expect(bytes.length).toBe(descriptor.sizeBytes);
      expect(createHash('sha256').update(bytes).digest('hex')).toBe(descriptor.sha256);
      const snapshot = JSON.parse(bytes.toString('utf8'));
      expect(snapshot).toBeDefined();
      expect(snapshot.__meta).toMatchObject({
        version: 2,
        schemaVersion: 2,
        exportedAt: expect.any(String),
        shopName: expect.any(String),
      });

      // Products verification
      const exportedProd = snapshot.sa_products.find((p: any) => p.id === prodId);
      expect(exportedProd).toBeDefined();
      expect(exportedProd.partNo).toBe('BK-001');
      expect(exportedProd.price).toBe(850);
      expect(exportedProd.cost).toBe(500);

      // Customers verification
      const exportedCust = snapshot.sa_customers.find((c: any) => c.id === custId);
      expect(exportedCust).toBeDefined();
      expect(exportedCust.name).toBe('Prasert');
      expect(exportedCust.points).toBe(50);

      // Sales verification with nested items
      const exportedSale = snapshot.sa_sales.find((s: any) => s.id === saleId);
      expect(exportedSale).toBeDefined();
      expect(exportedSale.receiptNo).toBe('RC-BK-1');
      expect(exportedSale.items).toHaveLength(1);
      expect(exportedSale.items[0].productId).toBe(prodId);
      expect(exportedSale.items[0].cost).toBe(500);

      // Cash drawer verification
      expect(snapshot.sa_cash_drawer).toBeDefined();
      expect(snapshot.sa_cash_drawer.id).toBe(shiftId);
      expect(snapshot.sa_cash_drawer.entries).toHaveLength(1);
      expect(snapshot.sa_cash_drawer.entries[0].amount).toBe(500);

      // Record counts
      expect(snapshot.__meta.recordCounts.products).toBeGreaterThanOrEqual(1);
      expect(snapshot.__meta.recordCounts.sales).toBeGreaterThanOrEqual(1);
      expect(snapshot.__meta.recordCounts.customers).toBeGreaterThanOrEqual(1);
      expect(snapshot.__meta.recordCounts.cashDrawer).toBe(1);

      // 5. AC3: Verify audit log row created
      const auditRows = await fixture.admin.query(
        `SELECT action, entity, entity_id, user_id
           FROM audit_log
          WHERE tenant_id = $1::uuid AND action = 'backup.exported'`,
        [TENANT_ID],
      );
      expect(auditRows).toHaveLength(1);
      expect(auditRows[0].action).toBe('backup.exported');
      expect(auditRows[0].entity).toBe('tenants');
      expect(auditRows[0].entity_id).toBe(TENANT_ID);
      expect(auditRows[0].user_id).toBe(tenantInfo.userId);
    });

    it('AC5: rejects cross-tenant job access with 404 Not Found', async () => {
      // 1. Enqueue job under TENANT_ID
      const exportRes = await request(fixture.app.getHttpServer())
        .post('/api/v1/backup/export')
        .set('Authorization', `Bearer ${ownerToken}`);

      const jobId = exportRes.body.data.jobId;

      // 2. Token from OTHER_TENANT_ID attempts to read this job
      const otherOwnerToken = accessToken({
        tenantId: OTHER_TENANT_ID,
        userId: 'other-user-uuid',
        role: 'owner',
        deviceId: 'other-pos-device',
        deviceRole: 'pos',
      });

      const crossRes = await request(fixture.app.getHttpServer())
        .get(`/api/v1/backup/jobs/${jobId}`)
        .set('Authorization', `Bearer ${otherOwnerToken}`);

      expect(crossRes.status).toBe(404);
      expect(crossRes.body.error.code).toBe('NOT_FOUND');

      // …nor download its file, once it exists.
      await waitFor(async () => (await (await backupQueue.getJob(jobId))?.getState()) === 'completed');
      const crossDl = await request(fixture.app.getHttpServer())
        .get(`/api/v1/backup/jobs/${jobId}/download`)
        .set('Authorization', `Bearer ${otherOwnerToken}`);
      expect(crossDl.status).toBe(404);
      expect(crossDl.body.error.code).toBe('NOT_FOUND');
    });

    it('AC5: returns 404 for non-existent job ID', async () => {
      const res = await request(fixture.app.getHttpServer())
        .get('/api/v1/backup/jobs/non-existent-job-id')
        .set('Authorization', `Bearer ${ownerToken}`);

      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('NOT_FOUND');
    });
  });
});
