import { Module } from '@nestjs/common';
import { DocumentsModule } from '../documents/documents.module.js';
import { IdempotencyModule } from '../idempotency/idempotency.module.js';
import { SalesController } from './sales.controller.js';
import { SalesService } from './sales.service.js';

@Module({
  imports: [DocumentsModule, IdempotencyModule],
  controllers: [SalesController],
  providers: [SalesService],
})
export class SalesModule {}
