import { Module } from '@nestjs/common';
import { DocumentsModule } from '../documents/documents.module.js';
import { IdempotencyModule } from '../idempotency/idempotency.module.js';
import { SalesModule } from '../sales/sales.module.js';
import { ShiftsModule } from '../shifts/shifts.module.js';
import { CreditPaymentsService } from './credit-payments.service.js';
import { MechanicsController } from './mechanics.controller.js';
import { MechanicsService } from './mechanics.service.js';

@Module({
  // `DocumentsModule` issues the CP number and `ShiftsModule` supplies the `shift_id`
  // stamp — a credit payment is a money document like a bill or a credit note (#24).
  imports: [DocumentsModule, IdempotencyModule, SalesModule, ShiftsModule],
  controllers: [MechanicsController],
  providers: [MechanicsService, CreditPaymentsService],
  exports: [MechanicsService, CreditPaymentsService],
})
export class MechanicsModule {}
