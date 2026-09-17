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
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { RequireDeviceRole } from '../common/decorators/device-role.decorator.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { clientIp } from '../common/client-ip.js';
import { DeviceRoleForbiddenException } from '../common/device-role-forbidden.exception.js';
import { idempotencyParamsOf } from '../idempotency/idempotency.runner.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import { Paginated, pageParams } from '../common/paginated.js';
import { parseCreateSale } from './sales.dto.js';
import { SalesService, type CreateSaleResult } from './sales.service.js';
import { SaleReadsService, type SaleWithItems } from './sale-reads.service.js';
import { VoidService, type VoidActor } from './void.service.js';

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
    private readonly idempotency: IdempotencyService,
  ) {}

  /**
   * `pos` only (ADR-0004: anything that touches the cash drawer happens on the
   * selling machine) and idempotent by force — a retry after a timeout must not
   * ring the bill up twice, because the receipt has already been printed.
   */
  @Post()
  @RequireDeviceRole('pos')
  create(
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<CreateSaleResult> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 201),
      res,
      () => {
        // A `pos` token always carries `did` — the guard refuses this route otherwise —
        // but the receipt number depends on it, so it is checked rather than asserted.
        if (!req.user.deviceId) {
          throw new DeviceRoleForbiddenException();
        }
        return this.sales.create(parseCreateSale(body), {
          userId: req.user.userId,
          deviceId: req.user.deviceId,
        });
      },
    );
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
   * `pos` device only. Restores stock, marks the bill void and
   * writes an audit row. Voiding twice, voiding a bill that already has a credit
   * note against it, or voiding a bill that is not from this device's open shift
   * (#94 — a credit note undoes that one), is refused.
   */
  @Post(':id/void')
  @HttpCode(200)
  @RequireDeviceRole('pos')
  async voidSale(
    @Param('id') id: string,
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<SaleWithItems> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () => this.voids.void(id, voidActorOf(req, body)),
    );
  }
}

/** Who is voiding: the token's user, role and device, plus the non-empty reason. */
function voidActorOf(req: AuthenticatedRequest, body: unknown): VoidActor {
  // A `pos` token always carries `did` — the guard refuses this route otherwise — but the
  // audit rows depend on it, so it is checked rather than asserted.
  if (!req.user.deviceId) {
    throw new DeviceRoleForbiddenException();
  }
  const reason = (body as { reason?: unknown })?.reason;
  if (typeof reason !== 'string' || reason.trim() === '') {
    throw new BadRequestException('Void reason is required');
  }
  return {
    userId: req.user.userId,
    role: req.user.role,
    deviceId: req.user.deviceId,
    reason: reason.trim(),
    ip: clientIp(req) ?? undefined,
  };
}

function isoDate(raw: string | undefined, field: string): string | undefined {
  if (raw === undefined || raw === '') return undefined;
  if (Number.isNaN(Date.parse(raw))) {
    throw new BadRequestException(`${field} must be an ISO-8601 timestamp`);
  }
  return raw;
}
