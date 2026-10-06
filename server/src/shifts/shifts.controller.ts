import {
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
import { idempotencyParamsOf } from '../idempotency/idempotency.runner.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import { Paginated, pageParams } from '../common/paginated.js';
import { asObject, cash, parseDrawerEntry, parseShiftOpen } from './shifts.dto.js';
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
        // No `openedAt`/`createdAt` online (here or in `addEntry`): the server's `now()`
        // dates both; only `/sync/push` passes a device time (08 §10, #411).
        return this.shifts.open(actorOf(req), parseShiftOpen(body));
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
        return this.shifts.addEntry(actorOf(req), parseDrawerEntry(body));
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
