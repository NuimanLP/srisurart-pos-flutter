import { Module } from '@nestjs/common';
import { IdempotencyModule } from '../idempotency/idempotency.module.js';
import { SalesModule } from '../sales/sales.module.js';
import { CustomersController } from './customers.controller.js';
import { CustomersService } from './customers.service.js';

@Module({
  imports: [IdempotencyModule, SalesModule],
  controllers: [CustomersController],
  providers: [CustomersService],
})
export class CustomersModule {}
