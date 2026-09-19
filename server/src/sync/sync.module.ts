import { Module } from '@nestjs/common';
import { AuditModule } from '../audit/audit.module.js';
import { AuthModule } from '../auth/auth.module.js';
import { CustomersModule } from '../customers/customers.module.js';
import { IdempotencyModule } from '../idempotency/idempotency.module.js';
import { MechanicsModule } from '../mechanics/mechanics.module.js';
import { ReturnsModule } from '../returns/returns.module.js';
import { ReviewItemsModule } from '../review-items/review-items.module.js';
import { SalesModule } from '../sales/sales.module.js';
import { ShiftsModule } from '../shifts/shifts.module.js';
import { DeviceTokenGuard } from '../common/guards/device-token.guard.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { TenantOrDeviceTokenGuard } from '../common/guards/tenant-or-device.guard.js';
import { SyncController } from './sync.controller.js';
import { SyncService } from './sync.service.js';

@Module({
  imports: [
    SalesModule,
    ReturnsModule,
    ShiftsModule,
    MechanicsModule,
    CustomersModule,
    ReviewItemsModule,
    IdempotencyModule,
    AuditModule,
    AuthModule,
  ],
  controllers: [SyncController],
  providers: [
    SyncService,
    DeviceTokenGuard,
    TenantGuard,
    TenantOrDeviceTokenGuard,
  ],
  exports: [SyncService],
})
export class SyncModule {}
