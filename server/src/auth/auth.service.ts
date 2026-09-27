import {
  BadRequestException,
  Injectable,
  UnauthorizedException,
  Logger,
  ForbiddenException,
  HttpException,
  HttpStatus,
} from '@nestjs/common';
import { DataSource } from 'typeorm';
import * as crypto from 'node:crypto';
import * as argon2 from 'argon2';
import { JwtSigner, type JwtPayload } from './jwt-keys.service.js';
import { AuditService } from '../audit/audit.service.js';
import { RateLimitService } from '../rate-limit/rate-limit.service.js';
import {
  chosenPasswordViolation,
  hashPassword,
  normalizePassword,
  passwordPolicyMessage,
  verifyAgainstDummyHash,
  verifyPassword,
  type PasswordPolicyViolation,
} from '../common/password.js';
import { returning } from '../common/sql.js';

export interface LoginDto {
  username: string;
  password?: string;
  deviceToken?: string;
}

/**
 * #443 PR3: lifetime of the restricted `typ:'pwchange'` token a temporary-password login
 * yields. Long enough to type a new password twice, short enough that a token left on a
 * shared screen is dead before anyone else sits down. It has no refresh token.
 */
export const PWCHANGE_TOKEN_TTL = '10m';

/** `WEAK_PASSWORD` (02_API_SCREENS.md §8.1) with the reason, for a password the owner chose. */
function weakPassword(violation: PasswordPolicyViolation): BadRequestException {
  return new BadRequestException({
    code: 'WEAK_PASSWORD',
    message: passwordPolicyMessage(violation, 'newPassword'),
    details: { reason: violation },
  });
}

@Injectable()
export class AuthService {
  private readonly logger = new Logger(AuthService.name);

  constructor(
    private readonly ds: DataSource,
    private readonly jwtSigner: JwtSigner,
    private readonly audit: AuditService,
    private readonly rateLimit: RateLimitService,
  ) {}

