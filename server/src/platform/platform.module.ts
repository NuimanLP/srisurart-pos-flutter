import { Module } from '@nestjs/common';
import { AuditService } from './audit.service.js';
import { PlatformAuthController } from './platform-auth.controller.js';
import { PlatformAuthGuard } from './platform-auth.guard.js';
import { PlatformAuthService } from './platform-auth.service.js';
import { PlatformTenantsController } from './platform-tenants.controller.js';
import { PlatformTenantsService } from './platform-tenants.service.js';
import { TenantImportModule } from './tenant-import.module.js';

@Module({
  imports: [TenantImportModule],
  controllers: [PlatformAuthController, PlatformTenantsController],
  providers: [AuditService, PlatformAuthService, PlatformTenantsService, PlatformAuthGuard],
  exports: [PlatformTenantsService, AuditService],
})
export class PlatformModule {}
