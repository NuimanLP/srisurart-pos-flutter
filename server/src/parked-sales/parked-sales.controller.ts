import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  Param,
  Post,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { RequireDeviceRole } from '../common/decorators/device-role.decorator.js';
import { DeviceRoleForbiddenException } from '../common/device-role-forbidden.exception.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { ParseUuidPipe } from '../common/parse-uuid.pipe.js';
import { idempotencyParamsOf } from '../idempotency/idempotency.runner.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import {
  ParkedSalesService,
  parseParkBody,
  type ParkedSale,
} from './parked-sales.service.js';

interface AuthenticatedRequest extends Request {
  user: { userId: string; deviceId?: string };
}

/**
 * `pos` only, reads included (02_API_SCREENS.md §4; ADR-0004, settled 2026-09-04:
 * "อะไรก็ตามที่เกี่ยวกับบิล ทำที่เครื่องขาย").
 */
@Controller('parked-sales')
@UseGuards(TenantGuard)
@RequireDeviceRole('pos')
export class ParkedSalesController {
  constructor(
    private readonly parked: ParkedSalesService,
    private readonly idempotency: IdempotencyService,
  ) {}

  @Get()
  list(): Promise<ParkedSale[]> {
    return this.parked.list();
  }

  @Post()
  park(
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<ParkedSale> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 201),
      res,
      () => {
        if (!req.user.deviceId) throw new DeviceRoleForbiddenException();
        return this.parked.park(parseParkBody(body), req.user.deviceId);
      },
    );
  }

  @Delete(':id')
  @HttpCode(200)
  remove(
    @Param('id', ParseUuidPipe) id: string,
    @Req() req: Request,
    @Res({ passthrough: true }) res: Response,
  ): Promise<ParkedSale> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () => {
        return this.parked.remove(id);
      },
    );
  }
}
