import {
  Body,
  Controller,
  Get,
  Param,
  Patch,
  Post,
  Req,
  UseGuards,
} from '@nestjs/common';
import type { Request } from 'express';
import { PlatformAuthGuard } from './platform-auth.guard.js';
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
    const ip = (req.headers['x-forwarded-for'] as string) || req.ip;
    return this.tenantsService.createTenant(dto, req.platformAdmin.id, ip);
  }

  @Patch(':id/status')
  async updateStatus(
    @Param('id') id: string,
    @Body() body: { status: 'active' | 'suspended' | 'closed' },
    @Req() req: AuthenticatedRequest,
  ) {
    const ip = (req.headers['x-forwarded-for'] as string) || req.ip;
    return this.tenantsService.updateStatus(
      id,
      body.status,
      req.platformAdmin.id,
      ip,
    );
  }

  @Get()
  async listTenants(@Req() req: AuthenticatedRequest) {
    const ip = (req.headers['x-forwarded-for'] as string) || req.ip;
    return this.tenantsService.listTenants(req.platformAdmin.id, ip);
  }
}
