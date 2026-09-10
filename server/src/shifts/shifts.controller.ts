import {
  BadRequestException,
  Body,
  Controller,
  ForbiddenException,
  Get,
  HttpCode,
  Post,
  Query,
  Req,
  UseGuards,
  UseInterceptors,
} from '@nestjs/common';
import type { Request } from 'express';
import { RequireDeviceRole } from '../common/decorators/device-role.decorator.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { toSatang } from '../common/money.js';
import { IdempotencyInterceptor } from '../idempotency/idempotency.interceptor.js';
import {
  ShiftsService,
  type Actor,
  type DrawerEntry,
  type ShiftWithEntries,
} from './shifts.service.js';

interface AuthenticatedRequest extends Request {
  user: { userId: string; tenantId: string; deviceId?: string };
}

/** `?page=1&limit=50`, capped at 200 (02_API_SCREENS.md §1.1). */
const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 200;

@Controller('shifts')
@UseGuards(TenantGuard)
export class ShiftsController {
  constructor(private readonly shifts: ShiftsService) {}

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
  ): Promise<{ items: ShiftWithEntries[]; total: number; page: number; limit: number }> {
    const p = positiveInt(page, 1, 'page');
    const l = Math.min(positiveInt(limit, DEFAULT_LIMIT, 'limit'), MAX_LIMIT);
    const { items, total } = await this.shifts.history(p, l);
    return { items, total, page: p, limit: l };
  }

  @Post('open')
  @HttpCode(200)
  @RequireDeviceRole('pos')
  @UseInterceptors(IdempotencyInterceptor)
  open(@Body() body: unknown, @Req() req: AuthenticatedRequest): Promise<ShiftWithEntries> {
    const b = asObject(body);
    return this.shifts.open(actorOf(req), toSatang(b.startingCash ?? 0, 'startingCash'));
  }

  @Post('close')
  @HttpCode(200)
  @RequireDeviceRole('pos')
  @UseInterceptors(IdempotencyInterceptor)
  close(@Body() body: unknown, @Req() req: AuthenticatedRequest): Promise<ShiftWithEntries> {
    const b = asObject(body);
    return this.shifts.close(
      actorOf(req).deviceId,
      toSatang(b.physicalCash ?? 0, 'physicalCash'),
    );
  }

  @Post('current/entries')
  @RequireDeviceRole('pos')
  @UseInterceptors(IdempotencyInterceptor)
  addEntry(@Body() body: unknown, @Req() req: AuthenticatedRequest): Promise<DrawerEntry> {
    const b = asObject(body);
    if (b.type !== 'in' && b.type !== 'out') {
      throw new BadRequestException(`type must be 'in' or 'out'`);
    }
    const amountSatang = toSatang(b.amount, 'amount');
    if (amountSatang <= 0) throw new BadRequestException('amount must be greater than zero');
    const note = b.note === undefined || b.note === null ? null : String(b.note);
    return this.shifts.addEntry(actorOf(req), { type: b.type, amountSatang, note });
  }
}

/**
 * A `pos` token always carries `did` — the guard refuses these routes otherwise —
 * but `uq_shift_active` is keyed on the device, so a missing one would silently open
 * a shift nothing can find again.
 */
function actorOf(req: AuthenticatedRequest): Actor {
  if (!req.user.deviceId) {
    throw new ForbiddenException({
      code: 'DEVICE_ROLE_FORBIDDEN',
      message: 'เครื่องนี้ขายของไม่ได้',
    });
  }
  return { userId: req.user.userId, deviceId: req.user.deviceId };
}

function asObject(body: unknown): Record<string, unknown> {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    throw new BadRequestException('body must be an object');
  }
  return body as Record<string, unknown>;
}

function positiveInt(raw: string | undefined, fallback: number, field: string): number {
  if (raw === undefined) return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1) {
    throw new BadRequestException(`${field} must be a positive integer`);
  }
  return n;
}
