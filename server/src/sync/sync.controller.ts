import {
  Body,
  Controller,
  HttpCode,
  HttpStatus,
  Post,
  Req,
  UseGuards,
} from '@nestjs/common';
import type { Request } from 'express';
import { DeviceTokenGuard } from '../common/guards/device-token.guard.js';
import { parseSyncPush, type SyncPushResponse } from './sync.dto.js';
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

@Controller('sync')
@UseGuards(DeviceTokenGuard)
export class SyncController {
  constructor(private readonly sync: SyncService) {}

  @Post('push')
  @HttpCode(HttpStatus.OK)
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
}
