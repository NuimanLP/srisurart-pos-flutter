import { Inject, Injectable, Optional } from '@nestjs/common';
import { InjectQueue } from '@nestjs/bullmq';
import { type Job, Queue } from 'bullmq';
import { DataSource, type EntityManager } from 'typeorm';
import type { Logger } from 'pino';
import { LOGGER } from '../infra/logger.provider.js';
import {
  assertWithinCommitCeiling,
  commitClockStart,
  TX_COMMIT_CEILING_MS,
} from '../common/database/commit-ceiling.js';
import { type BaseJobPayload, QUEUE_DLQ } from './queue.constants.js';

export interface JobExecutionResult<T> {
  skipped: boolean;
  reason?: 'TENANT_SUSPENDED' | 'TENANT_NOT_FOUND';
  result?: T;
}

@Injectable()
export class TenantJobRunner {
  /** The commit guard's ceiling (#213). A field only so a test can lower it. */
  commitCeilingMs = TX_COMMIT_CEILING_MS;

  constructor(
    private readonly dataSource: DataSource,
    @Inject(LOGGER) private readonly logger: Logger,
    @Optional() @InjectQueue(QUEUE_DLQ) private readonly dlqQueue?: Queue,
  ) {}

  /**
   * Executes a job handler within an isolated database transaction configured with
   * `SET LOCAL app.tenant_id = <tenantId>`.
   *
   * Guarantees:
   * 1. If tenant is suspended or not found, skips execution without touching business logic.
   * 2. If the handler throws, rolls back the transaction — preventing `app.tenant_id`
   *    from leaking to subsequent jobs on the connection pool.
   * 3. On final attempt failure, routes the job to the dead-letter queue (DLQ) and raises an alert.
   * 4. Refuses to commit a transaction older than `commitCeilingMs` (25 s, #213) — rolls back
   *    and fails the attempt — unless the caller passes `exemptFromCommitCeiling`. That
   *    opt-out is for a job that writes no row a client pulls by `updated_at`; today only
   *    the tenant export (`backup.processor.ts`, pinned by `tenant-job-runner.spec.ts`).
   */
  async runWithTenantContext<T>(
    job: Job<BaseJobPayload>,
    fn: (em: EntityManager) => Promise<T>,
    options: { exemptFromCommitCeiling?: true } = {},
  ): Promise<JobExecutionResult<T>> {
    const { tenantId, correlationId } = job.data;

    if (!tenantId) {
      this.logger.warn({ jobId: job.id, queue: job.queueName }, 'Job missing tenantId in payload');
      throw new Error(`Job ${job.id} on queue ${job.queueName} is missing required tenantId`);
    }

    // 1. Check tenant status before executing any transactional work (ADR-0003)
    const tenants: Array<{ status: string }> = await this.dataSource.query(
      'SELECT status FROM tenants WHERE id = $1',
      [tenantId],
    );

    if (tenants.length === 0) {
      this.logger.warn(
        { tenantId, correlationId, jobId: job.id, queue: job.queueName },
        'Job skipped: tenant not found',
      );
      return { skipped: true, reason: 'TENANT_NOT_FOUND' };
    }

    if (tenants[0].status === 'suspended') {
      this.logger.warn(
        { tenantId, correlationId, jobId: job.id, queue: job.queueName },
        'Job skipped: tenant is suspended (ADR-0003)',
      );
      return { skipped: true, reason: 'TENANT_SUSPENDED' };
    }

    // 2. Open dedicated QueryRunner and execute inside transaction with SET LOCAL
    const queryRunner = this.dataSource.createQueryRunner();

    try {
      // Inside the try, so a failed connect or BEGIN still releases the runner.
      await queryRunner.connect();
      const startedAt = commitClockStart();
      await queryRunner.startTransaction();

      await queryRunner.query('SELECT set_config($1, $2, true)', [
        'app.tenant_id',
        tenantId,
      ]);

      const result = await fn(queryRunner.manager);
      if (!options.exemptFromCommitCeiling) {
        assertWithinCommitCeiling(startedAt, this.commitCeilingMs);
      }
      await queryRunner.commitTransaction();

      return { skipped: false, result };
    } catch (err) {
      // Never let the rollback replace `err`: after Postgres ends an idle-in-transaction
      // session (#213) the runner is already released and `rollbackTransaction` throws,
      // which used to skip the DLQ routing below.
      try {
        if (queryRunner.isTransactionActive) await queryRunner.rollbackTransaction();
      } catch {
        /* the original error is the one worth reporting */
      }

      const maxAttempts = job.opts.attempts ?? 3;
      // attemptsMade starts at 0 on first execution, 1 on second, etc.
      if (job.attemptsMade + 1 >= maxAttempts) {
        await this.routeToDlq(job, err);
      }

      throw err;
    } finally {
      if (!queryRunner.isReleased) await queryRunner.release();
    }
  }

  private async routeToDlq(job: Job<BaseJobPayload>, err: unknown): Promise<void> {
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
      'BullMQ job exhausted all attempts; routing to DLQ and raising alert',
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
          {
            removeOnComplete: false,
            removeOnFail: false,
          },
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
