import { Inject, Injectable, type NestMiddleware } from '@nestjs/common';
import type { NextFunction, Request, Response } from 'express';
import type { Logger } from 'pino';
import { DataSource, type QueryRunner } from 'typeorm';
import { LOGGER } from '../infra/logger.provider.js';
import { toErrorEnvelope } from './http-exception.filter.js';
import { runInRequestContext } from './request-context.js';

/** Set by `TransactionInterceptor` once it will end the transaction itself. */
export const OWNED_BY_INTERCEPTOR = 'ownedByTransactionInterceptor';

/**
 * Opens the request's transaction and publishes it as the request context
 * (`request-context.ts` explains the three-stage split this is the first stage of).
 *
 * It deliberately does NOT look at the token: the tenant is `TenantGuard`'s to
 * decide (ADR-0003), and this stage runs before guards do. Until the guard names a
 * tenant the transaction has no `app.tenant_id`, so RLS shows it nothing — which is
 * exactly the fail-closed behaviour we want if a route forgets the guard.
 *
 * `TransactionInterceptor` ends the transaction on every path that reaches the
 * handler. The response's own end is the backstop for the one path that does not:
 * a guard that throws, which happens before any interceptor runs.
 */
@Injectable()
export class RequestContextMiddleware implements NestMiddleware {
  constructor(
    private readonly ds: DataSource,
    @Inject(LOGGER) private readonly logger: Logger,
  ) {}

  async use(req: Request, res: Response, next: NextFunction): Promise<void> {
    const qr = this.ds.createQueryRunner();

    // Registered before anything can fail. `connect()` has already taken a client out
    // of the pool by the time `startTransaction()` runs, so a listener added after the
    // try block would miss that window — and a connection leaked there is leaked for
    // the life of the process: one Postgres failover would drain the pool to zero.
    res.on('close', () => {
      // Only the path the interceptor never reached. Nest does not cancel a handler
      // when the client disconnects, so on a mid-sale abort this fires while the
      // handler is still issuing statements; rolling back and releasing underneath it
      // would hand a live query queue to whichever request takes that connection next.
      if (qr.data[OWNED_BY_INTERCEPTOR]) return;
      void endIfOpen(qr);
    });

    try {
      await qr.connect();
      await qr.startTransaction();
    } catch (err) {
      this.logger.error(
        { correlationId: (req as Request & { id?: string }).id, err },
        'could not open the request transaction',
      );
      await endIfOpen(qr);
      // 🔴 Express does not await a middleware's promise, so this must never reject:
      // an unhandled rejection is a killed worker, not a failed request.
      const { status, body } = toErrorEnvelope(err);
      res.status(status).json(body);
      return;
    }

    await runInRequestContext({ manager: qr.manager }, async () => {
      next();
    });
  }
}

/**
 * Rolls back and releases a transaction nothing else will. Releasing twice is not an
 * error we can do anything about, so it is swallowed rather than crashing the process
 * from an event handler with no request to fail.
 */
async function endIfOpen(qr: QueryRunner): Promise<void> {
  try {
    if (qr.isTransactionActive) await qr.rollbackTransaction();
  } catch {
    /* already ended */
  }
  try {
    if (!qr.isReleased) await qr.release();
  } catch {
    /* already released */
  }
}
