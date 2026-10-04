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
    // Single flight: `withTimeout` only stops the scrape waiting — the commands stay queued
    // in ioredis while redis-queue is down. Issuing fresh ones every scrape would pile them up
    // and burst them all onto Redis when it returns, so a scrape that finds a read still
    // pending joins it (and times out with it) instead of starting another.
    let inFlight: Promise<QueueJobCounts> | undefined;
    this.metrics.observeQueues(() => {
      inFlight ??= readQueues(queues, () => {
        inFlight = undefined;
      });
      return withTimeout(inFlight, QUEUE_READ_TIMEOUT_MS);
    });
  }
}

/** `onSettled` fires once every queue's command has settled — not at the first rejection. */
function readQueues(queues: Queue[], onSettled: () => void): Promise<QueueJobCounts> {
  const reads = queues.map((queue) =>
    queue.getJobCounts('waiting', 'active', 'delayed', 'failed'),
  );
  void Promise.allSettled(reads).then(onSettled);
  return Promise.all(reads).then((results) => {
    const counts: QueueJobCounts = {};
    queues.forEach((queue, i) => {
      counts[queue.name] = results[i];
    });
    return counts;
  });
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
