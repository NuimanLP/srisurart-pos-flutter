import {
  BadRequestException,
  Body,
  Controller,
  Get,
  HttpCode,
  Param,
  Post,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { clientIp } from '../common/client-ip.js';
import { DeviceRoleForbiddenException } from '../common/device-role-forbidden.exception.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { toSatang } from '../common/money.js';
import { idempotencyParamsOf } from '../idempotency/idempotency.runner.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import {
  DevicesService,
  type Device,
  type DeviceActor,
  type DeviceRole,
} from './devices.service.js';

interface AuthenticatedRequest extends Request {
  user: { userId: string; role?: string; deviceId?: string };
}

const LABEL_MAX_LENGTH = 100;

/**
 * `/devices` (ADR-0004 "การผูกเครื่อง", 02_API_SCREENS.md §4.2, F6). Enrolled device token
 * required (`did` in JWT — either `pos` or `backoffice`). A session without a device token is
 * refused with 403 DEVICE_ROLE_FORBIDDEN.
 */
@Controller('devices')
@UseGuards(TenantGuard)
export class DevicesController {
  constructor(
    private readonly devices: DevicesService,
    private readonly idempotency: IdempotencyService,
  ) {}

  @Get()
  list(@Req() req: AuthenticatedRequest): Promise<Device[]> {
    requireEnrolledDevice(req);
    return this.devices.list();
  }

  /**
   * `{label, role}` → `{device, enrolCode}`. The code is shown once to the owner and typed
   * into the new browser, which calls `POST /auth/device`. There is no `id` or `deviceNo` in
   * the body, ever — `did` comes from the server (ADR-0004).
   */
  @Post()
  create(
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<{ device: Device; enrolCode: string }> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 201),
      res,
      () => {
        requireEnrolledDevice(req);
        const b = asObject(body);
        if (typeof b.label !== 'string' || b.label.trim() === '') {
          throw new BadRequestException('label is required');
        }
        const label = b.label.trim();
        if (label.length > LABEL_MAX_LENGTH) {
          throw new BadRequestException(`label must be at most ${LABEL_MAX_LENGTH} characters`);
        }
        if (b.role !== 'pos' && b.role !== 'backoffice') {
          throw new BadRequestException(`role must be 'pos' or 'backoffice'`);
        }
        return this.devices.create(actorOf(req), { label, role: b.role as DeviceRole });
      },
    );
  }

  /**
   * `{physicalCash?}` — required only when the device still has an open drawer
   * (`409 PHYSICAL_CASH_REQUIRED` otherwise, answered from inside the transaction, since only
   * the locked shift row can say whether it is open).
   */
  @Post(':id/retire')
  @HttpCode(200)
  retire(
    @Param('id') id: string,
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ) {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () => {
        requireEnrolledDevice(req);
        const b = body === undefined || body === null ? {} : asObject(body);
        let physicalCash: number | null = null;
        if (b.physicalCash !== undefined && b.physicalCash !== null && b.physicalCash !== '') {
          physicalCash = toSatang(b.physicalCash, 'physicalCash');
          if (physicalCash < 0) throw new BadRequestException('physicalCash must not be negative');
        }

        if (b.force !== undefined && typeof b.force !== 'boolean') {
          throw new BadRequestException('force must be a boolean');
        }
        const force = b.force === true;
        let note: string | null = null;
        if (force) {
          if (typeof b.note !== 'string' || b.note.trim() === '') {
            throw new BadRequestException('note is required when force is true');
          }
          note = b.note.trim();
        }

        return this.devices.retire(actorOf(req), id, physicalCash, { force, note });
      },
    );
  }
}

function requireEnrolledDevice(req: AuthenticatedRequest): void {
  if (!req.user?.deviceId) {
    throw new DeviceRoleForbiddenException();
  }
}

function actorOf(req: AuthenticatedRequest): DeviceActor {
  return {
    userId: req.user.userId,
    deviceId: req.user.deviceId,
    ip: clientIp(req) ?? undefined,
  };
}

function asObject(body: unknown): Record<string, unknown> {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    throw new BadRequestException('body must be an object');
  }
  return body as Record<string, unknown>;
}
