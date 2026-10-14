import { Module } from '@nestjs/common';
import { IdempotencyModule } from '../idempotency/idempotency.module.js';
import { SalePhotosController } from './sale-photos.controller.js';
import { SalePhotosService } from './sale-photos.service.js';

@Module({
  imports: [IdempotencyModule],
  controllers: [SalePhotosController],
  providers: [SalePhotosService],
})
export class SalePhotosModule {}
