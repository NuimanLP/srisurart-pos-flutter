import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  Patch,
  Post,
  Query,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Response } from 'express';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { Paginated, pageParams } from '../common/paginated.js';
import { idempotencyParamsOf } from '../idempotency/idempotency.runner.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import { isoDate } from '../people/people.dto.js';
import type { MovementOut } from '../sales/sales.service.js';
import {
  parseCategoryCreate,
  parseSupplierCreate,
  parseSupplierPatch,
  type AuthenticatedRequest,
} from './catalogue.dto.js';
import { CategoriesService, type Category } from './categories.service.js';
import { MovementsService } from './movements.service.js';
import { SuppliersService, type Supplier } from './suppliers.service.js';

@Controller('categories')
@UseGuards(TenantGuard)
export class CategoriesController {
  constructor(
    private readonly categories: CategoriesService,
    private readonly idempotency: IdempotencyService,
  ) {}

  @Get()
  async list(@Res({ passthrough: true }) res: Response): Promise<Category[]> {
    const result = await this.categories.listCached();
    res.setHeader('X-Cache', result.fromCache ? 'HIT' : 'MISS');
    return result.categories;
  }

  @Post()
  create(
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Category> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 201),
      res,
      () => this.categories.create(parseCategoryCreate(body).name),
    );
  }

  @Delete(':name')
  delete(
    @Param('name') name: string,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<{ name: string; deleted: true }> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () => this.categories.delete(name),
    );
  }
}

/** Reads live on `GET /products/:id/suppliers` (ProductsController). */
@Controller('suppliers')
@UseGuards(TenantGuard)
export class SuppliersController {
  constructor(
    private readonly suppliers: SuppliersService,
    private readonly idempotency: IdempotencyService,
  ) {}

  @Post()
  create(
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Supplier> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 201),
      res,
      () => this.suppliers.create(parseSupplierCreate(body)),
    );
  }

  @Patch(':id')
  update(
    @Param('id') id: string,
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Supplier> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () => this.suppliers.update(id, parseSupplierPatch(body)),
    );
  }

  @Delete(':id')
  delete(
    @Param('id') id: string,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<{ id: string; deleted: true }> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () => this.suppliers.delete(id),
    );
  }
}

@Controller('movements')
@UseGuards(TenantGuard)
export class MovementsController {
  constructor(private readonly movements: MovementsService) {}

  @Get()
  async list(
    @Query('productId') productId?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('page') page?: string,
    @Query('limit') limit?: string,
  ): Promise<Paginated<MovementOut>> {
    const parsed = pageParams(page, limit);
    const result = await this.movements.list({
      productId: productId || undefined,
      from: isoDate(from, 'from'),
      to: isoDate(to, 'to'),
      ...parsed,
    });
    return new Paginated(result.items, { total: result.total, ...parsed });
  }
}
