import {
  HttpException,
  HttpStatus,
  Inject,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { DataSource } from 'typeorm';
import { ADMIN_DATA_SOURCE } from '../infra/db.module.js';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { signJwt } from '../common/jwt.js';
import { verifyAgainstDummyHash, verifyPassword } from '../common/password.js';
import { RateLimitService } from '../rate-limit/rate-limit.service.js';
import { AuditService } from './audit.service.js';

/**
 * Owner decision 2026-09-27 (#443 PR4, Q8): the browser holds this token in `sessionStorage`
 * with no refresh, so 24h (the original value) was an unnecessarily long-lived bearer credential
 * sitting in a tab. 1h matches how long an admin actually works a session before re-logging in.
 */
const PLATFORM_TOKEN_TTL_SEC = 60 * 60;

@Injectable()
export class PlatformAuthService {
  constructor(
    @Inject(ADMIN_DATA_SOURCE) private readonly adminDs: DataSource,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    private readonly auditService: AuditService,
    private readonly rateLimit: RateLimitService,
  ) {}

  async login(username: string, password: string, ip?: string) {
    // #443 PR4 (owner decision, Q5): the same per-IP + per-username throttle as the owner
    // login (auth.service.ts:96-112), reusing RateLimitService's atomic Lua `consumeAttempt`
    // rather than a second copy of the limiter. Checked before the DB query for the same
    // reason as the owner path: a locked-out caller must not cost a query or an argon2 verify.
    // Unlike the owner login, there is no tenant to scope the username bucket to — platform
    // admins are global — so the key is the bare username.
    const ipKey = ip ? `platform:ip:${ip}` : null;
    if (ipKey) {
      const ipStatus = await this.rateLimit.consumeAttempt(ipKey, 10, 60);
      if (!ipStatus.allowed) {
        throw new HttpException(
          {
            code: 'RATE_LIMITED',
            message: 'Too many requests from this IP. Please try again later.',
            retryAfter: ipStatus.retryAfter ?? 60,
          },
          HttpStatus.TOO_MANY_REQUESTS,
        );
      }
    }

    const userKey = username ? `platform:user:${username}` : null;
    if (userKey) {
      const userStatus = await this.rateLimit.consumeAttempt(userKey, 5, 60);
      if (!userStatus.allowed) {
        throw new HttpException(
          {
            code: 'RATE_LIMITED',
            message: 'Too many failed login attempts. Please try again later.',
            retryAfter: userStatus.retryAfter ?? 60,
          },
          HttpStatus.TOO_MANY_REQUESTS,
        );
      }
    }

    const res = await this.adminDs.query(
      `SELECT id, username, password_hash, display_name, is_active FROM platform_admins WHERE username = $1`,
      [username],
    );

    const admin = res[0];
    // An unknown admin still pays one argon2 verify, so latency does not reveal usernames (#425).
    const isValid = admin
      ? await verifyPassword(password, admin.password_hash)
      : await verifyAgainstDummyHash(password);
    if (!admin || !admin.is_active || !isValid) {
      throw new UnauthorizedException('Invalid platform admin credentials');
    }

    // A correct login clears this username's failures; the IP bucket only gets this one
    // attempt back, so failures against other usernames from the same address stay counted
    // (same reasoning as auth.service.ts:187-188).
    if (userKey) await this.rateLimit.clearKey(userKey, 60);
    if (ipKey) await this.rateLimit.refundAttempt(ipKey, 60);

    const token = signJwt(
      {
        iss: 'srisurart-pos',
        aud: 'platform',
        sub: admin.id,
        username: admin.username,
        exp: Math.floor(Date.now() / 1000) + PLATFORM_TOKEN_TTL_SEC,
      },
      this.config.jwtPlatformSecret,
    );

    // Platform audit log requirement
    await this.auditService.log(this.adminDs, {
      tenantId: '00000000-0000-0000-0000-000000000000',
      platformAdminId: admin.id,
      action: 'platform.auth.login',
      ip,
    });

    return {
      token,
      admin: {
        id: admin.id,
        username: admin.username,
        displayName: admin.display_name,
      },
    };
  }
}
