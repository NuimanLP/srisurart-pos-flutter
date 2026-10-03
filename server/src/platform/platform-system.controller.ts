import { Controller, Get, Req, UseGuards } from '@nestjs/common';
import type { Request } from 'express';
import { clientIp } from '../common/client-ip.js';
import { PlatformAuthGuard } from './platform-auth.guard.js';
import { PlatformSystemService } from './platform-system.service.js';

interface AuthenticatedRequest extends Request {
  platformAdmin: { id: string; username: string };
}

@Controller('platform/system')
@UseGuards(PlatformAuthGuard)
export class PlatformSystemController {
  constructor(private readonly system: PlatformSystemService) {}

  /** #443: deployed SHA, readiness, queue counts, honest backup status. Always 200. */
  @Get()
  async status(@Req() req: AuthenticatedRequest) {
    return this.system.status(req.platformAdmin.id, clientIp(req) ?? undefined);
  }
}
