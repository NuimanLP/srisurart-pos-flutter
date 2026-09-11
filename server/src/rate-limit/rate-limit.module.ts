import { Global, Module } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';
import { RateLimitService } from './rate-limit.service.js';
import { TenantRateLimitGuard } from './tenant-rate-limit.guard.js';

@Global()
@Module({
  providers: [
    RateLimitService,
    TenantRateLimitGuard,
    {
      provide: APP_GUARD,
      useClass: TenantRateLimitGuard,
    },
  ],
  exports: [RateLimitService, TenantRateLimitGuard],
})
export class RateLimitModule {}
