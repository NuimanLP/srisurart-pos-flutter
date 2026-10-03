import { Module } from '@nestjs/common';
import { DocumentsModule } from '../documents/documents.module.js';
import { IdempotencyModule } from '../idempotency/idempotency.module.js';
import { ShiftsModule } from '../shifts/shifts.module.js';
import { SalesController } from './sales.controller.js';
import { QuoteSaleService } from './quote-sale.service.js';
import { SalesService } from './sales.service.js';
import { SaleReadsService } from './sale-reads.service.js';
import { VoidService } from './void.service.js';

@Module({
  imports: [DocumentsModule, IdempotencyModule, ShiftsModule],
  controllers: [SalesController],
  providers: [SalesService, SaleReadsService, VoidService, QuoteSaleService],
  // `SalesService` + `QuoteSaleService` for `POST /quotes/:id/convert` (#27), which
  // sells through them.
  exports: [SaleReadsService, SalesService, VoidService, QuoteSaleService],
})
export class SalesModule {}
