import { Module } from '@nestjs/common';
import { IdempotencyModule } from '../idempotency/idempotency.module.js';
import { PaymentAccountsController } from './payment-accounts.controller.js';
import { PaymentAccountsService } from './payment-accounts.service.js';

@Module({
  imports: [IdempotencyModule],
  controllers: [PaymentAccountsController],
  providers: [PaymentAccountsService],
})
export class PaymentAccountsModule {}
