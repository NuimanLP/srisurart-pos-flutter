import { Module } from '@nestjs/common';
import { AuditService } from './audit.service.js';
import { TenantImportController } from './tenant-import.controller.js';
import { TenantImportService } from './tenant-import.service.js';

/**
 * #239: `TenantImportService` now runs on both sides — the API process answers
 * `POST/GET .../import` (this module's own `TenantImportController`), and the worker process
 * runs `TenantImportProcessor` (`queue/processors/tenant-import.processor.ts`), which needs the
 * same service with none of the HTTP plumbing. A dedicated module (rather than folding the
 * service into `PlatformModule`, which also carries `PlatformAuthGuard` and its controllers)
 * lets `QueueProcessorsModule` import just this and stay free of anything HTTP-only.
 *
 * No `QueueModule` import here on purpose: `TenantImportService`'s `@InjectQueue` only needs
 * the queue registered somewhere in the app's tree, and both `AppModule.forRoot` and
 * `WorkerModule.forRoot` already import the (`@Global()`) `QueueModule` directly. Importing it
 * here too would close a cycle back through `queue/queue.module.ts`, which imports this module
 * (via `QueueProcessorsModule`) to reach `TenantImportProcessor`'s dependency.
 */
@Module({
  controllers: [TenantImportController],
  providers: [TenantImportService, AuditService],
  exports: [TenantImportService],
})
export class TenantImportModule {}
