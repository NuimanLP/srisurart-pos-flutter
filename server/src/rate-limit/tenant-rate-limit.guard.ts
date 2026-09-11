import {
  CanActivate,
  ExecutionContext,
  HttpException,
  HttpStatus,
  Injectable,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { Request, Response } from 'express';
import { JwtVerifier } from '../auth/jwt-keys.service.js';
import {
  RATE_LIMIT_OPTIONS_KEY,
  SKIP_RATE_LIMIT_KEY,
  type RateLimitOptions,
} from './rate-limit.decorator.js';
import { RateLimitService } from './rate-limit.service.js';

@Injectable()
export class TenantRateLimitGuard implements CanActivate {
  constructor(
    private readonly rateLimitService: RateLimitService,
    private readonly reflector: Reflector,
    private readonly jwtVerifier: JwtVerifier,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const http = context.switchToHttp();
    const req = http.getRequest<Request & { user?: { tenantId?: string } }>();
    const res = http.getResponse<Response>();

    // 1. Exempt health endpoints (ADR-0006: health check must never be rate-limited)
    const url = req.url || req.path || '';
    if (url.startsWith('/health')) {
      return true;
    }

    // 2. Check @SkipRateLimit() decorator
    const isSkipped = this.reflector.getAllAndOverride<boolean>(
      SKIP_RATE_LIMIT_KEY,
      [context.getHandler(), context.getClass()],
    );
    if (isSkipped) {
      return true;
    }

    // 3. Resolve tenantId strictly from authenticated session (JWT only)
    // ADR-0006: Forged X-Tenant-Id headers are completely ignored.
    let tenantId = req.user?.tenantId;
    if (!tenantId) {
      const authHeader = req.headers.authorization;
      if (authHeader?.startsWith('Bearer ')) {
        const token = authHeader.substring(7);
        try {
          const payload = this.jwtVerifier.verify(token, 'access');
          if (payload.aud === 'tenant' && payload.tid) {
            tenantId = payload.tid;
          }
        } catch {
          // Unverified or invalid token; let downstream auth guard handle 401/403
          return true;
        }
      }
    }

    if (!tenantId) {
      // Unauthenticated / pre-auth traffic is protected by Nginx per-IP rate limit.
      return true;
    }

    // 4. Read route-specific rate limit options if decorated
    const options = this.reflector.getAllAndOverride<RateLimitOptions>(
      RATE_LIMIT_OPTIONS_KEY,
      [context.getHandler(), context.getClass()],
    );

    // 5. Construct route identifier
    const route = req.route?.path ?? req.path ?? 'root';
    const routeKey = `${req.method}:${route}`;

    // 6. Check quota in Redis
    const result = await this.rateLimitService.checkRateLimit(
      tenantId,
      routeKey,
      options,
    );

    if (!result.allowed) {
      const retryAfter = result.retryAfter ?? 60;
      res.setHeader('Retry-After', String(retryAfter));
      throw new HttpException(
        {
          code: 'RATE_LIMITED',
          message: 'ระบบกำลังทำงานหนัก กรุณารอสักครู่',
        },
        HttpStatus.TOO_MANY_REQUESTS,
      );
    }

    return true;
  }
}
