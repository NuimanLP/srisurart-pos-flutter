import { Inject, Injectable, type OnApplicationBootstrap } from '@nestjs/common';
import { InjectQueue } from '@nestjs/bullmq';
import type { Queue } from 'bullmq';
import type { Logger } from 'pino';
import { LOGGER } from '../infra/logger.provider.js';
import {
  IDEM_CLEANUP_INTERVAL_MS,
  IDEM_CLEANUP_SCHEDULER_ID,
  JOB_IDEM_CLEANUP,
  QUEUE_MAINTENANCE,
} from './queue.constants.js';

/**
 * Registers the repeatable `idem.cleanup` job (#182 / #169's follow-up). With no scheduler,
 * expired `idempotency_keys` rows — including #163's plaintext device-enrolment codes — were
 * only ever removed by someone enqueuing the job by hand.
 *
 * `Queue.upsertJobScheduler(id, …)` is keyed by `id`: calling it again (a restart, or a future
 * second worker replica) updates the same schedule rather than adding a duplicate one, which is
 * what makes this safe to run from `onApplicationBootstrap` with no extra bookkeeping. Against
 * real Redis/BullMQ 6.3.4, `every` with no prior run schedules the first job immediately (not
 * epoch-aligned an hour out) — the recurring cadence is what the review confirmed at an hour
 * apart from there.
 *
 * Lives in its own `QueueSchedulerModule`, imported only by `WorkerModule` — **not**
 * `QueueProcessorsModule`. Several e2e suites mount `QueueProcessorsModule` to exercise one
 * processor directly (`test/backup.e2e-spec.ts`, `test/worker-jobs.e2e-spec.ts`) and must not
 * also register (and fan out) the global schedule just by booting. `docker-compose.yml` runs one
 * worker replica against three API replicas (`AppModule` imports `QueueModule` to enqueue jobs,
 * never `QueueProcessorsModule` or this module), so the registration itself also runs once per
 * deploy, not three times; `upsertJobScheduler`'s id-based idempotency is the belt to that
 * suspenders.
 */
@Injectable()
export class JobSchedulerService implements OnApplicationBootstrap {
  constructor(
    @InjectQueue(QUEUE_MAINTENANCE) private readonly maintenanceQueue: Queue,
    @Inject(LOGGER) private readonly logger: Logger,
  ) {}

  async onApplicationBootstrap(): Promise<void> {
    // No `data` in the template: `MaintenanceProcessor.handleIdemCleanup` already falls back to
    // `idem-cleanup-${job.id}` for `correlationId` and the default TTL for `olderThanSeconds`
    // when a job carries neither, so a static correlationId here would just make every hourly
    // run log the same one.
    await this.maintenanceQueue.upsertJobScheduler(
      IDEM_CLEANUP_SCHEDULER_ID,
      { every: IDEM_CLEANUP_INTERVAL_MS },
      { name: JOB_IDEM_CLEANUP },
    );
    this.logger.info(
      { schedulerId: IDEM_CLEANUP_SCHEDULER_ID, everyMs: IDEM_CLEANUP_INTERVAL_MS },
      'idem.cleanup job scheduler registered',
    );
  }
}
