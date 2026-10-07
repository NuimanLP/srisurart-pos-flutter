import { Inject, Injectable } from '@nestjs/common';
import { Processor, WorkerHost } from '@nestjs/bullmq';
import type { Job } from 'bullmq';
import type { Logger } from 'pino';
import { EntityManager } from 'typeorm';
import { buildTenantSnapshot } from '../../backup/tenant-snapshot.js';
import { LOGGER } from '../../infra/logger.provider.js';
import { AuditService } from '../../audit/audit.service.js';
import {
  JOB_TENANT_EXPORT,
  QUEUE_BACKUP,
  type TenantExportJobPayload,
} from '../queue.constants.js';
import { TenantJobRunner } from '../tenant-job-runner.js';
import {
  exportFilePath,
  pruneExportFiles,
  writeExportFile,
  type ExportDescriptor,
} from '../../backup/export-file.js';

@Injectable()
@Processor(QUEUE_BACKUP)
export class BackupProcessor extends WorkerHost {
  constructor(
    private readonly tenantJobRunner: TenantJobRunner,
    private readonly auditService: AuditService,
    @Inject(LOGGER) private readonly logger: Logger,
  ) {
    super();
  }

  async process(job: Job<TenantExportJobPayload>): Promise<unknown> {
    const { name, data } = job;
    this.logger.info(
      { jobId: job.id, jobName: name, tenantId: data.tenantId, correlationId: data.correlationId },
      'Processing backup job',
    );

    if (name !== JOB_TENANT_EXPORT) {
      this.logger.warn({ jobName: name, jobId: job.id }, 'Unknown job name in backup queue');
      return { skipped: true, reason: 'UNKNOWN_JOB' };
    }

    // Files outlive their job only by up to one TTL: every export sweeps the expired ones.
    await pruneExportFiles();

    return this.tenantJobRunner.runWithTenantContext(job, async (em: EntityManager): Promise<ExportDescriptor> => {
      const tenantId = data.tenantId;

      // The one `pos_app` transaction whose statements scale with a tenant's whole history
      // (every sale, every movement, unpaged), so it is exempt from the role's timeouts and
      // the commit guard (#213) and capped at 5 min instead — it used to be unbounded. Safe
      // for ADR-0010's 30 s cursor rewind only because it writes no row a client pulls: its
      // one write is `audit_log`. `SET LOCAL` ends with this transaction, so the pooled
      // connection goes back with the role's settings. README *The transaction ceiling*.
      await em.query(`SET LOCAL statement_timeout = '5min'`);
      await em.query(`SET LOCAL idle_in_transaction_session_timeout = '5min'`);

      const { snapshot, recordCounts, exportedAt } = await buildTenantSnapshot(em, tenantId);

      // 17. The snapshot goes to a file, never into the job's `returnvalue`: that would park a
      // whole shop's history in `redis-queue` (192 MB, noeviction) for the job's lifetime.
      // Written before the audit row so a failed write fails the job without an audit entry.
      const { sizeBytes, sha256 } = await writeExportFile(
        exportFilePath(tenantId, String(job.id)),
        snapshot,
      );

      // 18. AC3: Write audit_log entry
      await this.auditService.log(em, {
        tenantId,
        userId: data.requestedByUserId || undefined,
        action: 'backup.exported',
        entity: 'tenants',
        entityId: tenantId,
        ip: data.ip,
        after: {
          recordCounts,
          exportedAt,
        },
      });

      this.logger.info(
        { tenantId, recordCounts, sizeBytes },
        'Tenant data export completed successfully',
      );

      return { sizeBytes, sha256, exportedAt, recordCounts };
    }, { exemptFromCommitCeiling: true });
  }
}
