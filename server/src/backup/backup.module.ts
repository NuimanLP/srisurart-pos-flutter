import { Module } from '@nestjs/common';
import { BackupController } from './backup.controller.js';
import { QueueModule } from '../queue/queue.module.js';
import { AuditModule } from '../audit/audit.module.js';
import { TenantImportModule } from '../platform/tenant-import.module.js';
import { OwnerImportController } from './owner-import.controller.js';

@Module({
  imports: [QueueModule, AuditModule, TenantImportModule],
  controllers: [BackupController, OwnerImportController],
  exports: [],
})
export class BackupModule {}
