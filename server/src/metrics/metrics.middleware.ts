import type { NextFunction, Request, Response } from 'express';
import type { MetricsService } from './metrics.service.js';

/**
 * Route label extraction:
 * Must use the route pattern (e.g. `/api/v1/sales/:id`), NOT the concrete path
 * (e.g. `/api/v1/sales/uuid`).
 *
 * Intentional design difference from idempotency fingerprinting:
 * - Idempotency MUST use the concrete path so different resources (e.g. `/sales/1/void` vs `/sales/2/void`)
 *   do not share a fingerprint collision.
 * - Prometheus metrics MUST use the route pattern to prevent cardinality explosion.
 *   Using concrete paths would create an unbounded number of metric series (one per sale/UUID),
 *   exhausting Prometheus memory.
 *
 * Hook choice: Express middleware with `res.on('finish')`:
 * NestJS execution order is Express middleware -> Guards -> Interceptors.
 * If a request is rejected by a Guard (e.g. 401 Unauthorized, 403 Forbidden, 429 Rate Limited),
 * Nest interceptors never execute. An Express middleware that measures duration and observes
 * labels on `res.on('finish')` guarantees that guard rejections are captured in error metrics.
 */

/**
 * Prometheus's own scrape is not API traffic and must not be measured as if it were.
 * Three api instances scraped every 15s is 12 guaranteed-200s a minute arriving forever,
 * which on a quiet counter outnumbers the shop's real requests — and the two SLI panels
 * (*API success rate*, *API p95 latency*, `02_API_SCREENS.md §9`) average over every series
 * in `http_requests_total`. Left in, a shop where every real sale is failing still reads as
 * ~92% success, because the scrapes carry the ratio. The health probes are excluded for the
 * same reason: compose health-checks each api instance every 15s, and the `api-readiness`
 * scrape job polls `/health/ready` on all three at the same interval.
 */
const UNMEASURED_PATHS = new Set(['/metrics', '/health/live', '/health/ready']);

export function createMetricsMiddleware(metricsService: MetricsService) {
  return (req: Request, res: Response, next: NextFunction): void => {
    if (UNMEASURED_PATHS.has(req.path)) {
      next();
      return;
    }
    const start = process.hrtime.bigint();
    res.on('finish', () => {
      const duration = Number(process.hrtime.bigint() - start) / 1e9;
      const routePath = req.route?.path;
      let route: string;
      if (routePath !== undefined) {
        route = `${req.baseUrl || ''}${routePath}`;
      } else {
        // Unmatched routes (e.g. 404s) must not use raw req.path to avoid cardinality explosion from URL scanners
        route = 'unmatched';
      }
      metricsService.recordRequest(req.method, route, res.statusCode, duration);
    });
    next();
  };
}
