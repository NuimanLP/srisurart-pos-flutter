import {
  Injectable,
  type CallHandler,
  type ExecutionContext,
  type NestInterceptor,
} from '@nestjs/common';
import { catchError, concatMap, from, throwError, type Observable } from 'rxjs';
import type { QueryRunner } from 'typeorm';
import { currentRequestTransaction } from './request-context.js';

/**
 * Ends the transaction `RequestContextMiddleware` opened: commit on success,
 * rollback on error — **before** the response is sent, so a client that reads 201
 * is reading committed data.
 *
 * Bind it globally after `EnvelopeInterceptor` so it nests inside the envelope and
 * outside every route-scoped interceptor. `IdempotencyInterceptor` in particular
 * must run inside this one: its record has to commit in the same transaction as the
 * work it describes.
 */
@Injectable()
export class TransactionInterceptor implements NestInterceptor {
  intercept(_ctx: ExecutionContext, next: CallHandler): Observable<unknown> {
    const qr = currentRequestTransaction()?.queryRunner;
    if (!qr) return next.handle();

    return next.handle().pipe(
      concatMap(async (value) => {
        await end(qr, 'commit');
        return value;
      }),
      catchError((err: unknown) =>
        from(end(qr, 'rollback')).pipe(concatMap(() => throwError(() => err))),
      ),
    );
  }
}

/**
 * Commits or rolls back, then always returns the connection — a pool slot leaked
 * here is one fewer sale the instance can make for the rest of its life.
 */
async function end(qr: QueryRunner, how: 'commit' | 'rollback'): Promise<void> {
  try {
    if (qr.isTransactionActive) {
      if (how === 'commit') await qr.commitTransaction();
      else await qr.rollbackTransaction();
    }
  } finally {
    if (!qr.isReleased) await qr.release();
  }
}
