import { beforeEach, describe, expect, it, vi } from 'vitest';
import { existsSync, mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { EXPORT_TTL_MS, exportFilePath } from '../src/backup/export-file.js';
import type { Job } from 'bullmq';
import { pino } from 'pino';
import { SalePostProcessor } from '../src/queue/processors/sale-post.processor.js';
import { InventoryProcessor } from '../src/queue/processors/inventory.processor.js';
import { MaintenanceProcessor } from '../src/queue/processors/maintenance.processor.js';
import {
  JOB_IDEM_CLEANUP,
  JOB_INVENTORY_CHECK,
  JOB_QUOTES_PURGE,
  JOB_RETURN_CREATED,
  JOB_SALE_CREATED,
  QUEUE_INVENTORY,
  QUEUE_MAINTENANCE,
  QUEUE_SALE_POST,
} from '../src/queue/queue.constants.js';

const logger = pino({ level: 'silent' });

describe('Worker Jobs Processors (unit)', () => {
  const TENANT_ID = '11111111-1111-1111-1111-111111111111';

  let mockEm: { query: ReturnType<typeof vi.fn> };
  let mockTenantJobRunner: { runWithTenantContext: ReturnType<typeof vi.fn> };

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
  });

  describe('SalePostProcessor', () => {
    let mockInventoryQueue: { add: ReturnType<typeof vi.fn> };
    let processor: SalePostProcessor;

    beforeEach(() => {
      mockInventoryQueue = {
        add: vi.fn().mockResolvedValue({ id: 'inv-job-1' }),
      };
      processor = new SalePostProcessor(
        mockTenantJobRunner as any,
        logger,
        mockInventoryQueue as any,
      );
    });

    it('processes sale.created and enqueues inventory.check if products reach min_stock', async () => {
      // Products with low stock
      mockEm.query.mockResolvedValueOnce([
        { id: 'prod-1', stock: 2, min_stock: 5 },
      ]);

      const job = {
        id: 'job-sale-1',
        name: JOB_SALE_CREATED,
        queueName: QUEUE_SALE_POST,
        data: {
          tenantId: TENANT_ID,
          correlationId: 'corr-1',
          saleId: 'sale-1',
          productIds: ['prod-1', 'prod-2'],
        },
      } as unknown as Job<any>;

      const res = (await processor.process(job)) as any;

      expect(res.skipped).toBe(false);
      expect(res.result).toEqual({
        processed: true,
        jobName: JOB_SALE_CREATED,
        itemCount: 2,
      });

      expect(mockInventoryQueue.add).toHaveBeenCalledTimes(1);
      expect(mockInventoryQueue.add).toHaveBeenCalledWith(
        JOB_INVENTORY_CHECK,
        {
          tenantId: TENANT_ID,
          correlationId: 'corr-1',
          productIds: ['prod-1'],
        },
        {
          jobId: `inv-check:${TENANT_ID}:prod-1`,
        },
      );
    });

    it('does not enqueue inventory.check if all products remain above min_stock', async () => {
      mockEm.query.mockResolvedValueOnce([]); // No low-stock products

      const job = {
        id: 'job-sale-2',
        name: JOB_SALE_CREATED,
        queueName: QUEUE_SALE_POST,
        data: {
          tenantId: TENANT_ID,
          correlationId: 'corr-2',
          saleId: 'sale-2',
          productIds: ['prod-3'],
        },
      } as unknown as Job<any>;

      const res = (await processor.process(job)) as any;

      expect(res.skipped).toBe(false);
      expect(res.result.processed).toBe(true);
      expect(mockInventoryQueue.add).not.toHaveBeenCalled();
    });

    it('AC1: idempotent execution — repeated calls yield identical outcome without side-effects', async () => {
      mockEm.query.mockResolvedValue([
        { id: 'prod-1', stock: 2, min_stock: 5 },
      ]);

      const job = {
        id: 'job-sale-idem',
        name: JOB_SALE_CREATED,
        queueName: QUEUE_SALE_POST,
        data: {
          tenantId: TENANT_ID,
          correlationId: 'corr-idem',
          saleId: 'sale-idem',
          productIds: ['prod-1'],
        },
      } as unknown as Job<any>;

      const run1 = (await processor.process(job)) as any;
      const run2 = (await processor.process(job)) as any;

      expect(run1).toEqual(run2);
      // Both runs generate identical deduplication jobId
      expect(mockInventoryQueue.add).toHaveBeenNthCalledWith(
        1,
        JOB_INVENTORY_CHECK,
        expect.anything(),
        { jobId: `inv-check:${TENANT_ID}:prod-1` },
      );
      expect(mockInventoryQueue.add).toHaveBeenNthCalledWith(
        2,
        JOB_INVENTORY_CHECK,
        expect.anything(),
        { jobId: `inv-check:${TENANT_ID}:prod-1` },
      );
    });

    it('handles return.created similarly', async () => {
      mockEm.query.mockResolvedValueOnce([]);

      const job = {
        id: 'job-ret-1',
        name: JOB_RETURN_CREATED,
        queueName: QUEUE_SALE_POST,
        data: {
          tenantId: TENANT_ID,
          correlationId: 'corr-ret',
          returnId: 'ret-1',
          productIds: ['prod-1'],
        },
      } as unknown as Job<any>;

      const res = (await processor.process(job)) as any;
      expect(res.result.processed).toBe(true);
      expect(res.result.jobName).toBe(JOB_RETURN_CREATED);
    });

    it('skips unknown job names', async () => {
      const job = {
        id: 'job-unknown',
        name: 'unknown.job',
        queueName: QUEUE_SALE_POST,
        data: { tenantId: TENANT_ID, correlationId: 'corr-x' },
      } as unknown as Job<any>;

      const res = (await processor.process(job)) as any;
      expect(res.result.skipped).toBe(true);
      expect(res.result.reason).toBe('UNKNOWN_JOB_NAME');
    });
  });

  describe('InventoryProcessor', () => {
    let processor: InventoryProcessor;

    beforeEach(() => {
      processor = new InventoryProcessor(mockTenantJobRunner as any, logger);
    });

    it('AC1: processes inventory.check and returns evaluated items idempotently', async () => {
      const lowStockRows = [
        { id: 'p1', part_no: 'P001', name: 'Brake Pad', stock: 1, min_stock: 5 },
      ];
      mockEm.query.mockResolvedValue(lowStockRows);

      const job = {
        id: 'job-inv-1',
        name: JOB_INVENTORY_CHECK,
        queueName: QUEUE_INVENTORY,
        data: {
          tenantId: TENANT_ID,
          correlationId: 'corr-inv-1',
          productIds: ['p1'],
        },
      } as unknown as Job<any>;

      const run1 = (await processor.process(job)) as any;
      const run2 = (await processor.process(job)) as any;

      expect(run1).toEqual(run2);
      expect(run1.result).toEqual({
        evaluated: true,
        lowStockCount: 1,
        items: [{ id: 'p1', stock: 1, minStock: 5 }],
      });
    });

    it('skips unknown job names', async () => {
      const job = {
        id: 'job-unknown',
        name: 'unknown.job',
        queueName: QUEUE_INVENTORY,
        data: { tenantId: TENANT_ID, correlationId: 'corr-x' },
      } as unknown as Job<any>;

      const res = (await processor.process(job)) as any;
      expect(res.result.skipped).toBe(true);
      expect(res.result.reason).toBe('UNKNOWN_JOB_NAME');
    });
  });

  describe('MaintenanceProcessor', () => {
    let mockDataSource: { query: ReturnType<typeof vi.fn> };
    let mockMaintenanceQueue: { addBulk: ReturnType<typeof vi.fn> };
    let processor: MaintenanceProcessor;

    beforeEach(() => {
      mockDataSource = {
        query: vi.fn(),
      };
      mockMaintenanceQueue = { addBulk: vi.fn() };
      processor = new MaintenanceProcessor(
        mockDataSource as any,
        mockTenantJobRunner as any,
        logger,
        mockMaintenanceQueue as any,
      );
    });

    describe('AC4: idem.cleanup', () => {
      it('cleans up expired idempotency keys for a specific tenant', async () => {
        mockEm.query.mockResolvedValueOnce([{ key: 'key-1' }, { key: 'key-2' }]);

        const job = {
          id: 'job-idem-tenant',
          name: JOB_IDEM_CLEANUP,
          queueName: QUEUE_MAINTENANCE,
          data: {
            tenantId: TENANT_ID,
            correlationId: 'corr-maint-1',
            olderThanSeconds: 86400,
          },
        } as unknown as Job<any>;

        const res = (await processor.process(job)) as any;

        expect(res.skipped).toBe(false);
        expect(res.result).toEqual({ cleaned: true, deletedCount: 2 });
        expect(mockEm.query).toHaveBeenCalledWith(
          expect.stringContaining('DELETE FROM idempotency_keys'),
          [TENANT_ID, 86400],
        );
      });

      it('with no tenantId, fans out one tenant-scoped job per tenant and deletes nothing itself (#169)', async () => {
        const OTHER = '22222222-2222-2222-2222-222222222222';
        mockDataSource.query.mockResolvedValueOnce([{ id: TENANT_ID }, { id: OTHER }]);

        const job = {
          id: 'job-idem-global',
          name: JOB_IDEM_CLEANUP,
          queueName: QUEUE_MAINTENANCE,
          data: {
            correlationId: 'corr-global',
            olderThanSeconds: 86400,
          },
        } as unknown as Job<any>;

        const res = (await processor.process(job)) as any;

        expect(res).toEqual({ fannedOut: 2 });
        expect(mockDataSource.query).toHaveBeenCalledTimes(1);
        expect(mockDataSource.query).not.toHaveBeenCalledWith(
          expect.stringContaining('DELETE'),
          expect.anything(),
        );
        expect(mockTenantJobRunner.runWithTenantContext).not.toHaveBeenCalled();
        expect(mockMaintenanceQueue.addBulk).toHaveBeenCalledWith([
          {
            name: JOB_IDEM_CLEANUP,
            data: { tenantId: TENANT_ID, correlationId: 'corr-global', olderThanSeconds: 86400 },
            opts: { jobId: `idem-cleanup-job-idem-global-${TENANT_ID}` },
          },
          {
            name: JOB_IDEM_CLEANUP,
            data: { tenantId: OTHER, correlationId: 'corr-global', olderThanSeconds: 86400 },
            opts: { jobId: `idem-cleanup-job-idem-global-${OTHER}` },
          },
        ]);
      });
    });

    it('the hourly tenant-less run also prunes expired tenant-export files (PDPA)', async () => {
      const root = mkdtempSync(join(tmpdir(), 'worker-jobs-exports-'));
      const prev = process.env.EXPORT_DIR;
      process.env.EXPORT_DIR = root;
      try {
        const file = exportFilePath(TENANT_ID, 'stale');
        mkdirSync(dirname(file), { recursive: true });
        writeFileSync(file, '{}');
        const past = (Date.now() - EXPORT_TTL_MS - 60_000) / 1000;
        utimesSync(file, past, past);
        mockDataSource.query.mockResolvedValueOnce([]);

        await processor.process({
          id: 'job-idem-global',
          name: JOB_IDEM_CLEANUP,
          queueName: QUEUE_MAINTENANCE,
          data: { correlationId: 'corr-global' },
        } as unknown as Job<any>);

        expect(existsSync(file)).toBe(false);
      } finally {
        if (prev === undefined) delete process.env.EXPORT_DIR;
        else process.env.EXPORT_DIR = prev;
        rmSync(root, { recursive: true, force: true });
      }
    });

    describe('AC5: quotes.purge', () => {
      it('purges quotes older than olderThanDays', async () => {
        mockEm.query.mockResolvedValueOnce([{ id: 'q1' }, { id: 'q2' }, { id: 'q3' }]);

        const job = {
          id: 'job-quotes-purge',
          name: JOB_QUOTES_PURGE,
          queueName: QUEUE_MAINTENANCE,
          data: {
            tenantId: TENANT_ID,
            correlationId: 'corr-purge',
            olderThanDays: 60,
          },
        } as unknown as Job<any>;

        const res = (await processor.process(job)) as any;

        expect(res.skipped).toBe(false);
        expect(res.result).toEqual({
          purged: true,
          deletedCount: 3,
          olderThanDays: 60,
        });
        expect(mockEm.query).toHaveBeenCalledWith(
          expect.stringContaining('DELETE FROM quotes'),
          [TENANT_ID, 60],
        );
      });

      it('AC1: idempotent execution — second call purges 0 additional quotes without error', async () => {
        mockEm.query
          .mockResolvedValueOnce([{ id: 'q1' }]) // run 1 deletes 1
          .mockResolvedValueOnce([]); // run 2 deletes 0

        const job = {
          id: 'job-quotes-purge-idem',
          name: JOB_QUOTES_PURGE,
          queueName: QUEUE_MAINTENANCE,
          data: {
            tenantId: TENANT_ID,
            correlationId: 'corr-purge-idem',
            olderThanDays: 90,
          },
        } as unknown as Job<any>;

        const res1 = (await processor.process(job)) as any;
        const res2 = (await processor.process(job)) as any;

        expect(res1.result).toEqual({ purged: true, deletedCount: 1, olderThanDays: 90 });
        expect(res2.result).toEqual({ purged: true, deletedCount: 0, olderThanDays: 90 });
      });
    });

    it('skips unknown job names', async () => {
      const job = {
        id: 'job-unknown',
        name: 'unknown.job',
        queueName: QUEUE_MAINTENANCE,
        data: { tenantId: TENANT_ID, correlationId: 'corr-x' },
      } as unknown as Job<any>;

      const res = (await processor.process(job)) as any;
      expect(res).toEqual({ skipped: true, reason: 'UNKNOWN_JOB_NAME' });
    });
  });
});
