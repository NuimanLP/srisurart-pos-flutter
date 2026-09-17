import {
  BadRequestException,
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
import type { Request, Response } from 'express';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { Paginated, pageParams } from '../common/paginated.js';
import { idempotencyParamsOf } from '../idempotency/idempotency.runner.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import {
  isoDate,
  parseCustomerCreate,
  parseCustomerPatch,
} from '../people/people.dto.js';
import { CustomersService, type Customer } from './customers.service.js';
import type { SaleWithItems } from '../sales/sale-reads.service.js';

@Controller('customers')
@UseGuards(TenantGuard)
export class CustomersController {
  constructor(
    private readonly customers: CustomersService,
    private readonly idempotency: IdempotencyService,
  ) {}

  @Get()
  async list(
    @Query('search') search: string | undefined,
    @Query('updatedSince') updatedSince: string | undefined,
    @Query('afterId') afterId: string | undefined,
    @Query('page') page: string | undefined,
    @Query('limit') limit: string | undefined,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Paginated<Customer>> {
    const parsed = pageParams(page, limit);
    const since = isoDate(updatedSince, 'updatedSince');
    if (afterId && !since) {
      throw new BadRequestException('afterId requires updatedSince');
    }
    if (since && parsed.page > 1) {
      throw new BadRequestException(
        'updatedSince is keyset-paged: follow meta.nextCursor instead of page',
      );
    }
    const result = await this.customers.list({
      search: search || undefined,
      updatedSince: since,
      afterId: afterId || undefined,
      ...parsed,
    });
    res.setHeader('X-Cache', result.fromCache ? 'HIT' : 'MISS');
    return new Paginated(result.items, {
      total: result.total,
      ...parsed,
      nextCursor: result.nextCursor,
    });
  }

  @Get(':id/sales')
  async sales(
    @Param('id') id: string,
    @Query('page') page?: string,
    @Query('limit') limit?: string,
  ): Promise<Paginated<SaleWithItems>> {
    const parsed = pageParams(page, limit);
    const result = await this.customers.sales(id, parsed.page, parsed.limit);
    return new Paginated(result.items, { total: result.total, ...parsed });
  }

  @Get(':id')
  byId(@Param('id') id: string): Promise<Customer> {
    return this.customers.byId(id);
  }

  @Post()
  create(
    @Body() body: unknown,
    @Req() req: Request,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Customer> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 201),
      res,
      () => {
        return this.customers.create(parseCustomerCreate(body));
      },
    );
  }

  @Patch(':id')
  update(
    @Param('id') id: string,
    @Body() body: unknown,
    @Req() req: Request,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Customer> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () => {
        return this.customers.update(id, parseCustomerPatch(body));
      },
    );
  }

  @Delete(':id')
  delete(
    @Param('id') id: string,
    @Req() req: Request,
    @Res({ passthrough: true }) res: Response,
  ): Promise<{ id: string; deleted: true }> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () => {
        return this.customers.delete(id);
      },
    );
  }
}
