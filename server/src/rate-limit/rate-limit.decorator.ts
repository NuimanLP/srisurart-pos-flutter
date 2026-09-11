import { SetMetadata } from '@nestjs/common';

export interface RateLimitOptions {
  /** Maximum number of allowed requests in the time window. */
  limit: number;
  /** Window duration in seconds. Defaults to 60. */
  windowSec?: number;
}

export const RATE_LIMIT_OPTIONS_KEY = 'rate_limit_options';
export const SKIP_RATE_LIMIT_KEY = 'skip_rate_limit';

/** Sets custom rate limit options on a route handler or controller. */
export const RateLimit = (options: RateLimitOptions) =>
  SetMetadata(RATE_LIMIT_OPTIONS_KEY, options);

/** Exempts a route handler or controller from rate limiting. */
export const SkipRateLimit = () => SetMetadata(SKIP_RATE_LIMIT_KEY, true);
