import { Inject, Injectable, Optional } from '@nestjs/common';
import { InjectQueue, OnWorkerEvent, Processor, WorkerHost } from '@nestjs/bullmq';
import { type Job, Queue } from 'bullmq';
import type { Logger } from 'pino';
import { LOGGER } from '../../infra/logger.provider.js';
import { TenantImportService } from '../../platform/tenant-import.service.js';
import { JOB_TENANT_IMPORT, QUEUE_DLQ, QUEUE_TENANT_IMPORT, type TenantImportJobPayload } from '../queue.constants.js';

/**
 * #239: the worker side of the tenant import. `TenantImportService` does all the database
 * work on `ADMIN_DATA_SOURCE` (platform plane, ADR-0002/0005 — see that file's own
 * `tenant-door.spec.ts` allowlist entry); this processor owns only the BullMQ shape: mark
 * running, run it (success is recorded by the import's own transaction, not here), mark
 * failed, and — on the last attempt only — route to the DLQ, the same rule
 * `TenantJobRunner.routeToDlq` follows for every other job. It does not use
 * `TenantJobRunner` itself: that helper opens a `pos_app`/RLS transaction scoped to one
 * tenant (`SET LOCAL app.tenant_id`), and the import's whole point is writing historical rows
 * as the owner role, exactly as the synchronous endpoint always has.
 *
 * On its own queue (`QUEUE_TENANT_IMPORT`), not `QUEUE_BACKUP` — see that constant's comment:
 * two `@Processor` classes on one queue name would race for every job.
 */
@Injectable()
@Processor(QUEUE_TENANT_IMPORT)
export class TenantImportProcessor extends WorkerHost {
  constructor(
    private readonly importService: TenantImportService,
    @Inject(LOGGER) private readonly logger: Logger,
    @Optional() @InjectQueue(QUEUE_DLQ) private readonly dlqQueue?: Queue,
  ) {
    super();
  }

  async process(job: Job<TenantImportJobPayload>): Promise<unknown> {
    const { name, data } = job;
    if (name !== JOB_TENANT_IMPORT) {
      // This queue has exactly one producer (`TenantImportService.createJob`) and exactly
      // one job name — reaching here is a bug, not something to skip silently, but the
      // defensive shape matches every other processor in this codebase.
      return undefined;
    }

    this.logger.info(
      { jobId: job.id, importJobId: data.importJobId, tenantId: data.tenantId, correlationId: data.correlationId },
      'Processing tenant import job',
    );

    await this.importService.markRunning(data.importJobId);
    try {
      // `processJob` writes `status = 'succeeded'` itself, atomically with the import
      // transaction (#239 review, issue 2) — there is nothing left to mark here.
      const result = await this.importService.processJob(data.importJobId);
      this.logger.info({ importJobId: data.importJobId, tenantId: data.tenantId, result }, 'Tenant import completed successfully');
      return result;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const maxAttempts = job.opts.attempts ?? 1;
      const isFinalAttempt = job.attemptsMade + 1 >= maxAttempts;
      await this.importService.markFailed(data.importJobId, message, isFinalAttempt);
      if (isFinalAttempt) {
        await this.routeToDlq(job, err);
      }
      throw err;
    }
  }

  /**
   * #239 review, issue 1(b): a worker crash or a BullMQ-detected stall can end a job's *last*
   * attempt without `process()`'s own `catch` block above ever running — the process that was
   * running it is gone, so nothing there ever calls `markFailed`. BullMQ still fires this
   * event, on whichever worker is left (or the same one, restarted), once it gives up on the
   * job for good. `STALE_JOB_CEILING_MINUTES` (`tenant-import.service.ts`) is the eventual
   * fallback if even this never runs (e.g. no worker survives to receive it); this handler is
   * the fast path that avoids waiting on that ceiling at all.
   *
   * Ordinary attempt-exhaustion (the `catch` above ran and this fires anyway, since BullMQ
   * marks the job failed either way) calls `markFailed` a second time — idempotent, and
   * cheaper to allow than to gate on a status read here.
   */
  @OnWorkerEvent('failed')
  async onFailed(job: Job<TenantImportJobPayload> | undefined, error: Error): Promise<void> {
    if (!job || job.name !== JOB_TENANT_IMPORT) return;
    const maxAttempts = job.opts.attempts ?? 1;
    if (job.attemptsMade < maxAttempts) return; // more attempts remain — not final yet
    try {
      await this.importService.markFailed(job.data.importJobId, error?.message ?? 'worker stalled', true);
    } catch (markErr) {
      this.logger.error(
        { jobId: job.id, importJobId: job.data.importJobId, err: markErr },
        'failed to record a stalled tenant import job as failed',
      );
    }
  }

  /** Mirrors `TenantJobRunner.routeToDlq` — kept local rather than shared because that
   * helper's `runWithTenantContext` is the one door BullMQ processors normally go through
   * (`tenant-door.spec.ts`'s `SCOPE_DOORS`), and this processor deliberately does not. */
  private async routeToDlq(job: Job<TenantImportJobPayload>, err: unknown): Promise<void> {
    const errorMessage = err instanceof Error ? err.message : String(err);
    const errorStack = err instanceof Error ? err.stack : undefined;

    this.logger.error(
      {
        alert: 'DLQ_JOB_FAILED',
        jobId: job.id,
        queue: job.queueName,
        jobName: job.name,
        tenantId: job.data.tenantId,
        correlationId: job.data.correlationId,
        attemptsMade: job.attemptsMade + 1,
        error: errorMessage,
      },
      'BullMQ tenant import job exhausted all attempts; routing to DLQ and raising alert',
    );

    if (this.dlqQueue) {
      try {
        await this.dlqQueue.add(
          'dead-letter',
          {
            originalJobId: job.id,
            originalQueue: job.queueName,
            originalName: job.name,
            payload: job.data,
            failedReason: errorMessage,
            stacktrace: errorStack,
            failedAt: new Date().toISOString(),
            attemptsMade: job.attemptsMade + 1,
          },
          { removeOnComplete: false, removeOnFail: false },
        );
      } catch (dlqErr) {
        this.logger.error(
          { dlqError: dlqErr instanceof Error ? dlqErr.message : String(dlqErr) },
          'Failed to write to DLQ queue',
        );
      }
    }
  }
}
