import { describe, expect, it, vi } from 'vitest';
import { pino } from 'pino';
import { JobSchedulerService } from '../src/queue/job-scheduler.service.js';
import {
  IDEM_CLEANUP_INTERVAL_MS,
  IDEM_CLEANUP_SCHEDULER_ID,
  JOB_IDEM_CLEANUP,
} from '../src/queue/queue.constants.js';

const logger = pino({ level: 'silent' });

describe('JobSchedulerService (#182, unit)', () => {
  it('registers idem.cleanup under a stable scheduler id, and a second bootstrap (a restart, or another worker replica) upserts the same id rather than adding a second one', async () => {
    const mockQueue = { upsertJobScheduler: vi.fn().mockResolvedValue({ id: 'next-job' }) };
    const service = new JobSchedulerService(mockQueue as any, logger);

    await service.onApplicationBootstrap();
    await service.onApplicationBootstrap();

    expect(mockQueue.upsertJobScheduler).toHaveBeenCalledTimes(2);
    expect(mockQueue.upsertJobScheduler).toHaveBeenNthCalledWith(
      1,
      IDEM_CLEANUP_SCHEDULER_ID,
      { every: IDEM_CLEANUP_INTERVAL_MS },
      { name: JOB_IDEM_CLEANUP },
    );
    expect(mockQueue.upsertJobScheduler).toHaveBeenNthCalledWith(
      2,
      IDEM_CLEANUP_SCHEDULER_ID,
      { every: IDEM_CLEANUP_INTERVAL_MS },
      { name: JOB_IDEM_CLEANUP },
    );
  });
});