  async login(dto: LoginDto, clientIp?: string) {
    if (!dto.password || typeof dto.password !== 'string') {
      throw new UnauthorizedException('Password is required');
    }
    // #443 PR3: the same NFC form every owner password is hashed in (common/password.ts).
    const password = normalizePassword(dto.password);

    // Brute-force checks (OWASP A07). The IP bucket needs no tenant, so it is checked before a
    // pool connection is taken: a locked-out IP must not cost a connection and a device lookup.
    // `clientIp` is the real client only because `configureApp` sets `trust proxy` to 1.
    //
    // Every attempt is counted up front, atomically (#138): a separate check then increment let N
    // concurrent attempts all pass. So every refusal counts — bad device token, unknown or ambiguous
    // username, wrong password, and (after a correct password) inactive user or suspended tenant —
    // and only a successful login gives its own attempt back. The IP bucket is never cleared on
    // success: that let one valid account reset the bucket every 9 failures and spray usernames
    // with no IP limit.
    const ipKey = clientIp ? `auth:ip:${clientIp}` : null;
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

    // No connection is held across this method (perf: a burst of logins used to pin every
    // `pos_app` pool slot through argon2's ~100-300 ms and starve sales). The two lookups are
    // SECURITY DEFINER functions that need no `app.tenant_id`, so each is a plain pool query
    // that returns its connection at once; argon2 runs with none held; each audit row takes
    // its own short connection afterwards. Never more than one at a time.

    // 1. Resolve device info from deviceToken if provided (ADR-0004)
    let deviceTenantId: string | null = null;
    let did: string | undefined;
    let drole: string | undefined;

    if (dto.deviceToken) {
      const hash = await this.hashDeviceToken(dto.deviceToken);
      const devRes = await this.ds.query(
        `SELECT tenant_id, id, role, retired_at FROM auth_lookup_device_by_token($1)`,
        [hash],
      );
      if (devRes.length === 1) {
        const dev = devRes[0];
        if (dev.retired_at) {
          throw new UnauthorizedException('Device has been retired');
        }
        deviceTenantId = dev.tenant_id;
        did = dev.id;
        drole = dev.role;
      } else {
        throw new UnauthorizedException('Invalid device token');
      }
    }

    // The username bucket is scoped to the device's tenant: usernames like `owner` repeat
    // across shops, so an unscoped key let failures in one shop lock that name in all of them.
    const userKey = dto.username
      ? `auth:user:${deviceTenantId ?? '-'}:${dto.username}`
      : null;

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

    // 2. Find User via SECURITY DEFINER function to respect RLS
    const userRows = await this.ds.query(
      `SELECT * FROM auth_lookup_user_for_login($1, $2)`,
      [dto.username, deviceTenantId ?? null],
    );

    // Owner decision 2026-09-25: the password is verified FIRST, and account status (tenant
    // suspended, user inactive) is only revealed to a caller who supplied the correct password.
    // Every other refusal — wrong password on any account, unknown user, ambiguous username —
    // is the same generic 401 after exactly one argon2 verify, so a password guesser never
    // learns an account's status. (A known user's failure still writes an audit row that an
    // unknown/ambiguous one does not; that small latency gap predates this and is out of scope.)
    if (userRows.length !== 1) {
      // 0 rows: unknown user (#425). >1 rows: the username exists in several shops and no
      // device token picks one. Establishing which (if any) password is right would need one
      // verify per candidate, so it is refused like a wrong password: one dummy verify, the
      // generic 401, and no audit row (there is no single tenant to audit under).
      await verifyAgainstDummyHash(password);
      this.logger.warn(
        `Login failed: ${userRows.length === 0 ? 'user not found' : 'ambiguous username'} for username=${dto.username}`,
      );
      throw new UnauthorizedException('Invalid credentials');
    }

    const user = userRows[0];
    const tenantId = user.tenant_id;

    // Verify Password (Argon2id) — before any status check (see above).
    let valid = false;
    try {
      valid = await argon2.verify(user.password_hash, password);
    } catch (err) {
      this.logger.warn(`Password verification failed to parse hash for userId=${user.id}: ${err}`);
      valid = false;
    }
    if (!valid) {
      await this.logAuthEvent(tenantId, {
        tenantId,
        userId: user.id,
        deviceId: did,
        ip: clientIp,
        action: 'auth.login_failed',
        before: { reason: 'invalid_password' },
      });
      throw new UnauthorizedException('Invalid credentials');
    }

    // Check tenant status (ADR-0003) — only reached with the correct password.
    if (user.tenant_status !== 'active') {
      await this.logAuthEvent(tenantId, {
        tenantId,
        userId: user.id,
        deviceId: did,
        ip: clientIp,
        action: 'auth.login_failed',
        before: { reason: 'tenant_inactive' },
      });
      throw new ForbiddenException({
        code: 'TENANT_SUSPENDED',
        message: 'ร้านนี้ถูกระงับการใช้งาน',
      });
    }

    // Check user active — only reached with the correct password.
    if (!user.is_active) {
      await this.logAuthEvent(tenantId, {
        tenantId,
        userId: user.id,
        deviceId: did,
        ip: clientIp,
        action: 'auth.login_failed',
        before: { reason: 'user_inactive' },
      });
      throw new UnauthorizedException('User is inactive');
    }

    // #443 PR3 (v2 condition 2): a temporary password nobody used in time is dead — the
    // platform team issues a new one. Only reached with the correct password, like the two
    // status checks above, so it tells a guesser nothing. Its own code, so the login screen
    // can say "ask for a new one" instead of "wrong password".
    if (user.must_change_password) {
      const expiresAt = user.temp_password_expires_at
        ? new Date(user.temp_password_expires_at).getTime()
        : 0;
      if (expiresAt <= Date.now()) {
        await this.logAuthEvent(tenantId, {
          tenantId,
          userId: user.id,
          deviceId: did,
          ip: clientIp,
          action: 'auth.login_failed',
          before: { reason: 'temp_password_expired' },
        });
        throw new UnauthorizedException({
          code: 'TEMP_PASSWORD_EXPIRED',
          message: 'The temporary password has expired; ask the platform team for a new one',
        });
      }
    }

    // A correct password clears this username's failures; the IP bucket only gets this one
    // attempt back, so failures against other usernames from the same address stay counted.
    if (userKey) await this.rateLimit.clearKey(userKey, 60);
    if (ipKey) await this.rateLimit.refundAttempt(ipKey, 60);

    // 3. Issue Tokens
    const payload: Omit<JwtPayload, 'iss' | 'iat' | 'exp'> = {
      aud: 'tenant',
      sub: user.id,
      jti: crypto.randomUUID(),
      typ: 'access',
      tid: tenantId,
      role: user.role,
      did,
      drole,
    };

    const userView = {
      id: user.id,
      username: user.username,
      role: user.role,
      displayName: user.display_name,
    };

    // #443 PR3 (v2 condition 3): a temporary password buys only a restricted token that
    // `POST /auth/change-password` alone accepts — enforced by the JWT `typ`, so every
    // `TenantGuard` route and `/auth/refresh` refuse it without a check of their own. No
    // refresh token, and no `accessToken` field: the client can neither keep a session nor
    // record this as the online login that opens the 3-day offline-PIN window (F5). The
    // `deviceToken` path runs through here too, so it cannot skip the change.
    if (user.must_change_password) {
      const passwordChangeToken = this.jwtSigner.sign(
        { ...payload, typ: 'pwchange' },
        PWCHANGE_TOKEN_TTL,
      );
      await this.logAuthEvent(tenantId, {
        tenantId,
        userId: user.id,
        deviceId: did,
        ip: clientIp,
        action: 'auth.login',
        after: { passwordChangeRequired: true },
      });
      return { passwordChangeRequired: true, passwordChangeToken, user: userView };
    }

    const accessToken = this.jwtSigner.sign(payload, '15m');
    
    const refreshPayload = { ...payload, typ: 'refresh' as const, jti: crypto.randomUUID() };
    const expUnix = this.calculateRefreshExpiry(user.timezone || 'Asia/Bangkok');
    const refreshToken = this.jwtSigner.sign(refreshPayload, expUnix);

    // Log success
    await this.logAuthEvent(tenantId, {
      tenantId,
      userId: user.id,
      deviceId: did,
      ip: clientIp,
      action: 'auth.login',
    });

    return {
      accessToken,
      refreshToken,
      user: userView,
      // #443 PR3 (v2 condition 7): the client shows "รหัสผ่านถูกเปลี่ยนเมื่อ …" when this is
      // recent, so a reset nobody at the shop asked for does not go unnoticed.
      passwordChangedAt: user.password_changed_at
        ? new Date(user.password_changed_at).toISOString()
        : null,
    };
  }

