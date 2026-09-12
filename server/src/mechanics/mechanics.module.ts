import { Module } from '@nestjs/common';
import { IdempotencyModule } from '../idempotency/idempotency.module.js';
import { SalesModule } from '../sales/sales.module.js';
import { MechanicsController } from './mechanics.controller.js';
import { MechanicsService } from './mechanics.service.js';

@Module({
  imports: [IdempotencyModule, SalesModule],
  controllers: [MechanicsController],
  providers: [MechanicsService],
})
export class MechanicsModule {}
