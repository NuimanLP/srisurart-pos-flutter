import {
  Controller,
  Get,
  HttpException,
  HttpStatus,
  Inject,
} from '@nestjs/common';
import type { Redis } from 'ioredis';
import { DataSource } from 'typeorm';
import { REDIS_CACHE, REDIS_QUEUE } from '../infra/redis.module.js';

type Check = 'up' | 'down';
const CHECK_TIMEOUT_MS = 2000;

async function probe(run: () => Promise<unknown>): Promise<Check> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error('timeout')), CHECK_TIMEOUT_MS);
  });
  try {
    await Promise.race([run(), timeout]);
    return 'up';
  } catch {
    return 'down';
  } finally {
    clearTimeout(timer);
  }
}

@Controller('health')
export class HealthController {
  constructor(
    private readonly ds: DataSource,
    @Inject(REDIS_CACHE) private readonly cache: Redis,
    @Inject(REDIS_QUEUE) private readonly queue: Redis,
  ) {}

  /** Liveness: touches nothing. A DB outage must not restart every instance. */
  @Get('live')
  live() {
    return { status: 'up' };
  }

  /** Readiness: Postgres + both Redis. 503 NOT_READY if any is down. */
  @Get('ready')
  async ready() {
    const [postgres, redisCache, redisQueue] = await Promise.all([
      probe(() => this.ds.query('SELECT 1')),
      probe(() => this.cache.ping()),
      probe(() => this.queue.ping()),
    ]);
    const checks = { postgres, redisCache, redisQueue };
    if (Object.values(checks).some((c) => c === 'down')) {
      throw new HttpException(
        {
          code: 'NOT_READY',
          message: 'Dependency unavailable',
          details: checks,
        },
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }
    return { status: 'up', checks };
  }
}
