import { Module } from '@nestjs/common';
import { DocumentsModule } from '../documents/documents.module.js';
import { IdempotencyModule } from '../idempotency/idempotency.module.js';
import { ShiftsModule } from '../shifts/shifts.module.js';
import { SalesController } from './sales.controller.js';
import { SalesService } from './sales.service.js';

@Module({
  imports: [DocumentsModule, IdempotencyModule, ShiftsModule],
  controllers: [SalesController],
  providers: [SalesService],
})
export class SalesModule {}