  /**
   * Refreshes a token based on the decoded payload from the refresh token.
   * ADR-0009: Check users.is_active, tenants.status, devices.retired_at
   */
  async refreshTokenPayload(payload: JwtPayload) {
    if (payload.typ !== 'refresh') {
      throw new UnauthorizedException('Invalid token type');
    }
    if (payload.aud !== 'tenant') {
      throw new UnauthorizedException('Invalid token audience');
    }
    const tenantId = payload.tid;
    const userId = payload.sub;
    const did = payload.did;

    if (!tenantId) {
      throw new UnauthorizedException('Token missing tenant id');
    }

    const qr = this.ds.createQueryRunner();
    await qr.connect();
    
    try {
      await qr.startTransaction();
      // `set_config(..., true)`, not `SET LOCAL app.tenant_id = $1`: SET is a utility
      // statement and takes no bind parameter, so that form is a plain 42601 syntax
      // error. Being the transaction's first statement, it turned every refresh into
      // a 500 and left ADR-0009's `auth.refresh_rejected` trail empty.
      await qr.query(`SELECT set_config('app.tenant_id', $1, true)`, [tenantId]);

      // Check tenant and user under RLS
      const userRows = await qr.query(
        `SELECT u.is_active, t.status, t.timezone,
                floor(extract(epoch FROM u.password_changed_at))::bigint AS password_changed_epoch
           FROM users u JOIN tenants t ON u.tenant_id = t.id
          WHERE u.tenant_id = $1 AND u.id = $2`,
        [tenantId, userId],
      );
      if (userRows.length === 0) {
        await qr.rollbackTransaction();
        throw new UnauthorizedException('User not found');
      }
      const u = userRows[0];

      if (u.status !== 'active') {
        await this.audit.log(qr.manager, {
          tenantId,
          userId,
          deviceId: did,
          action: 'auth.refresh_rejected',
          before: { reason: 'tenant_inactive' },
        });
        await qr.commitTransaction();
        throw new ForbiddenException({
          code: 'TENANT_SUSPENDED',
          message: 'ร้านนี้ถูกระงับการใช้งาน',
        });
      }

      if (!u.is_active) {
        await this.audit.log(qr.manager, {
          tenantId,
          userId,
          deviceId: did,
          action: 'auth.refresh_rejected',
          before: { reason: 'user_inactive' },
        });
        await qr.commitTransaction();
        throw new UnauthorizedException('User is inactive');
      }

      // ADR-0009 addendum 2026-09-27 (#443): the fourth DB check. A refresh token issued
      // before the password last changed (a reset, or the owner's own change) is dead —
      // the same column-check pattern as the three above, not a denylist. Strict `<`: a
      // token issued in the same second as the change survives (accepted — `iat` is whole
      // seconds, and a `<=` would kill the very token change-password just returned).
      if (
        u.password_changed_epoch !== null &&
        u.password_changed_epoch !== undefined &&
        payload.iat < Number(u.password_changed_epoch)
      ) {
        await this.audit.log(qr.manager, {
          tenantId,
          userId,
          deviceId: did,
          action: 'auth.refresh_rejected',
          before: { reason: 'password_changed' },
        });
        await qr.commitTransaction();
        throw new UnauthorizedException('Password has been changed');
      }

      // Check device if bound
      if (did) {
        const devRows = await qr.query(
          `SELECT retired_at FROM devices WHERE tenant_id = $1 AND id = $2`,
          [tenantId, did],
        );
        if (devRows.length === 0 || devRows[0].retired_at) {
          await this.audit.log(qr.manager, {
            tenantId,
            userId,
            deviceId: did,
            action: 'auth.refresh_rejected',
            before: { reason: 'device_retired' },
          });
          await qr.commitTransaction();
          throw new UnauthorizedException('Device is retired');
        }
      }

      await qr.commitTransaction();

      // Issue new access token
      const accessPayload: Omit<JwtPayload, 'iss' | 'iat' | 'exp'> = {
        aud: payload.aud,
        sub: payload.sub,
        jti: crypto.randomUUID(),
        typ: 'access',
        tid: payload.tid,
        role: payload.role,
        did: payload.did,
        drole: payload.drole,
      };

      const accessToken = this.jwtSigner.sign(accessPayload, '15m');
      
      // Issue new refresh token retaining the exact original expiration timestamp (ADR-0009)
      const refreshPayload = { ...accessPayload, typ: 'refresh' as const, jti: crypto.randomUUID() };
      const refreshToken = this.jwtSigner.sign(refreshPayload, payload.exp);

      return {
        accessToken,
        refreshToken,
      };
    } catch (err) {
      if (qr.isTransactionActive) {
        await qr.rollbackTransaction();
      }
      throw err;
    } finally {
      await qr.release();
    }
  }

