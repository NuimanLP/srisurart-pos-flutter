import {
  BadRequestException,
  Body,
  Controller,
  Get,
  HttpCode,
  Param,
  Post,
  Query,
  Req,
  UseGuards,
  UseInterceptors,
} from '@nestjs/common';
import type { Request } from 'express';
import { RequireDeviceRole } from '../common/decorators/device-role.decorator.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { DeviceRoleForbiddenException } from '../common/device-role-forbidden.exception.js';
import { IdempotencyInterceptor } from '../idempotency/idempotency.interceptor.js';
import { Paginated, pageParams } from '../common/paginated.js';
import { parseCreateSale } from './sales.dto.js';
import { SalesService, type CreateSaleResult } from './sales.service.js';
import { SaleReadsService, type SaleWithItems } from './sale-reads.service.js';
import { VoidService } from './void.service.js';

/** What `TenantGuard` attaches once the token has been verified. */
interface AuthenticatedRequest extends Request {
  user: {
    userId: string;
    tenantId: string;
    role?: string;
    deviceId?: string;
    deviceRole?: string;
  };
}

@Controller('sales')
@UseGuards(TenantGuard)
export class SalesController {
  constructor(
    private readonly sales: SalesService,
    private readonly reads: SaleReadsService,
    private readonly voids: VoidService,
  ) {}

  /**
   * `pos` only (ADR-0004: anything that touches the cash drawer happens on the
   * selling machine) and idempotent by force — a retry after a timeout must not
   * ring the bill up twice, because the receipt has already been printed.
   */
  @Post()
  @RequireDeviceRole('pos')
  @UseInterceptors(IdempotencyInterceptor)
  async create(
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
  ): Promise<CreateSaleResult> {
    // A `pos` token always carries `did` — the guard refuses this route otherwise —
    // but the receipt number depends on it, so it is checked rather than asserted.
    if (!req.user.deviceId) {
      throw new DeviceRoleForbiddenException();
    }
    return this.sales.create(parseCreateSale(body), {
      userId: req.user.userId,
      deviceId: req.user.deviceId,
    });
  }

  /** Both device roles: reading a bill does not touch the drawer (ADR-0004). */
  @Get()
  async list(
    @Query('search') search?: string,
    @Query('receiptNo') receiptNo?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('page') page?: string,
    @Query('limit') limit?: string,
  ): Promise<Paginated<SaleWithItems>> {
    const { page: p, limit: l } = pageParams(page, limit);
    const { items, total } = await this.reads.list({
      search,
      receiptNo,
      from: isoDate(from, 'from'),
      to: isoDate(to, 'to'),
      page: p,
      limit: l,
    });
    return new Paginated(items, { total, page: p, limit: l });
  }

  @Get(':id')
  byId(@Param('id') id: string): Promise<SaleWithItems> {
    return this.reads.byId(id);
  }

  /** Per line, how much has already been credited back — the Returns screen's guard. */
  @Get(':id/refunded-qty')
  refundedQty(@Param('id') id: string): Promise<Record<string, number>> {
    return this.reads.refundedQty(id);
  }

  /**
   * `manager` + PIN, `pos` device only. Restores stock, marks the bill void and
   * writes an audit row. Voiding twice, or voiding a bill that already has a credit
   * note against it, is refused.
   */
  @Post(':id/void')
  @HttpCode(200)
  @RequireDeviceRole('pos')
  @UseInterceptors(IdempotencyInterceptor)
  voidSale(
    @Param('id') id: string,
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
  ): Promise<SaleWithItems> {
    if (!req.user.deviceId) {
      throw new DeviceRoleForbiddenException();
    }
    const pin = (body as { pin?: unknown })?.pin;
    return this.voids.void(id, {
      userId: req.user.userId,
      role: req.user.role,
      deviceId: req.user.deviceId,
      pin: typeof pin === 'string' ? pin : '',
      ip: req.ip,
    });
  }
}

function isoDate(raw: string | undefined, field: string): string | undefined {
  if (raw === undefined || raw === '') return undefined;
  if (Number.isNaN(Date.parse(raw))) {
    throw new BadRequestException(`${field} must be an ISO-8601 timestamp`);
  }
  return raw;
}
