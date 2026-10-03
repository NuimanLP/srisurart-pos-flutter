import { Inject, Injectable } from '@nestjs/common';
import type { Redis } from 'ioredis';
import { DataSource } from 'typeorm';
import { HEALTH_DATA_SOURCE } from '../infra/db.module.js';
import { REDIS_CACHE, REDIS_QUEUE } from '../infra/redis.module.js';

export type Check = 'up' | 'down';
export interface ReadinessChecks {
  postgres: Check;
  redisCache: Check;
  redisQueue: Check;
}
const CHECK_TIMEOUT_MS = 2000;

/** Rejects with `timeout` after `ms`; the timer never outlives the race. */
export function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error('timeout')), ms);
  });
  return Promise.race([p, timeout]).finally(() => clearTimeout(timer));
}

async function probe(run: () => Promise<unknown>): Promise<Check> {
  try {
    await withTimeout(run(), CHECK_TIMEOUT_MS);
    return 'up';
  } catch {
    return 'down';
  }
}

/**
 * The `/health/ready` dependency checks, in one place so the platform system panel
 * (`GET /platform/system`) reports exactly what the readiness gate sees instead of a copy.
 */
@Injectable()
export class HealthService {
  constructor(
    // Its own pool of one, never the request pool (#248): a saturated request pool is a
    // busy instance, not a dead database.
    @Inject(HEALTH_DATA_SOURCE) private readonly ds: DataSource,
    @Inject(REDIS_CACHE) private readonly cache: Redis,
    @Inject(REDIS_QUEUE) private readonly queue: Redis,
  ) {}

  /** Postgres + both Redis, each bounded by 2 s. Never throws. */
  async readiness(): Promise<ReadinessChecks> {
    const [postgres, redisCache, redisQueue] = await Promise.all([
      probe(() => this.ds.query('SELECT 1')),
      probe(() => this.cache.ping()),
      probe(() => this.queue.ping()),
    ]);
    return { postgres, redisCache, redisQueue };
  }
}
