import {
  NotFoundException,
  RequestMethod,
  type INestApplication,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import type { Logger } from 'pino';
import { EnvelopeInterceptor } from './common/envelope.interceptor.js';
import {
  HttpExceptionFilter,
  toErrorEnvelope,
} from './common/http-exception.filter.js';
import { requestLogger } from './common/logger.js';
import { TransactionInterceptor } from './common/transaction.interceptor.js';

/** Everything main.ts and the e2e tests must configure identically. */
export async function configureApp(
  app: INestApplication,
  logger: Logger,
): Promise<void> {
  app.getHttpAdapter().getInstance().disable('x-powered-by');
  app.use(requestLogger(logger));
  app.setGlobalPrefix('api/v1', {
    exclude: [
      { path: 'health/live', method: RequestMethod.GET },
      { path: 'health/ready', method: RequestMethod.GET },
    ],
  });
  // Order matters: the envelope wraps whatever comes back, the transaction ends
  // inside it, and every route-scoped interceptor (IdempotencyInterceptor above all)
  // runs inside the transaction — its record must commit with the work it describes.
  app.useGlobalInterceptors(new EnvelopeInterceptor(), new TransactionInterceptor());
  app.useGlobalFilters(new HttpExceptionFilter(logger));
  app.enableShutdownHooks();
  await app.init();

  // Nest mounts its own 404 handler only under the global prefix; anything
  // else would fall through to the Express HTML page. Keep the envelope everywhere.
  app
    .getHttpAdapter()
    .getInstance()
    .use((req: Request, res: Response) => {
      const { status, body } = toErrorEnvelope(
        new NotFoundException(`Cannot ${req.method} ${req.originalUrl}`),
      );
      res.status(status).json(body);
    });
}
