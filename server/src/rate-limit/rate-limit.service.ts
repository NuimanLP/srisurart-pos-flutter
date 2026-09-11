import { Inject, Injectable, Logger } from '@nestjs/common';
import type { Redis } from 'ioredis';
import { DataSource } from 'typeorm';
import { REDIS_CACHE } from '../infra/redis.module.js';

export interface RateLimitCheckResult {
  allowed: boolean;
  retryAfter?: number;
}

const DEFAULT_LIMIT = 120;
const DEFAULT_WINDOW_SEC = 60;
const PLAN_CACHE_TTL_SEC = 300;

// Lua script to atomically increment and set expire if key is new
const RATE_LIMIT_LUA = `
local current = redis.call('INCR', KEYS[1])
if current == 1 then
  redis.call('EXPIRE', KEYS[1], ARGV[1])
end
local ttl = redis.call('TTL', KEYS[1])
return { current, ttl }
`;

@Injectable()
export class RateLimitService {
  private readonly logger = new Logger(RateLimitService.name);

  constructor(
    @Inject(REDIS_CACHE) private readonly redis: Redis,
    private readonly ds: DataSource,
  ) {}

  /**
   * Checks whether a request for a specific tenant and route is within quota.
   * ADR-0006: Fails open if Redis or DB is unavailable (POS cannot stop selling).
   */
  async checkRateLimit(
    tenantId: string,
    routeKey: string,
    options?: { limit?: number; windowSec?: number },
  ): Promise<RateLimitCheckResult> {
    if (!tenantId) {
      return { allowed: true };
    }

    try {
      // 1. Resolve tenant plan (cached in Redis t:{tid}:plan)
      const plan = await this.getTenantPlan(tenantId);

      // ADR-0006: 'loadtest' plan is unlimited so k6 measures the system rather than limiter
      if (plan === 'loadtest') {
        return { allowed: true };
      }

      const limit = options?.limit ?? DEFAULT_LIMIT;
      const windowSec = options?.windowSec ?? DEFAULT_WINDOW_SEC;
      const nowSec = Math.floor(Date.now() / 1000);
      const windowSlice = Math.floor(nowSec / windowSec);

      // ADR-0006 key: t:{tid}:rl:{route}:{window}
      const sanitizedRoute = routeKey.replace(/[^a-zA-Z0-9_-]/g, '_');
      const key = `t:${tenantId}:rl:${sanitizedRoute}:${windowSlice}`;

      // Atomic INCR + EXPIRE
      const result = (await this.redis.eval(
        RATE_LIMIT_LUA,
        1,
        key,
        windowSec,
      )) as [number, number];

      const count = result[0];
      const ttl = result[1];

      if (count > limit) {
        const retryAfter = ttl > 0 ? ttl : windowSec;
        return {
          allowed: false,
          retryAfter,
        };
      }

      return { allowed: true };
    } catch (err) {
      // ADR-0006: Fail-open rule: if Redis fails, let traffic through
      this.logger.warn(
        `RateLimitService fail-open for tenant ${tenantId} on route ${routeKey}: ${err}`,
      );
      return { allowed: true };
    }
  }

  private async getTenantPlan(tenantId: string): Promise<string> {
    const cacheKey = `t:${tenantId}:plan`;

    try {
      const cached = await this.redis.get(cacheKey);
      if (cached) {
        return cached;
      }
    } catch {
      // Redis error reading plan -> proceed to DB lookup
    }

    try {
      const rows = await this.ds.query(
        `SELECT plan FROM tenants WHERE id = $1`,
        [tenantId],
      );

      if (rows.length === 0) {
        return 'basic';
      }

      const plan = (rows[0].plan as string) || 'basic';

      try {
        await this.redis.set(cacheKey, plan, 'EX', PLAN_CACHE_TTL_SEC);
      } catch {
        // Non-critical if caching fails
      }

      return plan;
    } catch {
      return 'basic';
    }
  }
}
