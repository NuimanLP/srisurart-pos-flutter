import { Global, Inject, Module } from '@nestjs/common';
import { Redis } from 'ioredis';
import type { Logger } from 'pino';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { LOGGER } from './logger.provider.js';

/** `redis-cache` (allkeys-lru): cache, rate-limit counters, tenant status. */
export const REDIS_CACHE = Symbol('REDIS_CACHE');
/** `redis-queue` (noeviction + AOF): BullMQ only. Never cache here. */
export const REDIS_QUEUE = Symbol('REDIS_QUEUE');

function connect(url: string, name: string, logger: Logger): Redis {
  const client = new Redis(url, {
    // Fail fast while disconnected instead of queueing commands: a cache or
    // readiness call must not hang behind a dead Redis.
    enableOfflineQueue: false,
    maxRetriesPerRequest: 1,
  });
  // ioredis throws on an unhandled error event; log and keep reconnecting.
  client.on('error', (err) =>
    logger.warn({ redis: name, err: err.message }, 'redis error'),
  );
  return client;
}

@Global()
@Module({
  providers: [
    {
      provide: REDIS_CACHE,
      inject: [APP_CONFIG, LOGGER],
      useFactory: (cfg: AppConfig, logger: Logger) =>
        connect(cfg.redisCacheUrl, 'cache', logger),
    },
    {
      provide: REDIS_QUEUE,
      inject: [APP_CONFIG, LOGGER],
      useFactory: (cfg: AppConfig, logger: Logger) =>
        connect(cfg.redisQueueUrl, 'queue', logger),
    },
  ],
  exports: [REDIS_CACHE, REDIS_QUEUE],
})
export class RedisModule {
  constructor(
    @Inject(REDIS_CACHE) private readonly cache: Redis,
    @Inject(REDIS_QUEUE) private readonly queue: Redis,
  ) {}
  async onModuleDestroy() {
    await Promise.allSettled([this.cache.quit(), this.queue.quit()]);
  }
}
