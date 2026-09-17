import {
  NotFoundException,
  RequestMethod,
  type INestApplication,
} from '@nestjs/common';
import { json, type NextFunction, type Request, type Response } from 'express';
import type { Logger } from 'pino';
import helmet from 'helmet';
import { EnvelopeInterceptor } from './common/envelope.interceptor.js';
import {
  HttpExceptionFilter,
  toErrorEnvelope,
} from './common/http-exception.filter.js';
import { requestLogger } from './common/logger.js';
import { APP_CONFIG, type AppConfig } from './config/config.js';
import { platformTokenFromHeader } from './platform/platform-auth.guard.js';

/** `POST /platform/tenants/:id/import` (ADR-0005), as Express sees it under the global prefix. */
export const IMPORT_ROUTE = '/api/v1/platform/tenants/:id/import';
export const IMPORT_BODY_LIMIT = '10mb';

/** Everything main.ts and the e2e tests must configure identically. */
export async function configureApp(
  app: INestApplication,
  logger: Logger,
): Promise<void> {
  app.getHttpAdapter().getInstance().disable('x-powered-by');
  // Exactly one trusted hop: nginx, which appends $remote_addr to X-Forwarded-For. Without
  // this `req.ip` is nginx's container address for every client, so the per-IP login
  // limit was one bucket for everyone. Never `true` — that trusts the leftmost entry,
  // which the client writes. If another proxy (CDN, TLS terminator) is ever put in front of
  // nginx, `req.ip` becomes that proxy's address and #134 comes back: raise the hop count or
  // use nginx `real_ip` instead.
  app.getHttpAdapter().getInstance().set('trust proxy', 1);

  // Security headers via Helmet (OWASP A05)
  app.use(
    helmet({
      contentSecurityPolicy: false,
      crossOriginResourcePolicy: { policy: 'cross-origin' },
    }),
  );

  // Dynamic CORS configuration (OWASP A05)
  let allowedOrigins: string[] = ['*'];
  try {
    const cfg = app.get<AppConfig>(APP_CONFIG, { strict: false });
    if (cfg?.corsOrigins && cfg.corsOrigins.length > 0) {
      allowedOrigins = cfg.corsOrigins;
    }
  } catch {
    // fallback if APP_CONFIG not bound
  }

  app.enableCors({
    origin: (
      origin: string | undefined,
      callback: (err: Error | null, allow?: boolean) => void,
    ) => {
      // Allow requests with no origin (mobile apps, server-to-server, curl)
      if (!origin) return callback(null, true);
      if (allowedOrigins.includes('*') || allowedOrigins.includes(origin)) {
        return callback(null, true);
      }
      return callback(new Error('Not allowed by CORS'), false);
    },
    credentials: true,
    methods: ['GET', 'HEAD', 'PUT', 'PATCH', 'POST', 'DELETE', 'OPTIONS'],
    allowedHeaders: [
      'Content-Type',
      'Authorization',
      'Idempotency-Key',
      'If-None-Match',
      'X-Device-Id',
      'X-Client-Version',
      'X-Correlation-ID',
    ],
    exposedHeaders: ['Idempotency-Key', 'Retry-After', 'X-Correlation-ID', 'ETag'],
  });

  app.use(requestLogger(logger));
  // #185: the tenant import's body is a whole shop's backup (`sa_*` + `__meta`) — about 2 MiB
  // for four months of a mid-size shop — and Nest's own JSON parser stops at 100 KiB, so every
  // real file died as a 500. Only this route gets the larger limit, which matches nginx's
  // `client_max_body_size 10m`; it is registered before `app.init()` mounts Nest's parser,
  // and that parser skips a request whose body has already been read. 🔴 Wrapped, never passed
  // bare: Nest skips its own parser when it finds a middleware *named* `jsonParser` anywhere in
  // the stack, so `app.use(path, json())` silently left every other route with no body at all.
  // Only a request whose platform token verifies (signature, expiry, audience — the guard's own
  // check, `platformTokenFromHeader`) earns the large limit: nobody else may make the API buffer
  // and parse 10 MiB before the guard has looked at it. Anything else falls through to Nest's
  // 100 KiB parser (413 if larger) and the guard answers 401. With no config bound, nobody does.
  let platformSecret: string | undefined;
  try {
    platformSecret = app.get<AppConfig>(APP_CONFIG, { strict: false })?.jwtPlatformSecret;
  } catch {
    // APP_CONFIG not bound: no request earns the large limit
  }
  const importJson = json({ limit: IMPORT_BODY_LIMIT });
  app.use(IMPORT_ROUTE, (req: Request, res: Response, next: NextFunction) =>
    platformSecret && platformTokenFromHeader(req.headers.authorization, platformSecret)
      ? importJson(req, res, next)
      : next(),
  );
  app.setGlobalPrefix('api/v1', {
    exclude: [
      { path: 'health/live', method: RequestMethod.GET },
      { path: 'health/ready', method: RequestMethod.GET },
    ],
  });
  // The envelope wraps whatever comes back, a replayed idempotent body included. There is
  // no transaction interceptor (tx.4 #153): each handler's `TenantService.runTx` commits
  // before it returns, so the envelope only ever wraps committed data.
  app.useGlobalInterceptors(new EnvelopeInterceptor());
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