  /**
   * `POST /auth/change-password` (#443 PR3, v2 conditions 5-6): the owner replaces the
   * temporary password with their own, using the `typ:'pwchange'` token that login issued.
   *
   * Order is the CLAUDE.md rule — validate, then argon2 with no connection held, then one
   * short transaction:
   *   1. pure string checks (NFC → 12..128 → blocklist) — a refusal here costs no argon2 and
   *      no pool connection;
   *   2. read the current (temporary) hash on a connection released at once;
   *   3. argon2 verify "new ≠ temp", then argon2 hash — no connection held;
   *   4. one transaction: `UPDATE … WHERE must_change_password AND password_hash = <the hash
   *      we compared against> AND temp_password_expires_at > now()` — 0 rows means the token
   *      was already used, a reset happened meanwhile, or the temp password expired, and it is
   *      a 401. That predicate is what makes the token single-use.
   * Full tokens are signed only after the commit.
   */
  async changePassword(payload: JwtPayload, newPassword: unknown, clientIp?: string) {
    const violation = chosenPasswordViolation(newPassword);
    if (violation) throw weakPassword(violation);
    const password = normalizePassword(newPassword as string);

    const tenantId = payload.tid;
    const userId = payload.sub;
    if (payload.aud !== 'tenant' || !tenantId) {
      throw new UnauthorizedException('Invalid token audience');
    }

    const rows = (await this.readUnderTenant(
      tenantId,
      `SELECT u.password_hash, u.must_change_password, u.is_active, u.username, u.role,
              u.display_name, t.status, t.timezone,
              floor(extract(epoch FROM u.password_changed_at))::bigint AS password_changed_epoch
         FROM users u JOIN tenants t ON t.id = u.tenant_id
        WHERE u.tenant_id = $1 AND u.id = $2`,
      [tenantId, userId],
    )) as Array<{
      password_hash: string;
      must_change_password: boolean;
      is_active: boolean;
      username: string;
      role: string;
      display_name: string;
      status: string;
      timezone: string | null;
      password_changed_epoch: string | null;
    }>;
    const current = rows[0];
    // A pwchange token minted before a reset (which sets `password_changed_at`) belongs to
    // the temporary password that reset just killed — same `iat` rule as `/auth/refresh`.
    if (
      !current ||
      !current.must_change_password ||
      (current.password_changed_epoch !== null &&
        payload.iat < Number(current.password_changed_epoch))
    ) {
      throw new UnauthorizedException('Password change token is no longer valid');
    }
    if (current.status !== 'active') {
      throw new ForbiddenException({ code: 'TENANT_SUSPENDED', message: 'ร้านนี้ถูกระงับการใช้งาน' });
    }
    if (!current.is_active) {
      throw new UnauthorizedException('User is inactive');
    }

    if (await verifyPassword(password, current.password_hash)) {
      throw weakPassword('same_as_temp');
    }
    const newHash = await hashPassword(password);

    const qr = this.ds.createQueryRunner();
    await qr.connect();
    try {
      await qr.startTransaction();
      await qr.query(`SELECT set_config('app.tenant_id', $1, true)`, [tenantId]);
      const updated = returning(
        await qr.query(
          `UPDATE users SET password_hash = $3,
                  must_change_password = FALSE,
                  temp_password_expires_at = NULL,
                  password_changed_at = now()
            WHERE tenant_id = $1 AND id = $2
              AND must_change_password
              AND password_hash = $4
              AND temp_password_expires_at > now()
          RETURNING password_changed_at`,
          [tenantId, userId, newHash, current.password_hash],
        ),
      );
      if (updated.length === 0) {
        await qr.rollbackTransaction();
        throw new UnauthorizedException('Password change token is no longer valid');
      }
      // Never the password or its hash (v2 condition 1 / OWASP checklist).
      await this.audit.log(qr.manager, {
        tenantId,
        userId,
        deviceId: payload.did,
        ip: clientIp,
        action: 'auth.password_changed',
      });
      await qr.commitTransaction();
    } catch (err) {
      if (qr.isTransactionActive) await qr.rollbackTransaction();
      throw err;
    } finally {
      await qr.release();
    }

    const accessPayload: Omit<JwtPayload, 'iss' | 'iat' | 'exp'> = {
      aud: 'tenant',
      sub: userId,
      jti: crypto.randomUUID(),
      typ: 'access',
      tid: tenantId,
      role: payload.role,
      did: payload.did,
      drole: payload.drole,
    };
    const accessToken = this.jwtSigner.sign(accessPayload, '15m');
    const refreshToken = this.jwtSigner.sign(
      { ...accessPayload, typ: 'refresh', jti: crypto.randomUUID() },
      this.calculateRefreshExpiry(current.timezone || 'Asia/Bangkok'),
    );
    return {
      accessToken,
      refreshToken,
      user: {
        id: userId,
        username: current.username,
        role: current.role,
        displayName: current.display_name,
      },
    };
  }

