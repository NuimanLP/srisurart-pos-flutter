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
import type { Request, Response } from 'express';
import { RequireDeviceRole } from '../common/decorators/device-role.decorator.js';
import { DeviceRoleForbiddenException } from '../common/device-role-forbidden.exception.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { Paginated, pageParams } from '../common/paginated.js';
import { idempotencyParamsOf } from '../idempotency/idempotency.runner.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import {
  isoDate,
  parseMechanicCreate,
  parseMechanicPatch,
} from '../people/people.dto.js';
import type { SaleWithItems } from '../sales/sale-reads.service.js';
import { parseCreateCreditPayment } from './credit-payments.dto.js';
import {
  CreditPaymentsService,
  type CreateCreditPaymentResult,
} from './credit-payments.service.js';
import { MechanicsService, type Mechanic } from './mechanics.service.js';

interface AuthenticatedRequest extends Request {
  user: { userId: string; role?: string; deviceId?: string };
}

@Controller('mechanics')
@UseGuards(TenantGuard)
export class MechanicsController {
  constructor(
    private readonly mechanics: MechanicsService,
    private readonly creditPayments: CreditPaymentsService,
    private readonly idempotency: IdempotencyService,
  ) {}

  @Get()
  async list(
    @Query('search') search: string | undefined,
    @Query('updatedSince') updatedSince: string | undefined,
    @Query('page') page: string | undefined,
    @Query('limit') limit: string | undefined,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Paginated<Mechanic>> {
    const parsed = pageParams(page, limit);
    const result = await this.mechanics.list({
      search: search || undefined,
      updatedSince: isoDate(updatedSince, 'updatedSince'),
      ...parsed,
    });
    res.setHeader('X-Cache', result.fromCache ? 'HIT' : 'MISS');
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
  create(
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Mechanic> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 201),
      res,
      () => this.mechanics.create(parseMechanicCreate(body)),
    );
  }

  @Patch(':id')
  update(
    @Param('id') id: string,
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Mechanic> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () => this.mechanics.update(id, parseMechanicPatch(body)),
    );
  }

  /**
   * The mechanic pays down his tab. `pos` only — this takes cash over the counter and
   * prints a receipt, so it belongs to the machine with the drawer (ADR-0004) — and
   * idempotent by force: the receipt is already in the mechanic's hand by the time a
   * retry happens.
   *
   * Not `requireManager`: the cashier at the counter is who takes the money, and the
   * Dart intake dialog is on the mechanics screen with no PIN in front of it.
   */
  @Post(':id/credit-payments')
  @RequireDeviceRole('pos')
  creditPayment(
    @Param('id') id: string,
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<CreateCreditPaymentResult> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 201),
      res,
      () => {
        // A `pos` token always carries `did` — the guard refuses this route otherwise —
        // but the CP number depends on it, so it is checked rather than asserted.
        if (!req.user.deviceId) {
          throw new DeviceRoleForbiddenException();
        }
        return this.creditPayments.create(id, parseCreateCreditPayment(body), {
          userId: req.user.userId,
          deviceId: req.user.deviceId,
        });
      },
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
      () => this.mechanics.delete(id),
    );
  }
}

