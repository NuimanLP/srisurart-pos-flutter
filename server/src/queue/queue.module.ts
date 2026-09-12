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
} from './queue.constants.js';
import { TenantJobRunner } from './tenant-job-runner.js';

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
      { name: QUEUE_DLQ },
    ),
  ],
  providers: [TenantJobRunner],
  exports: [BullModule, TenantJobRunner],
})
export class QueueModule {}
