import { Module } from '@nestjs/common';
import { IdempotencyModule } from '../idempotency/idempotency.module.js';
import { ReviewItemsController } from './review-items.controller.js';
import { ReviewItemsService } from './review-items.service.js';

@Module({
  imports: [IdempotencyModule],
  controllers: [ReviewItemsController],
  providers: [ReviewItemsService],
  exports: [ReviewItemsService],
})
export class ReviewItemsModule {}
