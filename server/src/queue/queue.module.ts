import { Global, Module } from '@nestjs/common';
import { BullModule } from '@nestjs/bullmq';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import {
  DEFAULT_JOB_OPTIONS,
  QUEUE_BACKUP,
  QUEUE_DLQ,
  QUEUE_INVENTORY,
  QUEUE_MAINTENANCE,
  QUEUE_SALE_POST,
  QUEUE_TENANT_IMPORT,
} from './queue.constants.js';
import { TenantJobRunner } from './tenant-job-runner.js';
import { SalePostProcessor } from './processors/sale-post.processor.js';
import { InventoryProcessor } from './processors/inventory.processor.js';
import { MaintenanceProcessor } from './processors/maintenance.processor.js';
import { BackupProcessor } from './processors/backup.processor.js';
import { TenantImportProcessor } from './processors/tenant-import.processor.js';
import { AuditModule } from '../audit/audit.module.js';
import { TenantImportModule } from '../platform/tenant-import.module.js';
import { JobSchedulerService } from './job-scheduler.service.js';

@Global()
@Module({
  imports: [
    BullModule.forRootAsync({
      inject: [APP_CONFIG],
      useFactory: (cfg: AppConfig) => {
        const url = new URL(cfg.redisQueueUrl);
        return {
          connection: {
            host: url.hostname,
            port: Number(url.port || 6379),
            password: url.password || undefined,
            username: url.username || undefined,
            // BullMQ requires maxRetriesPerRequest to be null for workers/queues
            maxRetriesPerRequest: null,
            enableReadyCheck: false,
          },
          defaultJobOptions: DEFAULT_JOB_OPTIONS,
        };
      },
    }),
    BullModule.registerQueue(
      { name: QUEUE_SALE_POST },
      { name: QUEUE_INVENTORY },
      { name: QUEUE_MAINTENANCE },
      { name: QUEUE_BACKUP },
      { name: QUEUE_TENANT_IMPORT },
      { name: QUEUE_DLQ },
    ),
  ],
  providers: [TenantJobRunner],
  exports: [BullModule, TenantJobRunner],
})
export class QueueModule {}

@Module({
  imports: [QueueModule, AuditModule, TenantImportModule],
  providers: [
    SalePostProcessor,
    InventoryProcessor,
    MaintenanceProcessor,
    BackupProcessor,
    TenantImportProcessor,
  ],
  exports: [
    SalePostProcessor,
    InventoryProcessor,
    MaintenanceProcessor,
    BackupProcessor,
    TenantImportProcessor,
  ],
})
export class QueueProcessorsModule {}

/**
 * Separate from `QueueProcessorsModule` on purpose: several e2e suites mount
 * `QueueProcessorsModule` to exercise a processor directly (`test/backup.e2e-spec.ts`,
 * `test/worker-jobs.e2e-spec.ts`) without wanting the global `idem.cleanup` schedule
 * registered — and fanning that out over every dev tenant on every such boot is exactly the
 * shared-state leak #182's review caught. Only `WorkerModule` imports this module.
 */
@Module({
  imports: [QueueModule],
  providers: [JobSchedulerService],
  exports: [JobSchedulerService],
})
export class QueueSchedulerModule {}
