import {
  CanActivate,
  ExecutionContext,
  ForbiddenException,
  Inject,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { DataSource } from 'typeorm';
import type { Redis } from 'ioredis';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { ADMIN_DATA_SOURCE } from '../infra/db.module.js';
import { REDIS_CACHE } from '../infra/redis.module.js';
import { verifyJwt, type JwtPayload } from '../common/jwt.js';
import { clientIp } from '../common/client-ip.js';

/**
 * The platform token in an `Authorization` header, verified (HMAC with `jwtPlatformSecret`,
 * expiry, `aud: 'platform'`), or null. It checks the signature only — whether the admin
 * still exists is the guard's job. `configureApp` uses it to decide who earns the import
 * route's 10 MiB body limit before any guard has run.
 */
export function platformTokenFromHeader(header: unknown, secret: string): JwtPayload | null {
  if (typeof header !== 'string') return null;
  const [scheme, token] = header.split(' ');
  if (scheme !== 'Bearer' || !token) return null;
  const payload = verifyJwt(token, secret);
  return payload && payload.aud === 'platform' ? payload : null;
}

@Injectable()
export class PlatformAuthGuard implements CanActivate {
  constructor(
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    @Inject(ADMIN_DATA_SOURCE) private readonly adminDs: DataSource,
    @Inject(REDIS_CACHE) private readonly redisCache: Redis,
  ) {}

  private isAllowedIp(ip: string | null): boolean {
    if (!ip) return false;
    const lowerIp = ip.toLowerCase();
    const cleanIp = lowerIp.startsWith('::ffff:') ? lowerIp.slice(7) : lowerIp;
    if (cleanIp === '127.0.0.1' || cleanIp === '::1') {
      return true;
    }
    if (this.config.platformAdminIps?.includes(cleanIp)) {
      return true;
    }
    return false;
  }

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const req = context.switchToHttp().getRequest();

    // IP allowlist check: platform plane is restricted to loopback and configured admin IPs
    // (sec.platform-allowlist / #270).
    const ip = clientIp(req);
    if (!this.isAllowedIp(ip)) {
      throw new ForbiddenException({
        code: 'PLATFORM_IP_FORBIDDEN',
        message: 'IP not allowed for platform admin access',
      });
    }

    const authHeader = req.headers['authorization'];
    if (!authHeader || typeof authHeader !== 'string') {
      throw new UnauthorizedException('Missing Authorization header');
    }

    const [scheme, token] = authHeader.split(' ');
    if (scheme !== 'Bearer' || !token) {
      throw new UnauthorizedException('Invalid Authorization header format');
    }

    const payload = verifyJwt(token, this.config.jwtPlatformSecret);
    if (!payload) {
      throw new UnauthorizedException('Invalid or expired platform token');
    }

    if (payload.aud !== 'platform') {
      throw new ForbiddenException('Token audience is not platform');
    }

    const adminId = payload.sub;
    if (!adminId) {
      throw new UnauthorizedException('Token missing platform admin id');
    }

    // Verify platform admin exists and is active (cache in Redis with 60s TTL)
    const cacheKey = `pa:${adminId}:exists`;
    let exists: boolean | null = null;
    try {
      const cached = await this.redisCache.get(cacheKey);
      if (cached !== null) {
        exists = cached === '1';
      }
    } catch {
      // If Redis fails, fall back to DB query
    }

    if (exists === null) {
      const res = await this.adminDs.query(
        `SELECT id FROM platform_admins WHERE id = $1 AND is_active = true`,
        [adminId],
      );
      exists = Array.isArray(res) && res.length > 0;
      try {
        await this.redisCache.setex(cacheKey, 60, exists ? '1' : '0');
      } catch {
        // Ignore Redis write errors
      }
    }

    if (!exists) {
      throw new UnauthorizedException('Platform admin does not exist or is inactive');
    }

    req.platformAdmin = {
      id: payload.sub,
      username: payload.username,
    };

    return true;
  }
}
