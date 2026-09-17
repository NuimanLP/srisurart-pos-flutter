import { describe, expect, it, vi } from 'vitest';
import type { Job } from 'bullmq';
import { TenantImportProcessor } from './tenant-import.processor.js';
import { JOB_TENANT_IMPORT, type TenantImportJobPayload } from '../queue.constants.js';

// #239 review issue 1(b): a worker crash or a BullMQ-detected stall can end a job's *last*
// attempt with `process()`'s own try/catch never running (the process running it is gone).
// `@OnWorkerEvent('failed')` is BullMQ's own notification that a job is done retrying —
// this proves `onFailed` calls `markFailed(…, final: true)` only once attempts are exhausted,
// and does nothing on attempts that still have retries left or that belong to another queue.
describe('TenantImportProcessor.onFailed (#239 issue 1b)', () => {
  const makeJob = (overrides: Partial<Job<TenantImportJobPayload>> = {}): Job<TenantImportJobPayload> =>
    ({
      id: 'bull-1',
      name: JOB_TENANT_IMPORT,
      data: { tenantId: 't1', correlationId: 'corr-1', importJobId: 'imp_1' },
      attemptsMade: 3,
      opts: { attempts: 3 },
      queueName: 'tenant-import',
      ...overrides,
    }) as unknown as Job<TenantImportJobPayload>;

  const makeProcessor = () => {
    const importService = { markFailed: vi.fn().mockResolvedValue(undefined) };
    const logger = { info: vi.fn(), error: vi.fn(), warn: vi.fn() };
    const processor = new TenantImportProcessor(importService as any, logger as any, undefined);
    return { processor, importService, logger };
  };

  it('marks the job failed (final) once attemptsMade reaches the configured attempts', async () => {
    const { processor, importService } = makeProcessor();
    const job = makeJob({ attemptsMade: 3, opts: { attempts: 3 } });

    await processor.onFailed(job, new Error('worker stalled'));

    expect(importService.markFailed).toHaveBeenCalledWith('imp_1', 'worker stalled', true);
  });

  it('does nothing while attempts remain', async () => {
    const { processor, importService } = makeProcessor();
    const job = makeJob({ attemptsMade: 1, opts: { attempts: 3 } });

    await processor.onFailed(job, new Error('transient'));

    expect(importService.markFailed).not.toHaveBeenCalled();
  });

  it('defaults to 1 attempt when the job carries none, so a single failure is final', async () => {
    const { processor, importService } = makeProcessor();
    const job = makeJob({ attemptsMade: 1, opts: {} });

    await processor.onFailed(job, new Error('no retries configured'));

    expect(importService.markFailed).toHaveBeenCalledWith('imp_1', 'no retries configured', true);
  });

  it('ignores a job with no data (BullMQ can call worker events with an undefined job)', async () => {
    const { processor, importService } = makeProcessor();

    await processor.onFailed(undefined, new Error('x'));

    expect(importService.markFailed).not.toHaveBeenCalled();
  });

  it('ignores a job from another queue/name sharing this worker class', async () => {
    const { processor, importService } = makeProcessor();
    const job = makeJob({ name: 'some.other.job', attemptsMade: 3, opts: { attempts: 3 } });

    await processor.onFailed(job, new Error('x'));

    expect(importService.markFailed).not.toHaveBeenCalled();
  });

  it('logs but does not throw when markFailed itself rejects', async () => {
    const { processor, importService, logger } = makeProcessor();
    importService.markFailed.mockRejectedValueOnce(new Error('db down'));
    const job = makeJob({ attemptsMade: 3, opts: { attempts: 3 } });

    await expect(processor.onFailed(job, new Error('worker stalled'))).resolves.toBeUndefined();
    expect(logger.error).toHaveBeenCalled();
  });
});
