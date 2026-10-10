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
import { JwtVerifier } from './auth/jwt-keys.service.js';
import {
  OWNER_IMPORT_ROUTE,
  ownerImportTokenFromHeader,
} from './backup/owner-import.controller.js';
import {
  ownerTokenFromHeader,
  PAYMENT_ACCOUNTS_BODY_LIMIT,
  PAYMENT_ACCOUNTS_ROUTE,
} from './payment-accounts/payment-accounts.controller.js';
import { createMetricsMiddleware } from './metrics/metrics.middleware.js';
import { MetricsService } from './metrics/metrics.service.js';

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
      // Not allowed: omit the CORS headers and let the request proceed. The browser blocks the
      // response on its own (a preflight falls through to a 404). Throwing here gave curl and
      // scanners a 500 that skipped requestLogger and the metrics middleware below entirely.
      return callback(null, false);
    },
    credentials: true,
    methods: ['GET', 'HEAD', 'PUT', 'PATCH', 'POST', 'DELETE', 'OPTIONS'],
    allowedHeaders: [
      'Content-Type',
      'Authorization',
      'Idempotency-Key',
      'If-None-Match',
      'X-Device-Id',
      // /sync/push and /sync/discards authenticate with the device token (DeviceTokenGuard);
      // without it here a cross-origin web build's preflight fails and the outbox never sends.
      'X-Device-Token',
      'X-Client-Version',
      'X-Correlation-ID',
    ],
    exposedHeaders: ['Idempotency-Key', 'Retry-After', 'X-Correlation-ID', 'ETag'],
  });

  app.use(requestLogger(logger));
  // The lookup is lenient for exactly one reason: `app.setup.spec.ts` calls `configureApp` on
  // bare probe modules that never import `AppModule`, so `MetricsService` is genuinely absent
  // there. It is NOT a defence against losing the wiring in production — a real app that lost
  // `MetricsModule` fails `metrics.e2e-spec.ts` twice over (`GET /metrics` 404s because the
  // controller is gone, and the `http_requests_total` assertions find nothing).
  try {
    const metricsService = app.get(MetricsService, { strict: false });
    if (metricsService) {
      app.use(createMetricsMiddleware(metricsService));
    }
  } catch {
    // Not bound: a unit-test app built without AppModule. See the comment above.
  }
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
  // The shop owner's own import (`POST /backup/import`) takes the same file, so the same
  // limit — earned only by a verified owner access token on an enrolled device, for the same
  // reason as above. With no `JwtVerifier` bound (probe apps), nobody does.
  let tenantVerifier: JwtVerifier | undefined;
  try {
    tenantVerifier = app.get(JwtVerifier, { strict: false });
  } catch {
    // JwtVerifier not bound: no request earns the large limit
  }
  app.use(OWNER_IMPORT_ROUTE, (req: Request, res: Response, next: NextFunction) =>
    tenantVerifier && ownerImportTokenFromHeader(req.headers.authorization, tenantVerifier)
      ? importJson(req, res, next)
      : next(),
  );
  // QR payment accounts carry an uploaded QR image (≤ 300 KB decoded, ≈ 400 KB of base64):
  // 1 MB on these routes only, earned only by a verified owner access token — the same
  // pattern and reason as above. No enrolled device is needed (the routes require none).
  // `app.use(path)` also matches `/payment-accounts/:id`.
  const paymentAccountsJson = json({ limit: PAYMENT_ACCOUNTS_BODY_LIMIT });
  app.use(PAYMENT_ACCOUNTS_ROUTE, (req: Request, res: Response, next: NextFunction) =>
    tenantVerifier && ownerTokenFromHeader(req.headers.authorization, tenantVerifier)
      ? paymentAccountsJson(req, res, next)
      : next(),
  );
  app.setGlobalPrefix('api/v1', {
    exclude: [
      { path: 'health/live', method: RequestMethod.GET },
      { path: 'health/ready', method: RequestMethod.GET },
      { path: 'metrics', method: RequestMethod.GET },
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
