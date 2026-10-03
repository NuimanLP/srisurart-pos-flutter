import { Controller, Get, Param, Query, Req, UseGuards } from '@nestjs/common';
import type { Request } from 'express';
import { clientIp } from '../common/client-ip.js';
import { PlatformAuthGuard } from './platform-auth.guard.js';
import { PlatformAuditService } from './platform-audit.service.js';

interface AuthenticatedRequest extends Request {
  platformAdmin: { id: string; username: string };
}

@Controller('platform/tenants')
@UseGuards(PlatformAuthGuard)
export class PlatformAuditController {
  constructor(private readonly audit: PlatformAuditService) {}

  /** #443: one tenant's audit_log, newest first; `before` is the previous page's `nextCursor`. */
  @Get(':id/audit')
  async listTenantAudit(
    @Param('id') id: string,
    // `unknown`, not `string`: a repeated key arrives as an array; the service refuses it.
    @Query('before') before: unknown,
    @Query('limit') limit: unknown,
    @Req() req: AuthenticatedRequest,
  ) {
    return this.audit.listTenantAudit(
      id,
      { before, limit },
      req.platformAdmin.id,
      clientIp(req) ?? undefined,
    );
  }
}
