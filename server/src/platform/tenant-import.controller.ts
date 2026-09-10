import {
  Body,
  Controller,
  Param,
  Post,
  Req,
  UseGuards,
} from '@nestjs/common';
import type { Request } from 'express';
import { PlatformAuthGuard } from './platform-auth.guard.js';
import {
  SnapshotPayload,
  TenantImportService,
} from './tenant-import.service.js';

interface AuthenticatedRequest extends Request {
  platformAdmin: {
    id: string;
    username: string;
  };
}

@Controller('platform/tenants')
@UseGuards(PlatformAuthGuard)
export class TenantImportController {
  constructor(private readonly importService: TenantImportService) {}

  @Post(':id/import')
  async importSnapshot(
    @Param('id') id: string,
    @Body() body: SnapshotPayload,
    @Req() req: AuthenticatedRequest,
  ) {
    const ip = (req.headers['x-forwarded-for'] as string) || req.ip;
    return this.importService.importSnapshot(
      id,
      body,
      req.platformAdmin.id,
      ip,
    );
  }
}
