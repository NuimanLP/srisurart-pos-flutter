import { Inject, Injectable } from '@nestjs/common';
import { InjectQueue, Processor, WorkerHost } from '@nestjs/bullmq';
import type { Job, Queue } from 'bullmq';
import { DataSource } from 'typeorm';
import type { Logger } from 'pino';
import { LOGGER } from '../../infra/logger.provider.js';
import { IDEMPOTENCY_TTL_SECONDS } from '../../idempotency/idempotency.service.js';
import {
  JOB_IDEM_CLEANUP,
  JOB_QUOTES_PURGE,
  QUEUE_MAINTENANCE,
  type IdemCleanupJobPayload,
  type QuotesPurgeJobPayload,
} from '../queue.constants.js';
import { TenantJobRunner } from '../tenant-job-runner.js';
import { pruneExportFiles } from '../../backup/export-file.js';

@Injectable()
@Processor(QUEUE_MAINTENANCE)
export class MaintenanceProcessor extends WorkerHost {
  constructor(
    private readonly dataSource: DataSource,
    private readonly tenantJobRunner: TenantJobRunner,
    @Inject(LOGGER) private readonly logger: Logger,
    @InjectQueue(QUEUE_MAINTENANCE) private readonly maintenanceQueue: Queue,
  ) {
    super();
  }

  async process(job: Job<QuotesPurgeJobPayload | IdemCleanupJobPayload>): Promise<unknown> {
    const { name, data } = job;
    this.logger.info(
      { jobId: job.id, jobName: name, tenantId: data.tenantId, correlationId: data.correlationId },
      'Processing maintenance job',
    );

    if (name === JOB_IDEM_CLEANUP) {
      return this.handleIdemCleanup(job as Job<IdemCleanupJobPayload>);
    }

    if (name === JOB_QUOTES_PURGE) {
      return this.handleQuotesPurge(job as Job<QuotesPurgeJobPayload>);
    }

    this.logger.warn({ jobName: name }, 'Unknown job name in maintenance queue');
    return { skipped: true, reason: 'UNKNOWN_JOB_NAME' };
  }

  private async handleIdemCleanup(job: Job<IdemCleanupJobPayload>): Promise<unknown> {
    const ttlSeconds = job.data?.olderThanSeconds ?? IDEMPOTENCY_TTL_SECONDS;
    const tenantId = job.data?.tenantId;

    if (tenantId) {
      // Scoped cleanup for a specific tenant via TenantJobRunner
      return this.tenantJobRunner.runWithTenantContext(job, async (em) => {
        const result = await em.query(
          `DELETE FROM idempotency_keys
            WHERE tenant_id = $1::uuid
              AND created_at < now() - ($2::int * interval '1 second')
            RETURNING key`,
          [tenantId, ttlSeconds],
        );
        const deletedCount = extractDeletedCount(result);
        this.logger.info(
          { tenantId, ttlSeconds, deletedCount },
          'Expired idempotency keys cleaned up for tenant',
        );
        return { cleaned: true, deletedCount };
      });
    }

    // No tenant: fan out one tenant-scoped job per tenant (#169). The old branch ran the
    // DELETE on the pos_app pool with no app.tenant_id, and forced RLS on idempotency_keys
    // matched 0 rows while the job reported success. Fanning out keeps the delete under RLS
    // and reuses the runner's suspended-tenant skip, retries and DLQ; ADMIN_DATA_SOURCE
    // would bypass all three. `tenants` has no RLS, so listing it on the pool is safe.
    // Piggybacks on this hourly, tenant-less run: expired tenant-export files (backup.processor)
    // must go even when no shop ever exports again.
    const prunedExports = await pruneExportFiles();
    if (prunedExports > 0) {
      this.logger.info({ prunedExports }, 'Expired tenant export files pruned');
    }

    const tenants: Array<{ id: string }> = await this.dataSource.query(
      'SELECT id FROM tenants ORDER BY id',
    );
    const parent = job.id ?? 'adhoc';
    await this.maintenanceQueue.addBulk(
      tenants.map((t) => ({
        name: JOB_IDEM_CLEANUP,
        data: {
          tenantId: t.id,
          correlationId: job.data?.correlationId ?? `idem-cleanup-${parent}`,
          olderThanSeconds: ttlSeconds,
        },
        // A retried parent re-adds the same ids, which BullMQ ignores (no double fan-out).
        opts: { jobId: `idem-cleanup-${parent}-${t.id}` },
      })),
    );
    this.logger.info(
      { ttlSeconds, tenantCount: tenants.length },
      'Idempotency key cleanup fanned out to every tenant',
    );
    return { fannedOut: tenants.length };
  }

  private async handleQuotesPurge(job: Job<QuotesPurgeJobPayload>): Promise<unknown> {
    // Validated at the only producer (`parsePurgeOlderThanDays`) — trusted, never clamped.
    const olderThanDays = job.data.olderThanDays;

    return this.tenantJobRunner.runWithTenantContext(job, async (em) => {
      const result = await em.query(
        `DELETE FROM quotes
          WHERE tenant_id = $1::uuid
            AND (
              (status = 'converted' AND COALESCE(converted_at, date) < now() - ($2::int * interval '1 day'))
              OR
              (status != 'converted' AND valid_until < now() - ($2::int * interval '1 day'))
            )
          RETURNING id`,
        [job.data.tenantId, olderThanDays],
      );

      const deletedCount = extractDeletedCount(result);
      this.logger.info(
        { tenantId: job.data.tenantId, olderThanDays, deletedCount },
        'Old quotes purged successfully',
      );

      return { purged: true, deletedCount, olderThanDays };
    });
  }
}

/**
 * Normalizes deleted row count across TypeORM query result shapes:
 * - In TypeORM with Postgres: queryRunner.query returns `[ rows, count ]`.
 * - In raw pg or mocks: query returns `rows` array.
 */
function extractDeletedCount(result: unknown): number {
  if (Array.isArray(result)) {
    if (result.length === 2 && Array.isArray(result[0]) && typeof result[1] === 'number') {
      return result[1];
    }
    if (result.length > 0 && typeof result[0] === 'object' && !Array.isArray(result[0])) {
      return result.length;
    }
    if (result.length === 0) return 0;
  }
  return 0;
}
