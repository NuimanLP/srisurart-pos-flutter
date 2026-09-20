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
export function createMetricsMiddleware(metricsService: MetricsService) {
  return (req: Request, res: Response, next: NextFunction): void => {
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
