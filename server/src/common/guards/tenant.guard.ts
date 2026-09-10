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
import { JwtVerifier } from '../../auth/jwt-keys.service.js';
import { REQUIRE_DEVICE_ROLE_KEY } from '../decorators/device-role.decorator.js';
import { REDIS_CACHE } from '../../infra/redis.module.js';
import {
  currentRequestTransaction,
  setRequestTenant,
} from '../request-context.js';

@Injectable()
export class TenantGuard implements CanActivate {
  private readonly logger = new Logger(TenantGuard.name);

  constructor(
    private readonly jwtVerifier: JwtVerifier,
    private readonly reflector: Reflector,
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
      // If an endpoint requires 'pos', only drole === 'pos' is allowed (ADR-0004).
      if (requiredDeviceRole === 'pos' && payload.drole !== 'pos') {
        throw new HttpException(
          { code: 'DEVICE_ROLE_FORBIDDEN', message: 'เครื่องนี้ขายของไม่ได้' },
          HttpStatus.FORBIDDEN,
        );
      }
      // Note: 'pos' devices have full access to all 'backoffice' endpoints (ADR-0004: "ทั้งคู่").
      // Web sessions without a device token (drole undefined) and 'backoffice' devices can also access.
    }

    // The request already holds a pooled connection: RequestContextMiddleware opened a
    // transaction on one before any guard ran. Anything below that reaches for a
    // SECOND connection deadlocks the pool under load — every in-flight request
    // holding one and waiting for another — so the status probe runs on the request's
    // own transaction. `tenants` is one of the two tables with no RLS, so reading it
    // before `SET LOCAL app.tenant_id` is well defined.
    const manager = currentRequestTransaction();
    if (!manager) {
      throw new HttpException(
        { code: 'INTERNAL_ERROR', message: 'Internal server error' },
        HttpStatus.INTERNAL_SERVER_ERROR,
      );
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
      const res = (await manager.query(`SELECT status FROM tenants WHERE id = $1`, [
        payload.tid,
      ])) as { status: string }[];
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

    // 7. Only now name the tenant on that transaction (ADR-0003 — this guard is the
    //    ONE component allowed to). `SET LOCAL` is transaction-scoped, so it must land
    //    on the transaction RequestContextMiddleware opened and no other: a query on
    //    any other connection is a query RLS shows nothing. Doing it after the status
    //    check means a suspended tenant is never named on a transaction at all.
    await manager.query(`SELECT set_config('app.tenant_id', $1, true)`, [
      payload.tid,
    ]);
    setRequestTenant(payload.tid);

    return true;
  }
}