  /** One read under RLS on a connection of its own, released before this returns. */
  private async readUnderTenant(tenantId: string, sql: string, params: unknown[]) {
    const qr = this.ds.createQueryRunner();
    await qr.connect();
    try {
      await qr.startTransaction();
      await qr.query(`SELECT set_config('app.tenant_id', $1, true)`, [tenantId]);
      const rows = await qr.query(sql, params);
      await qr.commitTransaction();
      return rows;
    } catch (err) {
      if (qr.isTransactionActive) await qr.rollbackTransaction();
      throw err;
    } finally {
      await qr.release();
    }
  }

  /**
   * Enrols a device using an enrolment code (ADR-0004).
   * Generates a device token, hashes it, and stores it in the device row.
   */
  async enrolDevice(code: string) {
    const qr = this.ds.createQueryRunner();
    await qr.connect();

    try {
      const normalizedCode = (code || '').trim().toUpperCase();
      const codeHash = await this.hashDeviceToken(normalizedCode);
      const rawDeviceToken = crypto.randomUUID() + '-' + crypto.randomUUID();
      const tokenHash = await this.hashDeviceToken(rawDeviceToken);

      const res = await qr.query(
        `SELECT tenant_id, id FROM auth_enrol_device($1, $2)`,
        [codeHash, tokenHash],
      );

      if (res.length === 0) {
        throw new UnauthorizedException('Invalid or expired enrolment code');
      }

      const dev = res[0];

      // Audit log inside tenant RLS context
      await this.logAuthEventWithRls(qr, dev.tenant_id, {
        tenantId: dev.tenant_id,
        deviceId: dev.id,
        action: 'device.enrol',
      });

      return {
        deviceToken: rawDeviceToken,
      };
    } finally {
      await qr.release();
    }
  }

