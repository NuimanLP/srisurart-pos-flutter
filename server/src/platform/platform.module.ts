import { Module } from '@nestjs/common';
import { HealthModule } from '../health/health.module.js';
import { AuditService } from './audit.service.js';
import { PlatformAuditController } from './platform-audit.controller.js';
import { PlatformAuditService } from './platform-audit.service.js';
import { PlatformAuthController } from './platform-auth.controller.js';
import { PlatformAuthGuard } from './platform-auth.guard.js';
import { PlatformAuthService } from './platform-auth.service.js';
import { PlatformTenantsController } from './platform-tenants.controller.js';
import { PlatformSystemController } from './platform-system.controller.js';
import { PlatformSystemService } from './platform-system.service.js';
import { PlatformTenantsService } from './platform-tenants.service.js';
import { TenantImportModule } from './tenant-import.module.js';

@Module({
  imports: [TenantImportModule, HealthModule],
  controllers: [
    PlatformAuthController,
    PlatformTenantsController,
    PlatformAuditController,
    PlatformSystemController,
  ],
  providers: [
    AuditService,
    PlatformAuthService,
    PlatformTenantsService,
    PlatformAuthGuard,
    PlatformAuditService,
    PlatformSystemService,
  ],
  exports: [PlatformTenantsService, AuditService],
})
export class PlatformModule {}
