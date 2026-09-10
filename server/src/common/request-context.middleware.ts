import { Injectable, type NestMiddleware } from '@nestjs/common';
import type { NextFunction, Request, Response } from 'express';
import { DataSource, type QueryRunner } from 'typeorm';
import { runInRequestContext } from './request-context.js';

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
 * handler. A guard that throws never reaches an interceptor, so the response's own
 * end is the backstop that rolls back and returns the connection to the pool.
 */
@Injectable()
export class RequestContextMiddleware implements NestMiddleware {
  constructor(private readonly ds: DataSource) {}

  async use(req: Request, res: Response, next: NextFunction): Promise<void> {
    const qr = this.ds.createQueryRunner();
    await qr.connect();
    await qr.startTransaction();

    res.on('close', () => {
      void endIfOpen(qr);
    });

    await runInRequestContext({ manager: qr.manager }, async () => {
      next();
    });
  }
}

/**
 * Rolls back and releases a transaction the interceptor never got to — a guard
 * threw, or the client hung up mid-request. Releasing twice is not an error we can
 * do anything about, so it is swallowed rather than crashing the process from an
 * event handler with no request to fail.
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
