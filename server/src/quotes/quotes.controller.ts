import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Patch,
  Post,
  Query,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { InjectQueue } from '@nestjs/bullmq';
import { Queue } from 'bullmq';
import { RequireDeviceRole } from '../common/decorators/device-role.decorator.js';
import { DeviceRoleForbiddenException } from '../common/device-role-forbidden.exception.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { currentRequestContext } from '../common/request-context.js';
import { TenantService } from '../common/database/tenant.service.js';
import { newId } from '../common/ids.js';
import { Paginated, pageParams } from '../common/paginated.js';
import { idempotencyParamsOf } from '../idempotency/idempotency.runner.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import { isoDate } from '../people/people.dto.js';
import {
  JOB_QUOTES_PURGE,
  QUEUE_MAINTENANCE,
  type QuotesPurgeJobPayload,
} from '../queue/queue.constants.js';
import {
  parseQuoteConvert,
  parseQuoteCreate,
  parseQuoteFilter,
  parseQuotePatch,
  parsePurgeOlderThanDays,
} from './quotes.dto.js';
import {
  QuotesService,
  type ConvertQuoteResult,
  type Quote,
} from './quotes.service.js';

interface AuthenticatedRequest extends Request {
  user?: {
    userId?: string;
    tenantId?: string;
    role?: string;
    deviceId?: string;
    deviceRole?: string;
  };
}

/**
 * Quotes (#27). Reads and edits are both device roles (ADR-0004: a quote touches
 * neither stock nor money); convert is `pos` only, because it rings up a bill.
 * Every write goes through `IdempotencyService.runIdempotent` (02_API_SCREENS.md §4).
 */
@Controller('quotes')
@UseGuards(TenantGuard)
export class QuotesController {
  constructor(
    @InjectQueue(QUEUE_MAINTENANCE) private readonly maintenanceQueue: Queue,
    private readonly quotes: QuotesService,
    private readonly tenants: TenantService,
    private readonly idempotency: IdempotencyService,
  ) {}

  @Get()
  async list(
    @Query('status') status?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('page') page?: string,
    @Query('limit') limit?: string,
  ): Promise<Paginated<Quote>> {
    const parsed = pageParams(page, limit);
    const { items, total } = await this.quotes.list({
      status: parseQuoteFilter(status),
      from: isoDate(from, 'from'),
      to: isoDate(to, 'to'),
      ...parsed,
    });
    return new Paginated(items, { total, ...parsed });
  }

  @Post('purge')
  @HttpCode(HttpStatus.ACCEPTED)
  purgeQuotes(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
    @Res({ passthrough: true }) res: Response,
  ) {
    return this.tenants.runTx(() => this.purgeQuotesIn(req, body, res));
  }

  private purgeQuotesIn(
    req: AuthenticatedRequest,
    body: unknown,
    res: Response,
  ) {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, HttpStatus.ACCEPTED),
      res,
      async () => {
        const { tenantId } = currentRequestContext();
        const olderThanDays = parsePurgeOlderThanDays(body);
        const correlationId = newId('quote_');
        const idemKey = req.headers['idempotency-key'];
        const jobIdKey = idemKey
          ? (Array.isArray(idemKey) ? idemKey[0] : idemKey)
          : new Date().toISOString().slice(0, 10);

        const job = await this.maintenanceQueue.add(
          JOB_QUOTES_PURGE,
          {
            tenantId,
            correlationId,
            olderThanDays,
          } satisfies QuotesPurgeJobPayload,
          {
            jobId: `quotes-purge:${tenantId}:${jobIdKey}`,
          },
        );

        return {
          queued: true,
          jobId: job.id,
          olderThanDays,
        };
      },
    );
  }

  @Get(':id')
  byId(@Param('id') id: string): Promise<Quote> {
    return this.quotes.byId(id);
  }

  @Post()
  create(
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Quote> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 201),
      res,
      () => {
        return this.quotes.create(parseQuoteCreate(body), deviceIdOf(req));
      },
    );
  }

  @Patch(':id')
  update(
    @Param('id') id: string,
    @Body() body: unknown,
    @Req() req: Request,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Quote> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () => {
        return this.quotes.update(id, parseQuotePatch(body));
      },
    );
  }

  @Delete(':id')
  delete(
    @Param('id') id: string,
    @Req() req: Request,
    @Res({ passthrough: true }) res: Response,
  ): Promise<{ id: string; deleted: true }> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 200),
      res,
      () => {
        return this.quotes.delete(id);
      },
    );
  }

  @Post(':id/duplicate')
  duplicate(
    @Param('id') id: string,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Quote> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 201),
      res,
      () => {
        return this.quotes.duplicate(id, deviceIdOf(req));
      },
    );
  }

  @Post(':id/convert')
  @RequireDeviceRole('pos')
  convert(
    @Param('id') id: string,
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<ConvertQuoteResult> {
    return this.idempotency.runIdempotent(
      idempotencyParamsOf(req, 201),
      res,
      () => {
        const deviceId = deviceIdOf(req);
        return this.quotes.convert(id, parseQuoteConvert(body), {
          userId: req.user!.userId!,
          deviceId,
        });
      },
    );
  }
}

/**
 * The QT (and, on convert, RC) number is issued in the token's device series
 * (ADR-0007), so a session with no device token cannot issue one.
 */
function deviceIdOf(req: AuthenticatedRequest): string {
  const deviceId = req.user?.deviceId;
  if (!deviceId) throw new DeviceRoleForbiddenException();
  return deviceId;
}
