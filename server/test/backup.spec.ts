import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Job } from 'bullmq';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { Writable } from 'node:stream';
import { pino } from 'pino';
import { NotFoundException } from '@nestjs/common';
import { DeviceRoleForbiddenException } from '../src/common/device-role-forbidden.exception.js';
import { BackupProcessor } from '../src/queue/processors/backup.processor.js';
import { BackupController } from '../src/backup/backup.controller.js';
import {
  JOB_TENANT_EXPORT,
} from '../src/queue/queue.constants.js';
import { runInRequestContext } from '../src/common/request-context.js';
import {
  EXPORT_TTL_MS,
  exportFilePath,
  pruneExportFiles,
} from '../src/backup/export-file.js';

const logger = pino({ level: 'silent' });

describe('Backup Module (unit)', () => {
  const TENANT_ID = '11111111-1111-1111-1111-111111111111';
  const USER_ID = '22222222-2222-2222-2222-222222222222';
  let exportRoot: string;
  const prevExportDir = process.env.EXPORT_DIR;

  beforeAll(() => {
    exportRoot = mkdtempSync(join(tmpdir(), 'backup-spec-'));
    process.env.EXPORT_DIR = exportRoot;
  });

  afterAll(() => {
    rmSync(exportRoot, { recursive: true, force: true });
    if (prevExportDir === undefined) delete process.env.EXPORT_DIR;
    else process.env.EXPORT_DIR = prevExportDir;
  });

  describe('BackupProcessor', () => {
    let mockEm: { query: ReturnType<typeof vi.fn> };
    let mockTenantJobRunner: { runWithTenantContext: ReturnType<typeof vi.fn> };
    let mockAuditService: { log: ReturnType<typeof vi.fn> };
    let processor: BackupProcessor;

    beforeEach(() => {
      mockEm = {
        query: vi.fn(),
      };
      mockTenantJobRunner = {
        runWithTenantContext: vi.fn(async (_job, fn) => {
          const result = await fn(mockEm as any);
          return { skipped: false, result };
        }),
      };
      mockAuditService = {
        log: vi.fn().mockResolvedValue(undefined),
      };
      processor = new BackupProcessor(
        mockTenantJobRunner as any,
        mockAuditService as any,
        logger,
      );
    });

    it('skips non-export jobs', async () => {
      const job = {
        id: 'job-1',
        name: 'other.job',
        data: { tenantId: TENANT_ID, correlationId: 'c1' },
      } as Job<any>;

      const res = await processor.process(job);
      expect(res).toEqual({ skipped: true, reason: 'UNKNOWN_JOB' });
      expect(mockTenantJobRunner.runWithTenantContext).not.toHaveBeenCalled();
    });

    it('assembles complete snapshot matching legacy sa_* format and records audit log', async () => {
      // Mock queries in the sequence called in BackupProcessor
      // 0. SET LOCAL statement_timeout / idle_in_transaction_session_timeout (#213)
      mockEm.query.mockResolvedValueOnce([]);
      mockEm.query.mockResolvedValueOnce([]);
      // 1. Settings
      mockEm.query.mockResolvedValueOnce([
        {
          shop_name: 'ศรีสุราษฎร์เจริญยนต์',
          shop_name_en: 'Srisurart Autopart',
          tax_rate: '7.00',
          quote_valid_days: 30,
          address: 'Surat Thani',
          phone: '077123456',
        },
      ]);
      // 2. Categories
      mockEm.query.mockResolvedValueOnce([
        { name: 'กรองน้ำมัน', position: 1 },
        { name: 'เบรก', position: 2 },
      ]);
      // 3. Products
      mockEm.query.mockResolvedValueOnce([
        {
          id: 'p-1',
          part_no: 'OF-100',
          name: 'Oil Filter',
          name_th: 'กรองน้ำมันเครื่อง',
          category: 'กรองน้ำมัน',
          brand: 'Denso',
          price: '150.00',
          cost: '90.00',
          stock: 25,
          min_stock: 5,
          compat: 'Toyota Vios',
          updated_at: new Date('2026-09-01T10:00:00.000Z'),
        },
      ]);
      // 4. Customers
      mockEm.query.mockResolvedValueOnce([
        {
          id: 'c-1',
          code: 'CUS-001',
          name: 'Somchai',
          name_th: 'สมชาย',
          phone: '0812345678',
          points: 120,
          total_spend: '4500.00',
          created_at: new Date('2026-08-01T08:00:00.000Z'),
        },
      ]);
      // 5. Mechanics
      mockEm.query.mockResolvedValueOnce([
        {
          id: 'm-1',
          code: 'M-001',
          name: 'Chang Noi',
          name_th: 'ช่างน้อย',
          credit_limit: '10000.00',
          credit_balance: '1200.00',
          total_sales: '5000.00',
          total_credit: '3000.00',
          total_discount: '300.00',
          total_markup: '200.00',
        },
      ]);
      // 6. Sales & SaleItems
      mockEm.query.mockResolvedValueOnce([
        {
          id: 's-1',
          receipt_no: 'RC-001',
          subtotal: '300.00',
          discount: '0.00',
          total: '300.00',
          payment_method: 'เงินสด',
          points_granted: 30,
          date: new Date('2026-09-10T12:00:00.000Z'),
          voided: false,
        },
      ]);
      mockEm.query.mockResolvedValueOnce([
        {
          sale_id: 's-1',
          line_no: 1,
          product_id: 'p-1',
          part_no: 'OF-100',
          name: 'Oil Filter',
          name_th: 'กรองน้ำมันเครื่อง',
          qty: 2,
          price: '150.00',
          cost_at_sale: '90.00',
        },
      ]);
      // 7. Returns & ReturnItems
      mockEm.query.mockResolvedValueOnce([
        {
          id: 'r-1',
          cn_no: 'CN-001',
          sale_id: 's-1',
          receipt_no: 'RC-001',
          refund_subtotal: '150.00',
          refund_discount: '0.00',
          refund_total: '150.00',
          refund_method: 'เงินสด',
          reason: 'สั่งผิดเบอร์',
          date: new Date('2026-09-11T09:00:00.000Z'),
        },
      ]);
      mockEm.query.mockResolvedValueOnce([
        {
          return_id: 'r-1',
          line_no: 1,
          product_id: 'p-1',
          name: 'Oil Filter',
          qty: 1,
          price: '150.00',
          original_qty: 2,
        },
      ]);
      // 8. PurchaseOrders & POItems
      mockEm.query.mockResolvedValueOnce([
        {
          id: 'po-1',
          po_no: 'PO-001',
          supplier: 'Denso Corp',
          status: 'received',
          created_at: new Date('2026-09-02T08:00:00.000Z'),
        },
      ]);
      mockEm.query.mockResolvedValueOnce([
        {
          po_id: 'po-1',
          line_no: 1,
          part_no: 'OF-100',
          name: 'Oil Filter',
          qty: 50,
          cost: '85.00',
        },
      ]);
      // 9. Quotes & QuoteItems
      mockEm.query.mockResolvedValueOnce([
        {
          id: 'q-1',
          quote_no: 'QT-001',
          status: 'open',
          date: new Date('2026-09-05T10:00:00.000Z'),
          valid_until: new Date('2026-10-05T10:00:00.000Z'),
          subtotal: '150.00',
          total: '150.00',
        },
      ]);
      mockEm.query.mockResolvedValueOnce([
        {
          quote_id: 'q-1',
          line_no: 1,
          product_id: 'p-1',
          name: 'Oil Filter',
          qty: 1,
          price: '150.00',
        },
      ]);
      // 10. Movements
      mockEm.query.mockResolvedValueOnce([
        {
          id: 'mov-1',
          product_id: 'p-1',
          part_no: 'OF-100',
          name: 'Oil Filter',
          delta: -2,
          type: 'sale',
          stock_after: 23,
          date: new Date('2026-09-10T12:00:00.000Z'),
        },
      ]);
      // 11. Suppliers
      mockEm.query.mockResolvedValueOnce([
        {
          id: 'sup-1',
          product_id: 'p-1',
          name: 'Denso Corp',
          unit_cost: '85.00',
          freight: '5.00',
        },
      ]);
      // 12. Credit Payments
      mockEm.query.mockResolvedValueOnce([
        {
          id: 'cp-1',
          receipt_no: 'CP-001',
          mechanic_id: 'm-1',
          amount: '500.00',
          date: new Date('2026-09-12T15:00:00.000Z'),
        },
      ]);
      // 13. Shifts & DrawerEntries
      mockEm.query.mockResolvedValueOnce([
        {
          id: 'sh-active',
          date_str: '2026-09-13',
          starting_cash: '1000.00',
          opened_at: new Date('2026-09-13T08:00:00.000Z'),
          is_active: true,
        },
        {
          id: 'sh-closed',
          date_str: '2026-09-12',
          starting_cash: '1000.00',
          opened_at: new Date('2026-09-12T08:00:00.000Z'),
          closed_at: new Date('2026-09-12T18:00:00.000Z'),
          physical_cash: '2500.00',
          is_active: false,
        },
      ]);
      mockEm.query.mockResolvedValueOnce([
        {
          id: 'de-1',
          shift_id: 'sh-active',
          type: 'in',
          amount: '500.00',
          note: 'เงินทอนเพิ่ม',
          created_at: new Date('2026-09-13T09:00:00.000Z'),
        },
      ]);
      // 14. Parked Sales
      mockEm.query.mockResolvedValueOnce([
        {
          id: 'pk-1',
          parked_at: new Date('2026-09-13T09:30:00.000Z'),
          payload: { customer: 'General Customer', items: [] },
        },
      ]);
      // 15. Tenant meta
      mockEm.query.mockResolvedValueOnce([]);

      const job = {
        id: 'job-export-1',
        name: JOB_TENANT_EXPORT,
        data: {
          tenantId: TENANT_ID,
          correlationId: 'corr-1',
          requestedByUserId: USER_ID,
          ip: '127.0.0.1',
        },
      } as Job<any>;

      const execution = await processor.process(job) as { skipped: boolean; result: any };
      expect(execution.skipped).toBe(false);

      // The job's result is only a small descriptor — the snapshot is a file, never Redis.
      const descriptor = execution.result;
      expect(Object.keys(descriptor).sort()).toEqual(
        ['exportedAt', 'recordCounts', 'sha256', 'sizeBytes'],
      );
      const bytes = readFileSync(exportFilePath(TENANT_ID, 'job-export-1'));
      expect(descriptor.sizeBytes).toBe(bytes.length);
      expect(descriptor.sha256).toBe(createHash('sha256').update(bytes).digest('hex'));
      const snapshot = JSON.parse(bytes.toString('utf8'));
      expect(descriptor.recordCounts).toEqual(snapshot.__meta.recordCounts);

      // Validate core snapshot structure
      expect(snapshot.sa_categories).toEqual(['กรองน้ำมัน', 'เบรก']);
      expect(snapshot.sa_products).toHaveLength(1);
      expect(snapshot.sa_products[0].partNo).toBe('OF-100');
      expect(snapshot.sa_products[0].price).toBe(150);

      // Validate nested sale items
      expect(snapshot.sa_sales).toHaveLength(1);
      expect(snapshot.sa_sales[0].receiptNo).toBe('RC-001');
      expect(snapshot.sa_sales[0].items).toHaveLength(1);
      expect(snapshot.sa_sales[0].items[0].name).toBe('Oil Filter');
      expect(snapshot.sa_sales[0].items[0].cost).toBe(90);

      // Validate nested return items
      expect(snapshot.sa_returns).toHaveLength(1);
      expect(snapshot.sa_returns[0].items).toHaveLength(1);
      expect(snapshot.sa_returns[0].items[0].originalQty).toBe(2);

      // Validate shifts split: active vs history
      expect(snapshot.sa_cash_drawer).not.toBeNull();
      expect(snapshot.sa_cash_drawer.id).toBe('sh-active');
      expect(snapshot.sa_cash_drawer.entries).toHaveLength(1);
      expect(snapshot.sa_shift_history).toHaveLength(1);
      expect(snapshot.sa_shift_history[0].id).toBe('sh-closed');

      // Validate __meta block
      expect(snapshot.__meta.version).toBe(2);
      expect(snapshot.__meta.schemaVersion).toBe(2);
      expect(snapshot.__meta.shopName).toBe('ศรีสุราษฎร์เจริญยนต์');
      expect(snapshot.__meta.recordCounts).toEqual({
        products: 1,
        customers: 1,
        sales: 1,
        purchaseOrders: 1,
        movements: 1,
        suppliers: 1,
        mechanics: 1,
        quotes: 1,
        returns: 1,
        creditPayments: 1,
        shiftHistory: 1,
        parked: 1,
        categories: 2,
        cashDrawer: 1,
      });

      // Validate AC3: audit log written
      expect(mockAuditService.log).toHaveBeenCalledWith(
        mockEm,
        expect.objectContaining({
          tenantId: TENANT_ID,
          userId: USER_ID,
          action: 'backup.exported',
          entity: 'tenants',
          entityId: TENANT_ID,
          ip: '127.0.0.1',
        }),
      );
    });
  });

  describe('BackupController', () => {
    let mockQueue: { add: ReturnType<typeof vi.fn>; getJob: ReturnType<typeof vi.fn> };
    let controller: BackupController;

    beforeEach(() => {
      mockQueue = {
        add: vi.fn(),
        getJob: vi.fn(),
      };
      controller = new BackupController(mockQueue as any);
    });

    describe('POST /backup/export (AC1 & AC2)', () => {
      it('AC1: rejects token without deviceId with 403 DEVICE_ROLE_FORBIDDEN', async () => {
        const req: any = { user: { role: 'owner', userId: USER_ID } };
        await expect(controller.exportTenantData(req)).rejects.toThrow(DeviceRoleForbiddenException);
      });

      it('AC2: accepts enrolled device and enqueues job with status queued', async () => {
        mockQueue.add.mockResolvedValueOnce({ id: 'export-job-123' });
        const req: any = {
          user: { role: 'owner', userId: USER_ID, deviceId: 'dev-1' },
          headers: { 'x-forwarded-for': '192.168.1.10' },
          ip: '127.0.0.1',
        };

        const res = await runInRequestContext(
          { tenantId: TENANT_ID, manager: {} as any },
          () => controller.exportTenantData(req),
        );
        expect(res).toEqual({
          jobId: 'export-job-123',
          status: 'queued',
        });
        expect(mockQueue.add).toHaveBeenCalledWith(
          JOB_TENANT_EXPORT,
          expect.objectContaining({
            requestedByUserId: USER_ID,
            ip: '192.168.1.10',
          }),
          expect.any(Object),
        );
      });
    });

    describe('GET /backup/jobs/:id (AC1 & AC5)', () => {
      it('AC1: rejects token without deviceId with 403 DEVICE_ROLE_FORBIDDEN', async () => {
        const req: any = { user: { role: 'owner' } };
        await expect(controller.getJobStatus(req, 'job-1')).rejects.toThrow(DeviceRoleForbiddenException);
      });

      it('AC5: rejects if job not found', async () => {
        mockQueue.getJob.mockResolvedValueOnce(null);
        const req: any = { user: { role: 'owner', deviceId: 'dev-1' } };
        await expect(
          runInRequestContext(
            { tenantId: TENANT_ID, manager: {} as any },
            () => controller.getJobStatus(req, 'job-nonexistent'),
          ),
        ).rejects.toThrow(NotFoundException);
      });

      it('AC5: rejects cross-tenant job lookup with 404', async () => {
        mockQueue.getJob.mockResolvedValueOnce({
          id: 'job-other',
          data: { tenantId: 'different-tenant-uuid' },
        });
        const req: any = { user: { role: 'owner', deviceId: 'dev-1' } };
        await expect(
          runInRequestContext(
            { tenantId: TENANT_ID, manager: {} as any },
            () => controller.getJobStatus(req, 'job-other'),
          ),
        ).rejects.toThrow(NotFoundException);
      });

      it('AC5: returns status and the file descriptor, never the snapshot inline', async () => {
        const descriptor = { sizeBytes: 2, sha256: 'abc', exportedAt: '2026-09-25T00:00:00.000Z', recordCounts: {} };
        mockQueue.getJob.mockResolvedValueOnce({
          id: 'job-mine',
          data: { tenantId: TENANT_ID },
          getState: vi.fn().mockResolvedValue('completed'),
          progress: 100,
          returnvalue: { skipped: false, result: descriptor },
          failedReason: undefined,
        });
        const req: any = { user: { role: 'owner', deviceId: 'dev-1' } };
        const res = await runInRequestContext(
          { tenantId: TENANT_ID, manager: {} as any },
          () => controller.getJobStatus(req, 'job-mine'),
        );

        expect(res.id).toBe('job-mine');
        expect(res.status).toBe('completed');
        expect(res.data).toEqual({
          ...descriptor,
          downloadPath: '/api/v1/backup/jobs/job-mine/download',
        });
      });

      it('opens no transaction: needs only the guard-authorised tenant', async () => {
        mockQueue.getJob.mockResolvedValueOnce(null);
        const req: any = { user: { role: 'owner', deviceId: 'dev-1' } };
        // manager: null — a runTx here would be the only way to need one.
        await expect(
          runInRequestContext(
            { tenantId: TENANT_ID, manager: null as any },
            () => controller.getJobStatus(req, 'job-x'),
          ),
        ).rejects.toThrow(NotFoundException);
      });
    });

    describe('GET /backup/jobs/:id/download', () => {
      const completedJob = (tenantId: string, id = 'dl-1') => ({
        id,
        data: { tenantId },
        getState: vi.fn().mockResolvedValue('completed'),
        returnvalue: {
          skipped: false,
          result: { sizeBytes: 0, sha256: 'x', exportedAt: '2026-09-25T01:02:03.000Z', recordCounts: {} },
        },
      });

      function fakeRes() {
        const chunks: Buffer[] = [];
        const res: any = new Writable({
          write(chunk, _enc, cb) {
            chunks.push(Buffer.from(chunk));
            cb();
          },
        });
        res.headers = {} as Record<string, string>;
        res.status = vi.fn(() => res);
        res.setHeader = (k: string, v: string) => { res.headers[k] = v; };
        res.body = () => Buffer.concat(chunks).toString('utf8');
        res.done = new Promise((r) => res.on('finish', r));
        return res;
      }

      const download = (tenantId: string, id: string, res: any) =>
        runInRequestContext({ tenantId, manager: null as any }, () =>
          controller.downloadExport({ user: { deviceId: 'dev-1' } } as any, id, res),
        );

      it('streams the tenant\'s own export file with attachment headers', async () => {
        const file = exportFilePath(TENANT_ID, 'dl-1');
        mkdirSync(dirname(file), { recursive: true });
        writeFileSync(file, '{"sa_products":[]}');
        mockQueue.getJob.mockResolvedValueOnce(completedJob(TENANT_ID));
        const res = fakeRes();
        await download(TENANT_ID, 'dl-1', res);
        await res.done;
        expect(res.body()).toBe('{"sa_products":[]}');
        expect(res.headers['Content-Length']).toBe('18');
        expect(res.headers['Content-Disposition']).toBe('attachment; filename="backup-2026-09-25.json"');
      });

      it('404s another tenant\'s job without touching its file', async () => {
        const OTHER = '33333333-3333-3333-3333-333333333333';
        mockQueue.getJob.mockResolvedValueOnce(completedJob(OTHER, 'dl-other'));
        await expect(download(TENANT_ID, 'dl-other', fakeRes())).rejects.toThrow(NotFoundException);
      });

      it('404s when the file has expired or the job is not finished', async () => {
        mockQueue.getJob.mockResolvedValueOnce(completedJob(TENANT_ID, 'dl-gone'));
        await expect(download(TENANT_ID, 'dl-gone', fakeRes())).rejects.toThrow(NotFoundException);

        mockQueue.getJob.mockResolvedValueOnce({
          ...completedJob(TENANT_ID, 'dl-1'),
          getState: vi.fn().mockResolvedValue('active'),
          returnvalue: null,
        });
        await expect(download(TENANT_ID, 'dl-1', fakeRes())).rejects.toThrow(NotFoundException);
      });

      it('rejects a token without deviceId', async () => {
        await expect(
          controller.downloadExport({ user: {} } as any, 'dl-1', fakeRes()),
        ).rejects.toThrow(DeviceRoleForbiddenException);
      });
    });
  });

  describe('export files', () => {
    it('refuses a path built from anything but a uuid tenant and a plain job id', () => {
      expect(() => exportFilePath('../etc', '1')).toThrow();
      expect(() => exportFilePath(TENANT_ID, '../../x')).toThrow();
      expect(exportFilePath(TENANT_ID, '42')).toBe(join(exportRoot, TENANT_ID, '42.json'));
    });

    it('prunes only files older than the TTL', async () => {
      const oldFile = exportFilePath(TENANT_ID, 'old');
      const newFile = exportFilePath(TENANT_ID, 'new');
      mkdirSync(dirname(oldFile), { recursive: true });
      writeFileSync(oldFile, '{}');
      writeFileSync(newFile, '{}');
      const past = (Date.now() - EXPORT_TTL_MS - 60_000) / 1000;
      utimesSync(oldFile, past, past);
      await pruneExportFiles();
      expect(existsSync(oldFile)).toBe(false);
      expect(existsSync(newFile)).toBe(true);
    });
  });
});
