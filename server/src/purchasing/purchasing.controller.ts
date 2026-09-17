import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  Post,
  Query,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { idempotencyParamsOf } from '../idempotency/idempotency.runner.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import {
  PurchaseOrderOut,
  ReceivePOResult,
} from './purchasing.dto.js';
import { PurchasingService } from './purchasing.service.js';

interface AuthenticatedRequest extends Request {
  user: {
    userId: string;
    tenantId: string;
    role?: string;
    deviceId?: string;
    deviceRole?: string;
  };
}


function extractActor(req: AuthenticatedRequest): { userId: string; deviceId: string } {
  return {
    userId: req.user?.userId || 'system',
    deviceId: req.user?.deviceId || 'dev1',
  };
}

@Controller('purchase-orders')
@UseGuards(TenantGuard)
export class PurchasingController {
  constructor(
    private readonly purchasingService: PurchasingService,
    private readonly idempotency: IdempotencyService,
  ) {}

  @Get()
  list(
    @Query('status') status?: string,
    @Query('page') pageRaw?: string,
    @Query('limit') limitRaw?: string,
  ): Promise<{ items: PurchaseOrderOut[]; total: number }> {
    const page = pageRaw ? parseInt(pageRaw, 10) || 1 : 1;
    const limit = limitRaw ? parseInt(limitRaw, 10) || 50 : 50;
    return this.purchasingService.list(status, page, limit);
  }

  @Get(':id')
  byId(@Param('id') id: string): Promise<PurchaseOrderOut> {
    return this.purchasingService.byId(id);
  }

  @Post()
  create(
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
  ): Promise<PurchaseOrderOut> {
    const actor = extractActor(req);
    return this.purchasingService.create(body, actor);
  }

  @Post(':id/receive')
  receive(
    @Param('id') id: string,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<ReceivePOResult> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 201),
      res,
      () => {
        const actor = extractActor(req);
        return this.purchasingService.receive(id, actor);
      },
    );
  }

  @Post(':id/cancel')
  cancel(
    @Param('id') id: string,
    @Req() req: AuthenticatedRequest,
  ): Promise<PurchaseOrderOut> {
    const actor = extractActor(req);
    return this.purchasingService.cancel(id, actor);
  }

  @Delete(':id')
  delete(
    @Param('id') id: string,
    @Req() req: AuthenticatedRequest,
  ): Promise<{ id: string; deleted: boolean }> {
    const actor = extractActor(req);
    return this.purchasingService.delete(id, actor);
  }
}
