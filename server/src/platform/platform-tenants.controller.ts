import {
  Body,
  Controller,
  Get,
  HttpCode,
  Param,
  Patch,
  Post,
  Req,
  UseGuards,
} from '@nestjs/common';
import type { Request } from 'express';
import { PlatformAuthGuard } from './platform-auth.guard.js';
import { clientIp } from '../common/client-ip.js';
import {
  CreateTenantDto,
  PlatformTenantsService,
} from './platform-tenants.service.js';

interface AuthenticatedRequest extends Request {
  platformAdmin: {
    id: string;
    username: string;
  };
}

@Controller('platform/tenants')
@UseGuards(PlatformAuthGuard)
export class PlatformTenantsController {
  constructor(private readonly tenantsService: PlatformTenantsService) {}

  @Post()
  async createTenant(
    @Body() dto: CreateTenantDto,
    @Req() req: AuthenticatedRequest,
  ) {
    const ip = clientIp(req) ?? undefined;
    return this.tenantsService.createTenant(dto, req.platformAdmin.id, ip);
  }

  @Patch(':id/status')
  async updateStatus(
    @Param('id') id: string,
    @Body() body: { status: 'active' | 'suspended' | 'closed' },
    @Req() req: AuthenticatedRequest,
  ) {
    const ip = clientIp(req) ?? undefined;
    return this.tenantsService.updateStatus(
      id,
      body.status,
      req.platformAdmin.id,
      ip,
    );
  }

  @Get()
  async listTenants(@Req() req: AuthenticatedRequest) {
    const ip = clientIp(req) ?? undefined;
    return this.tenantsService.listTenants(req.platformAdmin.id, ip);
  }

  /** #443 PR2: a new one-time code for a device that has never been enrolled. */
  @Post(':id/devices/:deviceId/enrol-code')
  @HttpCode(200)
  async reissueEnrolCode(
    @Param('id') id: string,
    @Param('deviceId') deviceId: string,
    @Req() req: AuthenticatedRequest,
  ) {
    const ip = clientIp(req) ?? undefined;
    return this.tenantsService.reissueEnrolCode(id, deviceId, req.platformAdmin.id, ip);
  }

  /**
   * #476: retire a lost enrolled device and create its replacement (new `device_no`), for a
   * shop with no enrolled browser left. Body `{force?, note?, label?}`.
   */
  @Post(':id/devices/:deviceId/replace')
  @HttpCode(200)
  async replaceDevice(
    @Param('id') id: string,
    @Param('deviceId') deviceId: string,
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
  ) {
    const ip = clientIp(req) ?? undefined;
    const input =
      typeof body === 'object' && body !== null && !Array.isArray(body)
        ? (body as Record<string, unknown>)
        : {};
    return this.tenantsService.replaceDevice(id, deviceId, input, req.platformAdmin.id, ip);
  }

  /** #443 PR3: forgotten owner password → a new 24 h temporary one; the old one dies now. */
  @Post(':id/owner/temp-password')
  @HttpCode(200)
  async issueOwnerTempPassword(@Param('id') id: string, @Req() req: AuthenticatedRequest) {
    const ip = clientIp(req) ?? undefined;
    return this.tenantsService.issueOwnerTempPassword(id, req.platformAdmin.id, ip);
  }

  /** #443 PR2: tenant + its devices (no secrets/hashes) + its recent import jobs. */
  @Get(':id')
  async getTenantDetail(@Param('id') id: string, @Req() req: AuthenticatedRequest) {
    const ip = clientIp(req) ?? undefined;
    return this.tenantsService.getTenantDetail(id, req.platformAdmin.id, ip);
  }
}
