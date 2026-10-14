import {
  Body,
  Controller,
  Delete,
  Get,
  HttpException,
  HttpStatus,
  Param,
  Patch,
  Post,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import type { JwtVerifier } from '../auth/jwt-keys.service.js';
import { clientIp } from '../common/client-ip.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { ParseUuidPipe } from '../common/parse-uuid.pipe.js';
import { idempotencyParamsOf } from '../idempotency/idempotency.runner.js';
import { IdempotencyService } from '../idempotency/idempotency.service.js';
import {
  parsePaymentAccountCreate,
  parsePaymentAccountPatch,
  type PaymentAccount,
} from './payment-accounts.dto.js';
import { PaymentAccountsService, type PaymentAccountActor } from './payment-accounts.service.js';

/** `/payment-accounts` as Express sees it under the global prefix (`app.setup.ts`). */
export const PAYMENT_ACCOUNTS_ROUTE = '/api/v1/payment-accounts';
/** An image of ≤ 300 KB is ≈ 400 KB of base64 — past Nest's own 100 KiB JSON parser. */
export const PAYMENT_ACCOUNTS_BODY_LIMIT = '1mb';

interface AuthenticatedRequest extends Request {
  user?: { userId?: string; role?: string; deviceId?: string };
}

/**
 * The shop's QR payment accounts (contract §2). Anyone signed in to the shop reads them (the
 * till needs them at checkout); only `role = 'owner'` writes. No enrolled device is required:
 * these are settings, like `PATCH /settings`, not one of the device-bound actions 08 names
 * (retire / enrol / export / import).
 *
 * Every write claims its `Idempotency-Key` first; the owner check is the first statement of
 * the claimed work, as `DevicesController` does — a refusal rolls the claim back with it.
 */
@Controller('payment-accounts')
@UseGuards(TenantGuard)
export class PaymentAccountsController {
  constructor(
    private readonly accounts: PaymentAccountsService,
    private readonly idempotency: IdempotencyService,
  ) {}

  @Get()
  list(): Promise<PaymentAccount[]> {
    return this.accounts.list();
  }

  @Post()
  create(
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<PaymentAccount> {
    return this.idempotency.runIdempotent(idempotencyParamsOf(req, 201), res, () => {
      requireOwner(req);
      return this.accounts.create(actorOf(req), parsePaymentAccountCreate(body));
    });
  }

  @Patch(':id')
  update(
    @Param('id', ParseUuidPipe) id: string,
    @Body() body: unknown,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<PaymentAccount> {
    return this.idempotency.runIdempotent(idempotencyParamsOf(req, 200), res, () => {
      requireOwner(req);
      return this.accounts.update(actorOf(req), id, parsePaymentAccountPatch(body));
    });
  }

  @Delete(':id')
  delete(
    @Param('id', ParseUuidPipe) id: string,
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<PaymentAccount & { deletedAt: string }> {
    return this.idempotency.runIdempotent(idempotencyParamsOf(req, 200), res, () => {
      requireOwner(req);
      return this.accounts.remove(actorOf(req), id);
    });
  }
}

/** For the audit row: who wrote, from the token, never from the body. */
function actorOf(req: AuthenticatedRequest): PaymentAccountActor {
  return {
    userId: req.user?.userId,
    deviceId: req.user?.deviceId,
    ip: clientIp(req) ?? undefined,
  };
}

/**
 * `403 OWNER_ONLY`. A new code rather than the generic `FORBIDDEN`: that one also means "bad
 * token audience" / "tenant not found" and carries no Thai string (02 §8), while the counter
 * must tell a non-owner exactly why the Save button did nothing.
 */
function requireOwner(req: AuthenticatedRequest): void {
  if (req.user?.role !== 'owner') {
    throw new HttpException(
      { code: 'OWNER_ONLY', message: 'เฉพาะเจ้าของร้านเท่านั้นที่แก้ไขบัญชีรับเงินได้' },
      HttpStatus.FORBIDDEN,
    );
  }
}

/**
 * `app.setup.ts`: only a request this predicate accepts earns the 1 MB body parser on
 * {@link PAYMENT_ACCOUNTS_ROUTE} — a verified tenant access token of an owner, the claims
 * `TenantGuard` + `requireOwner` check. Anyone else falls through to Nest's 100 KiB parser,
 * so nobody may make the API buffer 1 MB before the guard has looked at the token.
 */
export function ownerTokenFromHeader(header: unknown, verifier: JwtVerifier): boolean {
  if (typeof header !== 'string' || !header.startsWith('Bearer ')) return false;
  try {
    const p = verifier.verify(header.substring(7), 'access');
    return p.aud === 'tenant' && p.role === 'owner' && !!p.tid;
  } catch {
    return false;
  }
}
