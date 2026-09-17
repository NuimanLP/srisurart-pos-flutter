import {
  Controller,
  Get,
  HttpCode,
  Param,
  Post,
  Query,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { Paginated, pageParams } from '../common/paginated.js';
import { idempotencyParamsOf } from '../idempotency/idempotency.runner.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import {
  parseReviewItemStatus,
  type ReviewItem,
} from './review-items.dto.js';
import { ReviewItemsService } from './review-items.service.js';

interface AuthenticatedRequest extends Request {
  user: {
    userId: string;
    tenantId: string;
    role?: string;
    deviceId?: string;
    deviceRole?: string;
  };
}

@Controller('review-items')
@UseGuards(TenantGuard)
export class ReviewItemsController {
  constructor(
    private readonly reviewItems: ReviewItemsService,
    private readonly idempotency: IdempotencyService,
  ) {}

  @Get()
  list(
    @Query('status') status?: string,
    @Query('page') page?: string,
    @Query('limit') limit?: string,
  ): Promise<Paginated<ReviewItem>> {
    const parsedStatus = parseReviewItemStatus(status);
    const { page: p, limit: l } = pageParams(page, limit);
    return this.reviewItems.list(parsedStatus, p, l);
  }

  @Post(':id/reviewed')
  @HttpCode(200)
  markReviewed(
    @Param('id') id: string,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<ReviewItem> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () =>
        this.reviewItems.markReviewed(id, {
          userId: req.user.userId,
          ip: req.ip,
        }),
    );
  }
}