  private async hashDeviceToken(token: string): Promise<string> {
    const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token));
    return Buffer.from(hash).toString('hex');
  }

  /** `logAuthEventWithRls` on a connection of its own, taken and released here (best-effort). */
  private async logAuthEvent(
    tenantId: string,
    params: Parameters<AuditService['log']>[1],
  ): Promise<void> {
    const qr = this.ds.createQueryRunner();
    try {
      await qr.connect();
      await this.logAuthEventWithRls(qr, tenantId, params);
    } catch (err) {
      // Only `connect()` lands here: logAuthEventWithRls catches its own failures.
      this.logger.error(`Failed to take a connection for the auth audit log: ${err}`);
    } finally {
      await qr.release();
    }
  }

  private async logAuthEventWithRls(
    qr: any,
    tenantId: string,
    params: Parameters<AuditService['log']>[1],
  ): Promise<void> {
    try {
      await qr.startTransaction();
      // `SET LOCAL` takes no bind parameter — `SET LOCAL app.tenant_id = $1` is a
      // plain syntax error, so every auth audit write failed into the catch below and
      // ADR-0009's "every /auth/* endpoint writes audit_log" recorded nothing at all.
      // `set_config(..., true)` is the transaction-scoped form that does take one.
      await qr.query(`SELECT set_config('app.tenant_id', $1, true)`, [tenantId]);
      await this.audit.log(qr.manager, params);
      await qr.commitTransaction();
    } catch (err) {
      try {
        if (qr.isTransactionActive) await qr.rollbackTransaction();
      } catch {
        /* the connection is already gone; the log below is what matters */
      }
      this.logger.error(`Failed to write auth audit log: ${err}`);
    }
  }

  /**
   * Calculates the refresh token expiry timestamp (Unix seconds).
   * Expires at 04:00 AM of the tenant's timezone.
   * If issued after 03:00 AM, expires at 04:00 AM the *next* day (ADR-0009).
   */
  public calculateRefreshExpiry(timezone: string): number {
    let validTimezone = timezone;
    try {
      new Intl.DateTimeFormat(undefined, { timeZone: validTimezone });
    } catch {
      validTimezone = 'Asia/Bangkok';
    }

    const now = new Date();
    const formatter = new Intl.DateTimeFormat('en-US', {
      timeZone: validTimezone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hourCycle: 'h23',
    });
    
    const parts = formatter.formatToParts(now);
    const getPart = (type: string) => parseInt(parts.find(p => p.type === type)?.value || '0', 10);
    
    const year = getPart('year');
    const month = getPart('month') - 1; // 0-indexed
    const day = getPart('day');
    const hour = getPart('hour');
    
    const targetDate = new Date(Date.UTC(year, month, day, 4, 0, 0)); 
    
    if (hour >= 3) {
      targetDate.setUTCDate(targetDate.getUTCDate() + 1);
    }
    
    let targetMs = Date.UTC(targetDate.getUTCFullYear(), targetDate.getUTCMonth(), targetDate.getUTCDate(), 4, 0, 0);
    const targetStr = new Intl.DateTimeFormat('en-US', {
      timeZone: validTimezone,
      timeZoneName: 'longOffset',
    }).format(new Date(targetMs));

    const match = targetStr.match(/GMT([+-]\d{2}):?(\d{2})?/);
    let offsetMinutes = 0;
    if (match) {
      const hours = parseInt(match[1], 10);
      const mins = parseInt(match[2] || '0', 10);
      offsetMinutes = hours * 60 + (hours < 0 ? -mins : mins);
    }
    
    targetMs -= offsetMinutes * 60 * 1000;
    return Math.floor(targetMs / 1000);
  }
}
