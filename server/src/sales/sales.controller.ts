import {
  Body,
  Controller,
  ForbiddenException,
  Post,
  Req,
  UseGuards,
  UseInterceptors,
} from '@nestjs/common';
import type { Request } from 'express';
import { RequireDeviceRole } from '../common/decorators/device-role.decorator.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { IdempotencyInterceptor } from '../idempotency/idempotency.interceptor.js';
import { parseCreateSale } from './sales.dto.js';
import { SalesService, type CreateSaleResult } from './sales.service.js';

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
  constructor(private readonly sales: SalesService) {}

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
      throw new ForbiddenException({
        code: 'DEVICE_ROLE_FORBIDDEN',
        message: 'เครื่องนี้ขายของไม่ได้',
      });
    }
    return this.sales.create(parseCreateSale(body), {
      userId: req.user.userId,
      deviceId: req.user.deviceId,
    });
  }
}
