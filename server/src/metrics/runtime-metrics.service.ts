import { Inject, Injectable, type OnModuleInit } from '@nestjs/common';
import { ModuleRef } from '@nestjs/core';
import { getQueueToken } from '@nestjs/bullmq';
import type { Queue } from 'bullmq';
import { DB_POOL_STATS, type DbPoolStatsReader } from '../infra/db.module.js';
import { ALL_QUEUES } from '../queue/queue.constants.js';
import { MetricsService, type QueueJobCounts } from './metrics.service.js';

// BullMQ connections run with `maxRetriesPerRequest: null` (queue.module.ts), so a command
// against an unreachable redis-queue never rejects — it waits. A scrape must not wait with it.
const QUEUE_READ_TIMEOUT_MS = 1000;

/**
 * Feeds `MetricsService` the two readings that need live infrastructure handles: the request
 * pool and the BullMQ queues. Kept out of `MetricsService` so that one stays constructible
 * with no dependencies, and out of `MetricsModule` so a graph that imports only that module
 * (`IdempotencyModule` does) does not have to provide the pool reader and six queues.
 */
@Injectable()
export class RuntimeMetricsService implements OnModuleInit {
  constructor(
    private readonly metrics: MetricsService,
    @Inject(DB_POOL_STATS) private readonly dbPoolStats: DbPoolStatsReader,
    private readonly moduleRef: ModuleRef,
  ) {}

  onModuleInit(): void {
    this.metrics.observeDbPool(this.dbPoolStats);

    const queues = ALL_QUEUES.map((name) =>
      this.moduleRef.get<Queue>(getQueueToken(name), { strict: false }),
    );
    this.metrics.observeQueues(() =>
      withTimeout(readQueues(queues), QUEUE_READ_TIMEOUT_MS),
    );
  }
}

async function readQueues(queues: Queue[]): Promise<QueueJobCounts> {
  const counts: QueueJobCounts = {};
  await Promise.all(
    queues.map(async (queue) => {
      counts[queue.name] = await queue.getJobCounts(
        'waiting',
        'active',
        'delayed',
        'failed',
      );
    }),
  );
  return counts;
}

function withTimeout<T>(work: Promise<T>, ms: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`queue read exceeded ${ms}ms`)),
      ms,
    );
    work.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (err: unknown) => {
        clearTimeout(timer);
        reject(err instanceof Error ? err : new Error(String(err)));
      },
    );
  });
}
