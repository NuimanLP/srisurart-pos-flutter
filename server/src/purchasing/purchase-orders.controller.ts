import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  Param,
  Post,
  Query,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Response } from 'express';
import { DeviceRoleForbiddenException } from '../common/device-role-forbidden.exception.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { Paginated, pageParams } from '../common/paginated.js';
import { idempotencyParamsOf } from '../idempotency/idempotency.runner.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import { type AuthenticatedRequest } from '../products/catalogue.dto.js';
import { parsePoCreate, parsePoStatus } from './purchase-orders.dto.js';
import {
  PurchaseOrdersService,
  type PurchaseOrder,
  type ReceiveResult,
} from './purchase-orders.service.js';

/**
 * 02_API_SCREENS.md §3.3 / §4: reads for any role, writes `manager` (owner included),
 * both device roles — receiving stock is back-office work and touches no drawer.
 */
@Controller('purchase-orders')
@UseGuards(TenantGuard)
export class PurchaseOrdersController {
  constructor(
    private readonly orders: PurchaseOrdersService,
    private readonly idempotency: IdempotencyService,
  ) {}

  @Get()
  async list(
    @Query('status') status?: string,
    @Query('page') page?: string,
    @Query('limit') limit?: string,
  ): Promise<Paginated<PurchaseOrder>> {
    const parsed = pageParams(page, limit);
    const result = await this.orders.list({
      status: parsePoStatus(status),
      ...parsed,
    });
    return new Paginated(result.items, { total: result.total, ...parsed });
  }

  @Get(':id')
  get(@Param('id') id: string): Promise<PurchaseOrder> {
    return this.orders.get(id);
  }

  @Post()
  create(
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<PurchaseOrder> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 201),
      res,
      () => {
        const input = parsePoCreate(body);
        // The PO number is issued in the calling device's series (ADR-0007), and the
        // device comes from the token only (ADR-0004).
        if (!req.user.deviceId) throw new DeviceRoleForbiddenException();
        return this.orders.create(input, { deviceId: req.user.deviceId });
      },
    );
  }

  /** The one that matters: transactional, and idempotent by force (§4). */
  @Post(':id/receive')
  @HttpCode(200)
  receive(
    @Param('id') id: string,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<ReceiveResult> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () =>
        this.orders.receive(id, {
          userId: req.user.userId,
          deviceId: req.user.deviceId,
        }),
    );
  }

  @Post(':id/cancel')
  @HttpCode(200)
  cancel(
    @Param('id') id: string,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<PurchaseOrder> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () => this.orders.cancel(id),
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
      () => this.orders.delete(id),
    );
  }
}
