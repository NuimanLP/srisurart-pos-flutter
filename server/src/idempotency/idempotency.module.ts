import { Module } from '@nestjs/common';
import { IdempotencyInterceptor } from './idempotency.interceptor.js';
import { IdempotencyService } from './idempotency.service.js';

/**
 * Import where a controller applies `IdempotencyInterceptor` (#18 p5.1).
 * `POST /sales` is the first adopter, in #20.
 */
@Module({
  providers: [IdempotencyService, IdempotencyInterceptor],
  exports: [IdempotencyService, IdempotencyInterceptor],
})
export class IdempotencyModule {}
