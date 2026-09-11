import { Global, Module } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';
import { AuthModule } from '../auth/auth.module.js';
import { RateLimitService } from './rate-limit.service.js';
import { TenantRateLimitGuard } from './tenant-rate-limit.guard.js';

@Global()
@Module({
  imports: [AuthModule],
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
