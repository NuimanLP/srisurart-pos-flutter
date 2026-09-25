import {
  BadRequestException,
  Body,
  Controller,
  Get,
  HttpCode,
  Post,
  Query,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { RequireDeviceRole } from '../common/decorators/device-role.decorator.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { DeviceRoleForbiddenException } from '../common/device-role-forbidden.exception.js';
import { toSatang } from '../common/money.js';
import { idempotencyParamsOf } from '../idempotency/idempotency.runner.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import { Paginated, pageParams } from '../common/paginated.js';
import {
  ShiftsService,
  type Actor,
  type DrawerEntry,
  type ShiftWithEntries,
} from './shifts.service.js';

interface AuthenticatedRequest extends Request {
  user: { userId: string; tenantId: string; deviceId?: string };
}

@Controller('shifts')
@UseGuards(TenantGuard)
export class ShiftsController {
  constructor(
    private readonly shifts: ShiftsService,
    private readonly idempotency: IdempotencyService,
  ) {}

  /**
   * Both device roles may read: looking at the drawer does not touch it (ADR-0004).
   * A `backoffice` machine has to be able to see whether the shop is open.
   */
  @Get('current')
  current(): Promise<ShiftWithEntries | null> {
    return this.shifts.current();
  }

  @Get('history')
  async history(
    @Query('page') page?: string,
    @Query('limit') limit?: string,
  ): Promise<Paginated<ShiftWithEntries>> {
    const { page: p, limit: l } = pageParams(page, limit);
    const { items, total } = await this.shifts.history(p, l);
    return new Paginated(items, { total, page: p, limit: l });
  }

  @Post('open')
  @HttpCode(200)
  @RequireDeviceRole('pos')
  open(
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<ShiftWithEntries> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () => {
        const b = asObject(body);
        // `openedAt` is deliberately not read (#411, 08 §10): an online open is stamped
        // with the server's `now()`. Only `/sync/push` passes a device-recorded time.
        return this.shifts.open(actorOf(req), {
          id: asOptionalString(b.id, 'id'),
          startingCashSatang: cash(b.startingCash, 'startingCash'),
        });
      },
    );
  }

  @Post('close')
  @HttpCode(200)
  @RequireDeviceRole('pos')
  close(
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<ShiftWithEntries> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () => {
        const b = asObject(body);
        return this.shifts.close(
          actorOf(req).deviceId,
          cash(b.physicalCash, 'physicalCash'),
        );
      },
    );
  }

  @Post('current/entries')
  @RequireDeviceRole('pos')
  addEntry(
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<DrawerEntry> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 201),
      res,
      () => {
        const b = asObject(body);
        if (b.type !== 'in' && b.type !== 'out') {
          throw new BadRequestException(`type must be 'in' or 'out'`);
        }
        const amountSatang = toSatang(b.amount, 'amount');
        if (amountSatang <= 0)
          throw new BadRequestException('amount must be greater than zero');
        const id = typeof b.id === 'string' && b.id.trim() ? b.id.trim() : null;
        const note = b.note === undefined || b.note === null ? null : String(b.note);
        // `createdAt` is deliberately not read (#411, 08 §10) — server `now()` online;
        // only `/sync/push` passes a device-recorded time.
        return this.shifts.addEntry(actorOf(req), {
          id,
          type: b.type,
          amountSatang,
          note,
        });
      },
    );
  }
}

/**
 * A `pos` token always carries `did` — the guard refuses these routes otherwise —
 * but `uq_shift_active` is keyed on the device, so a missing one would silently open
 * a shift nothing can find again.
 */
function actorOf(req: AuthenticatedRequest): Actor {
  if (!req.user.deviceId) {
    throw new DeviceRoleForbiddenException();
  }
  return { userId: req.user.userId, deviceId: req.user.deviceId };
}

/**
 * Cash counted into or out of the drawer. Required and non-negative, both on purpose:
 * a defaulted `0` closes the day at zero counted cash, and the closing report then
 * shows a shortfall the size of the day's takings — which §3.11 names as the thing
 * that makes staff stop believing the report at all.
 */
function cash(value: unknown, field: string): number {
  if (value === undefined || value === null || value === '') {
    throw new BadRequestException(`${field} is required`);
  }
  const satang = toSatang(value, field);
  if (satang < 0)
    throw new BadRequestException(`${field} must not be negative`);
  return satang;
}

function asObject(body: unknown): Record<string, unknown> {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    throw new BadRequestException('body must be an object');
  }
  return body as Record<string, unknown>;
}

function asOptionalString(value: unknown, field: string): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'string' || value.trim() === '') {
    throw new BadRequestException(`${field} must be a non-empty string`);
  }
  return value.trim();
}
