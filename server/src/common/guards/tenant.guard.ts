import {
  Injectable,
  CanActivate,
  ExecutionContext,
  UnauthorizedException,
  HttpException,
  HttpStatus,
  Logger,
  Inject,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { Redis } from 'ioredis';
import { DataSource } from 'typeorm';
import { JwtVerifier } from '../../auth/jwt-keys.service.js';
import { REQUIRE_DEVICE_ROLE_KEY } from '../decorators/device-role.decorator.js';
import { REDIS_CACHE } from '../../infra/redis.module.js';

@Injectable()
export class TenantGuard implements CanActivate {
  private readonly logger = new Logger(TenantGuard.name);

  constructor(
    private readonly jwtVerifier: JwtVerifier,
    private readonly reflector: Reflector,
    private readonly ds: DataSource,
    @Inject(REDIS_CACHE) private readonly redisCache: Redis,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest();

    // 1. Extract Token
    const authHeader = request.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      throw new UnauthorizedException('Missing or invalid Authorization header');
    }
    const token = authHeader.substring(7);

    try {
      // 2. Verify Token (Throws UnauthorizedException on bad/expired signature or wrong typ)
      const payload = this.jwtVerifier.verify(token, 'access');

      // 3. Check Audience (ADR-0002)
      if (payload.aud !== 'tenant') {
        throw new HttpException(
          { code: 'FORBIDDEN', message: 'Invalid token audience' },
          HttpStatus.FORBIDDEN,
        );
      }

      if (!payload.tid) {
        throw new HttpException(
          { code: 'FORBIDDEN', message: 'Token missing tenant id' },
          HttpStatus.FORBIDDEN,
        );
      }

      // 4. Attach to Request
      request.user = {
        userId: payload.sub,
        tenantId: payload.tid,
        role: payload.role,
        deviceId: payload.did,
        deviceRole: payload.drole,
      };

      // 5. Check Device Role (ADR-0004)
      const requiredDeviceRole = this.reflector.getAllAndOverride<'pos' | 'backoffice'>(
        REQUIRE_DEVICE_ROLE_KEY,
        [context.getHandler(), context.getClass()],
      );

      if (requiredDeviceRole) {
        // If an endpoint requires 'pos', only drole === 'pos' is allowed.
        if (requiredDeviceRole === 'pos' && payload.drole !== 'pos') {
          throw new HttpException(
            { code: 'DEVICE_ROLE_FORBIDDEN', message: 'เครื่องนี้ขายของไม่ได้' },
            HttpStatus.FORBIDDEN,
          );
        }
        // If an endpoint requires 'backoffice', non-device logins (drole undefined) or drole === 'backoffice' are allowed.
        if (requiredDeviceRole === 'backoffice' && payload.drole && payload.drole !== 'backoffice') {
          throw new HttpException(
            { code: 'DEVICE_ROLE_FORBIDDEN', message: 'เครื่องนี้ขายของไม่ได้' },
            HttpStatus.FORBIDDEN,
          );
        }
      }

      // 6. Check Tenant Status (ADR-0003) with Redis caching (t:{tid}:status, TTL 300s + jitter)
      const cacheKey = `t:${payload.tid}:status`;
      let status: string | null = null;

      try {
        status = await this.redisCache.get(cacheKey);
      } catch (err) {
        this.logger.warn(`Redis cache error reading tenant status: ${err}`);
        status = null;
      }

      if (!status) {
        const res = await this.ds.query(
          `SELECT status FROM tenants WHERE id = $1`,
          [payload.tid],
        );
        if (res.length === 0) {
          throw new HttpException(
            { code: 'FORBIDDEN', message: 'Tenant not found' },
            HttpStatus.FORBIDDEN,
          );
        }
        status = res[0].status as string;

        try {
          const ttl = 300 + Math.floor(Math.random() * 30);
          await this.redisCache.set(cacheKey, status, 'EX', ttl);
        } catch (err) {
          this.logger.warn(`Redis cache error setting tenant status: ${err}`);
        }
      }

      if (status !== 'active') {
        throw new HttpException(
          { code: 'TENANT_SUSPENDED', message: 'ร้านนี้ถูกระงับการใช้งาน' },
          HttpStatus.FORBIDDEN,
        );
      }

      return true;
    } catch (err) {
      if (err instanceof HttpException) {
        throw err;
      }
      this.logger.warn(`Token validation failed: ${err}`);
      throw new UnauthorizedException('Invalid token');
    }
  }
}
