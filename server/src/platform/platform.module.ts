import { Module } from '@nestjs/common';
import { AuditService } from './audit.service.js';
import { PlatformAuthController } from './platform-auth.controller.js';
import { PlatformAuthGuard } from './platform-auth.guard.js';
import { PlatformAuthService } from './platform-auth.service.js';
import { PlatformTenantsController } from './platform-tenants.controller.js';
import { PlatformTenantsService } from './platform-tenants.service.js';
import { TenantImportController } from './tenant-import.controller.js';
import { TenantImportService } from './tenant-import.service.js';

@Module({
  controllers: [
    PlatformAuthController,
    PlatformTenantsController,
    TenantImportController,
  ],
  providers: [
    AuditService,
    PlatformAuthService,
    PlatformTenantsService,
    TenantImportService,
    PlatformAuthGuard,
  ],
  exports: [PlatformTenantsService, AuditService],
})
export class PlatformModule {}
