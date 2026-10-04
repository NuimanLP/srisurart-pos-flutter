import { EventEmitter } from 'node:events';
import type { NextFunction, Request, Response } from 'express';
import { describe, expect, it, vi } from 'vitest';
import { createMetricsMiddleware } from './metrics.middleware.js';
import type { MetricsService } from './metrics.service.js';

function run(req: Partial<Request>, statusCode = 200) {
  const recordRequest = vi.fn();
  const res = Object.assign(new EventEmitter(), { statusCode });
  const next = vi.fn() as NextFunction;
  createMetricsMiddleware({ recordRequest } as unknown as MetricsService)(
    Object.assign(req, { method: req.method ?? 'GET' }) as Request,
    res as unknown as Response,
    next,
  );
  return { recordRequest, next, finish: () => res.emit('finish') };
}

describe('createMetricsMiddleware', () => {
  it.each(['/metrics', '/health/live', '/health/ready'])(
    'does not measure %s (not API traffic, would inflate the SLI)',
    (path) => {
      const { recordRequest, next, finish } = run({ path });
      finish();
      expect(next).toHaveBeenCalledOnce();
      expect(recordRequest).not.toHaveBeenCalled();
    },
  );

  it('labels a matched request with the route pattern, not the concrete path', () => {
    const req: Partial<Request> = { path: '/api/v1/sales/abc', baseUrl: '' };
    const { recordRequest, next, finish } = run(req, 404);
    expect(next).toHaveBeenCalledOnce();
    expect(recordRequest).not.toHaveBeenCalled(); // only on finish
    // Express sets req.route once a handler matched — after the middleware ran.
    (req as { route: { path: string } }).route = { path: '/api/v1/sales/:id' };
    finish();
    expect(recordRequest).toHaveBeenCalledOnce();
    const [method, route, status, seconds] = recordRequest.mock.calls[0];
    expect([method, route, status]).toEqual(['GET', '/api/v1/sales/:id', 404]);
    expect(seconds).toBeGreaterThanOrEqual(0);
  });

  it('prefixes the router mount point', () => {
    const req: Partial<Request> = {
      path: '/x',
      method: 'POST',
      baseUrl: '/api/v1',
      route: { path: '/sales' },
    };
    const { recordRequest, finish } = run(req, 201);
    finish();
    expect(recordRequest.mock.calls[0].slice(0, 3)).toEqual(['POST', '/api/v1/sales', 201]);
  });

  it('collapses every unmatched path into one series', () => {
    const { recordRequest, finish } = run({ path: '/wp-admin/setup.php' }, 404);
    finish();
    expect(recordRequest.mock.calls[0][1]).toBe('unmatched');
  });
});
