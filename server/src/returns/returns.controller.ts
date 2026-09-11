import {
  BadRequestException,
  Body,
  Controller,
  Get,
  Post,
  Query,
  Req,
  UseGuards,
  UseInterceptors,
} from '@nestjs/common';
import type { Request } from 'express';
import { RequireDeviceRole } from '../common/decorators/device-role.decorator.js';
import { DeviceRoleForbiddenException } from '../common/device-role-forbidden.exception.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { Paginated, pageParams } from '../common/paginated.js';
import { IdempotencyInterceptor } from '../idempotency/idempotency.interceptor.js';
import { parseCreateReturn } from './returns.dto.js';
import {
  ReturnsService,
  type CreateReturnResult,
  type ReturnWithItems,
} from './returns.service.js';

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

@Controller('returns')
@UseGuards(TenantGuard)
export class ReturnsController {
  constructor(private readonly returns: ReturnsService) {}

  /**
   * `pos` only — a credit note puts stock back and takes money out of the drawer,
   * exactly like a sale (ADR-0004) — and idempotent by force: the credit note has
   * already been printed by the time a retry happens.
   */
  @Post()
  @RequireDeviceRole('pos')
  @UseInterceptors(IdempotencyInterceptor)
  create(
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
  ): Promise<CreateReturnResult> {
    // A `pos` token always carries `did` — the guard refuses this route otherwise —
    // but the credit-note number depends on it, so it is checked rather than asserted.
    if (!req.user.deviceId) {
      throw new DeviceRoleForbiddenException();
    }
    return this.returns.create(parseCreateReturn(body), {
      userId: req.user.userId,
      deviceId: req.user.deviceId,
    });
  }

  /** Both device roles: reading the refund history does not touch the drawer. */
  @Get()
  async list(
    @Query('saleId') saleId?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('page') page?: string,
    @Query('limit') limit?: string,
  ): Promise<Paginated<ReturnWithItems>> {
    const { page: p, limit: l } = pageParams(page, limit);
    const { items, total } = await this.returns.list({
      saleId: saleId || undefined,
      from: isoDate(from, 'from'),
      to: isoDate(to, 'to'),
      page: p,
      limit: l,
    });
    return new Paginated(items, { total, page: p, limit: l });
  }
}

/**
 * The same guard `sales.controller.ts` puts on its own `from`/`to`: an unparseable
 * value would otherwise reach Postgres as a `22007` and surface as a 500. Copied
 * rather than shared — the sale and the credit note are separate contracts, and #22's
 * review asked for no new helpers between them.
 */
function isoDate(raw: string | undefined, field: string): string | undefined {
  if (raw === undefined || raw === '') return undefined;
  if (Number.isNaN(Date.parse(raw))) {
    throw new BadRequestException(`${field} must be an ISO-8601 timestamp`);
  }
  return raw;
}
