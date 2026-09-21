import { Module } from '@nestjs/common';
import { MetricsModule } from '../metrics/metrics.module.js';
import { IdempotencyService } from './idempotency.service.js';

/**
 * Import where a controller calls `IdempotencyService.runIdempotent` (#18 p5.1; explicit
 * since tx.3 #152). `POST /sales` was the first adopter, in #20.
 */
@Module({
  // `MetricsModule` is imported explicitly even though it is `@Global()`: the replay counter
  // (D5 #335) is a hard dependency of this service, and an explicit edge means a graph that
  // ever loses the global registration fails at bootstrap rather than counting nothing.
  imports: [MetricsModule],
  providers: [IdempotencyService],
  exports: [IdempotencyService],
})
export class IdempotencyModule {}
