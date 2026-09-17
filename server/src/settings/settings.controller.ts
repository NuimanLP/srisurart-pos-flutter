import {
  Body,
  Controller,
  Get,
  Patch,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { idempotencyParamsOf } from '../idempotency/idempotency.runner.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import { parseSettingsPatch, type Settings } from './settings.dto.js';
import { SettingsService } from './settings.service.js';

interface AuthenticatedRequest extends Request {
  user?: { role?: string };
}

@Controller('settings')
@UseGuards(TenantGuard)
export class SettingsController {
  constructor(
    private readonly settingsService: SettingsService,
    private readonly idempotency: IdempotencyService,
  ) {}

  @Get()
  async getSettings(@Res({ passthrough: true }) res: Response): Promise<Settings> {
    const result = await this.settingsService.getSettingsCached();
    res.setHeader('X-Cache', result.fromCache ? 'HIT' : 'MISS');
    return result.settings;
  }

  @Patch()
  updateSettings(
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Settings> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () => this.settingsService.updateSettings(parseSettingsPatch(body)),
    );
  }
}
