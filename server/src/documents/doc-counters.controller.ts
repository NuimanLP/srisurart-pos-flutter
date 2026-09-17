import { Controller, Get, Req, UseGuards } from '@nestjs/common';
import type { Request } from 'express';
import { RequireDeviceRole } from '../common/decorators/device-role.decorator.js';
import { DeviceRoleForbiddenException } from '../common/device-role-forbidden.exception.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { DocCountersService, type DocCounters } from './doc-counters.service.js';

interface AuthenticatedRequest extends Request {
  user: { deviceId?: string };
}

@Controller('doc-counters')
@UseGuards(TenantGuard)
export class DocCountersController {
  constructor(private readonly counters: DocCountersService) {}

  /**
   * `pos` only (02 §4, ADR-0007): only that device will issue RC/CN itself. The device is
   * the token's `did` — there is no query parameter, so no device can read another's series.
   */
  @Get()
  @RequireDeviceRole('pos')
  list(@Req() req: AuthenticatedRequest): Promise<DocCounters> {
    if (!req.user.deviceId) throw new DeviceRoleForbiddenException();
    return this.counters.forDevice(req.user.deviceId);
  }
}
