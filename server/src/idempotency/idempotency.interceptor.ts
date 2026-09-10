import {
  BadRequestException,
  ConflictException,
  Injectable,
  type CallHandler,
  type ExecutionContext,
  type NestInterceptor,
} from '@nestjs/common';
import { HTTP_CODE_METADATA } from '@nestjs/common/constants';
import { Reflector } from '@nestjs/core';
import type { Request, Response } from 'express';
import { concatMap, of, type Observable } from 'rxjs';
import { currentRequestContext } from '../common/request-context.js';
import {
  IdempotencyService,
  IDEMPOTENCY_KEY_HEADER,
  IDEMPOTENCY_KEY_MAX_LENGTH,
} from './idempotency.service.js';

/**
 * Makes a write endpoint idempotent (02_API_SCREENS.md §1.4 — mandatory on every
 * write that touches money or stock).
 *
 * Apply it per route or controller, never globally: it must run INSIDE the request
 * transaction (see `common/request-context.ts` for who opens it), and a globally
 * bound copy would also wrap routes that have no tenant and no key at all.
 *
 * The success envelope is added by the global `EnvelopeInterceptor`, which sits
 * outside this one, so what is stored and replayed is the handler's own return
 * value and the envelope is re-applied to a replay exactly as to the original.
 * A replay is equal to the original as JSON, not byte for byte: `response_body` is
 * `jsonb`, which does not preserve object key order. Nothing may depend on the bytes.
 */
@Injectable()
export class IdempotencyInterceptor implements NestInterceptor {
  constructor(
    private readonly idempotency: IdempotencyService,
    private readonly reflector: Reflector,
  ) {}

  async intercept(
    context: ExecutionContext,
    next: CallHandler,
  ): Promise<Observable<unknown>> {
    const http = context.switchToHttp();
    const req = http.getRequest<Request>();

    // The docs make the header mandatory here (02_API_SCREENS.md §1.4) but never say
    // what an unusable one returns. Refusing is the only safe reading — a write that
    // silently ran without a key cannot be retried without double-charging — and the
    // length bound keeps an oversized key a 400 rather than a btree failure at 500.
    const key = req.header(IDEMPOTENCY_KEY_HEADER)?.trim();
    if (!key || key.length > IDEMPOTENCY_KEY_MAX_LENGTH) {
      throw new BadRequestException({
        code: 'IDEMPOTENCY_KEY_INVALID',
        message: key
          ? `Header ${IDEMPOTENCY_KEY_HEADER} must be at most ${IDEMPOTENCY_KEY_MAX_LENGTH} characters`
          : `Header ${IDEMPOTENCY_KEY_HEADER} is required on this endpoint`,
      });
    }

    const { tenantId, manager } = currentRequestContext();
    // The CONCRETE target, not `req.route.path`: that is the route pattern, so every
    // bill sent to `POST /sales/:id/void` — whose whole body is `{pin}` — would share
    // one fingerprint, and a reused key would replay the first bill's receipt while
    // the bill the clerk meant to void stayed live. The path parameter identifies
    // what is being written, so it belongs in `endpoint` (what was addressed) rather
    // than in `request_hash`, which `01_DATABASE.md` defines as the hash of the body.
    const endpoint = `${req.method} ${req.baseUrl}${req.path}`;
    const requestHash = IdempotencyService.requestHash(req.body);

    const claim = await this.idempotency.claim(manager, {
      tenantId,
      key,
      endpoint,
      requestHash,
    });

    if (claim.outcome === 'reused') {
      throw new ConflictException({
        code: 'IDEMPOTENCY_KEY_REUSED',
        message: 'Idempotency-Key already used for a different request',
      });
    }

    if (claim.outcome === 'replay') {
      http.getResponse<Response>().status(claim.response.code);
      return of(claim.response.body);
    }

    const code = this.successStatus(context, req);
    return next.handle().pipe(
      concatMap(async (body) => {
        // Inside the caller's transaction, so the record and the work it describes
        // commit together or not at all.
        await this.idempotency.complete(manager, {
          tenantId,
          key,
          response: { code, body },
        });
        return body;
      }),
    );
  }

  /**
   * The status Nest will send for this route — `@HttpCode`, else 201 for POST — read
   * the same way Nest reads it, so the stored code is the one the original answered
   * with. `??`, not a truthiness test, because Nest's own rule is `?? byMethod`.
   */
  private successStatus(context: ExecutionContext, req: Request): number {
    const declared = this.reflector.get<number | undefined>(
      HTTP_CODE_METADATA,
      context.getHandler(),
    );
    return declared ?? (req.method === 'POST' ? 201 : 200);
  }
}
