import { Module } from '@nestjs/common';
import { IdempotencyModule } from '../idempotency/idempotency.module.js';
import { ShiftsController } from './shifts.controller.js';
import { ShiftsService } from './shifts.service.js';

@Module({
  imports: [IdempotencyModule],
  controllers: [ShiftsController],
  providers: [ShiftsService],
  // `SalesService` stamps `shift_id` on every bill (#28), so the service leaves this
  // module; the controller does not.
  exports: [ShiftsService],
})
export class ShiftsModule {}
