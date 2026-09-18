import {
  Body,
  Controller,
  HttpCode,
  HttpStatus,
  Post,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { DeviceTokenGuard } from '../common/guards/device-token.guard.js';
import { TenantOrDeviceTokenGuard } from '../common/guards/tenant-or-device.guard.js';
import { idempotencyParamsOf } from '../idempotency/idempotency.runner.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import {
  parseSyncDiscard,
  parseSyncPush,
  type SyncPushResponse,
} from './sync.dto.js';
import { SyncService } from './sync.service.js';

interface DeviceAuthenticatedRequest extends Request {
  user: {
    userId: string;
    tenantId: string;
    role: string;
    deviceId: string;
    deviceRole: string;
  };
  device: {
    id: string;
    role: string;
  };
}

interface DiscardAuthenticatedRequest extends Request {
  user: {
    userId: string;
    tenantId: string;
    role?: string;
    deviceId?: string;
    deviceRole?: string;
  };
}

@Controller('sync')
export class SyncController {
  constructor(
    private readonly sync: SyncService,
    private readonly idempotency: IdempotencyService,
  ) {}

  @Post('push')
  @HttpCode(HttpStatus.OK)
  @UseGuards(DeviceTokenGuard)
  async push(
    @Body() body: unknown,
    @Req() req: DeviceAuthenticatedRequest,
  ): Promise<SyncPushResponse> {
    const dto = parseSyncPush(body);
    const actor = {
      userId: req.user.userId,
      tenantId: req.user.tenantId,
      deviceId: req.user.deviceId,
    };
    const device = {
      id: req.device.id,
      role: req.device.role,
    };

    return this.sync.processPush(actor, device, dto);
  }

  @Post('discards')
  @HttpCode(200)
  @UseGuards(TenantOrDeviceTokenGuard)
  discard(
    @Body() body: unknown,
    @Req() req: DiscardAuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<{ serverHasRow: boolean }> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () => {
        const dto = parseSyncDiscard(body);
        const actor = {
          userId: req.user.userId,
          tenantId: req.user.tenantId,
          deviceId: req.user.deviceId,
          ip: req.ip,
        };
        return this.sync.discardOp(actor, dto);
      },
    );
  }
}
