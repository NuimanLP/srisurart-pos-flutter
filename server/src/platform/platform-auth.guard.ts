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

/**
 * The Redis key `PlatformAuthGuard` caches a platform admin's existence + password cutoff
 * under. Renamed from `pa:<id>:exists` to `pa:<id>:cutoff` on 2026-09-28 (#443 fix round):
 * the old key held a plain `'1'`/`'0'` exists flag, and reusing it for the cutoff value would
 * let a value a pre-deploy replica cached survive into the new code for up to its 60s TTL —
 * exactly the no-`iat`-token window the migration backfill (`…4600`) exists to close. A new
 * key name makes any old cached value a guaranteed miss instead. One helper so the guard, the
 * cache-bust in `main.ts`, and the e2e suites can never drift apart on the key shape.
 */
export function platformAdminCacheKey(adminId: string): string {
  return `pa:${adminId}:cutoff`;
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

    // Verify platform admin exists and is active (cache in Redis with 60s TTL). The cached
    // value also carries the password cutoff (#443, 2026-09-28): '0' = missing/inactive,
    // '1' = active with no `password_changed_at`, otherwise floor(epoch(password_changed_at)).
    const cacheKey = platformAdminCacheKey(adminId);
    let cached: string | null = null;
    try {
      cached = await this.redisCache.get(cacheKey);
    } catch {
      // If Redis fails, fall back to DB query
    }

    if (cached === null) {
      const res = await this.adminDs.query(
        `SELECT floor(extract(epoch FROM password_changed_at))::bigint AS cutoff
           FROM platform_admins WHERE id = $1 AND is_active = true`,
        [adminId],
      );
      const row = Array.isArray(res) ? res[0] : undefined;
      cached = !row ? '0' : row.cutoff == null ? '1' : String(row.cutoff);
      try {
        await this.redisCache.setex(cacheKey, 60, cached);
      } catch {
        // Ignore Redis write errors
      }
    }

    if (cached === '0') {
      throw new UnauthorizedException('Platform admin does not exist or is inactive');
    }

    // ADR-0009 addendum 2026-09-26 rule, applied to platform admins: a token issued before the
    // password last changed (PLATFORM_ADMINS sync, `bootstrap-admin --force`) is dead. Strict
    // `<` on whole seconds, like `/auth/refresh`; a token with no `iat` (minted before #443's
    // fix round) counts as older than any cutoff.
    if (cached !== '1' && (payload.iat ?? 0) < Number(cached)) {
      throw new UnauthorizedException('Platform token predates the last password change');
    }

    req.platformAdmin = {
      id: payload.sub,
      username: payload.username,
    };

    return true;
  }
}
