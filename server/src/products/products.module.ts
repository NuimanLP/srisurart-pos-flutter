import { Module } from '@nestjs/common';
import { IdempotencyModule } from '../idempotency/idempotency.module.js';
import {
  CategoriesController,
  MovementsController,
  SuppliersController,
} from './catalogue.controllers.js';
import { CategoriesService } from './categories.service.js';
import { MovementsService } from './movements.service.js';
import { ProductImagesController } from './product-images.controller.js';
import { ProductsController } from './products.controller.js';
import { ProductsService } from './products.service.js';
import { SuppliersService } from './suppliers.service.js';

@Module({
  imports: [IdempotencyModule],
  controllers: [
    ProductsController,
    ProductImagesController,
    CategoriesController,
    SuppliersController,
    MovementsController,
  ],
  providers: [
    ProductsService,
    CategoriesService,
    SuppliersService,
    MovementsService,
  ],
  exports: [ProductsService],
})
export class ProductsModule {}
