import {
  Body,
  Controller,
  Delete,
  ForbiddenException,
  Get,
  Param,
  Patch,
  Post,
  Query,
  Req,
  UseGuards,
  UseInterceptors,
} from '@nestjs/common';
import type { Request } from 'express';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { Paginated, pageParams } from '../common/paginated.js';
import { IdempotencyInterceptor } from '../idempotency/idempotency.interceptor.js';
import {
  isoDate,
  parseMechanicCreate,
  parseMechanicPatch,
} from '../people/people.dto.js';
import type { SaleWithItems } from '../sales/sale-reads.service.js';
import { MechanicsService, type Mechanic } from './mechanics.service.js';

interface AuthenticatedRequest extends Request {
  user: { role?: string };
}

@Controller('mechanics')
@UseGuards(TenantGuard)
export class MechanicsController {
  constructor(private readonly mechanics: MechanicsService) {}

  @Get()
  async list(
    @Query('search') search?: string,
    @Query('updatedSince') updatedSince?: string,
    @Query('page') page?: string,
    @Query('limit') limit?: string,
  ): Promise<Paginated<Mechanic>> {
    const parsed = pageParams(page, limit);
    const result = await this.mechanics.list({
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
    const result = await this.mechanics.sales(id, parsed.page, parsed.limit);
    return new Paginated(result.items, { total: result.total, ...parsed });
  }

  @Get(':id')
  byId(@Param('id') id: string): Promise<Mechanic> {
    return this.mechanics.byId(id);
  }

  @Post()
  @UseInterceptors(IdempotencyInterceptor)
  create(
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
  ): Promise<Mechanic> {
    requireManager(req);
    return this.mechanics.create(parseMechanicCreate(body));
  }

  @Patch(':id')
  @UseInterceptors(IdempotencyInterceptor)
  update(
    @Param('id') id: string,
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
  ): Promise<Mechanic> {
    requireManager(req);
    return this.mechanics.update(id, parseMechanicPatch(body));
  }

  @Delete(':id')
  @UseInterceptors(IdempotencyInterceptor)
  delete(
    @Param('id') id: string,
    @Req() req: AuthenticatedRequest,
  ): Promise<{ id: string; deleted: true }> {
    requireManager(req);
    return this.mechanics.delete(id);
  }
}

function requireManager(req: AuthenticatedRequest): void {
  if (req.user.role !== 'manager' && req.user.role !== 'owner') {
    throw new ForbiddenException({
      code: 'FORBIDDEN',
      message: 'Manager role required',
    });
  }
}
