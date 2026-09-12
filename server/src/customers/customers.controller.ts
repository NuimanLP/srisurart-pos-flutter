import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  Patch,
  Post,
  Query,
  UseGuards,
  UseInterceptors,
} from '@nestjs/common';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { Paginated, pageParams } from '../common/paginated.js';
import { IdempotencyInterceptor } from '../idempotency/idempotency.interceptor.js';
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
  constructor(private readonly customers: CustomersService) {}

  @Get()
  async list(
    @Query('search') search?: string,
    @Query('updatedSince') updatedSince?: string,
    @Query('page') page?: string,
    @Query('limit') limit?: string,
  ): Promise<Paginated<Customer>> {
    const parsed = pageParams(page, limit);
    const result = await this.customers.list({
      search: search || undefined,
      updatedSince: isoDate(updatedSince, 'updatedSince'),
      ...parsed,
    });
    return new Paginated(result.items, { total: result.total, ...parsed });
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
  @UseInterceptors(IdempotencyInterceptor)
  create(@Body() body: unknown): Promise<Customer> {
    return this.customers.create(parseCustomerCreate(body));
  }

  @Patch(':id')
  @UseInterceptors(IdempotencyInterceptor)
  update(@Param('id') id: string, @Body() body: unknown): Promise<Customer> {
    return this.customers.update(id, parseCustomerPatch(body));
  }

  @Delete(':id')
  @UseInterceptors(IdempotencyInterceptor)
  delete(@Param('id') id: string): Promise<{ id: string; deleted: true }> {
    return this.customers.delete(id);
  }
}
