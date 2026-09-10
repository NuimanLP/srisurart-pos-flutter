import { Injectable, UnauthorizedException, Logger, ForbiddenException } from '@nestjs/common';
import { DataSource } from 'typeorm';
import * as crypto from 'node:crypto';
import * as argon2 from 'argon2';
import { JwtSigner, type JwtPayload } from './jwt-keys.service.js';
import { AuditService } from '../audit/audit.service.js';

export interface LoginDto {
  username: string;
  password?: string;
  deviceToken?: string;
}

@Injectable()
export class AuthService {
  private readonly logger = new Logger(AuthService.name);

  constructor(
    private readonly ds: DataSource,
    private readonly jwtSigner: JwtSigner,
    private readonly audit: AuditService,
  ) {}

  async login(dto: LoginDto) {
    if (!dto.password) {
      throw new UnauthorizedException('Password is required');
    }

    const qr = this.ds.createQueryRunner();
    await qr.connect();
    
    try {
      // 1. Resolve device info from deviceToken if provided (ADR-0004)
      let deviceTenantId: string | null = null;
      let did: string | undefined;
      let drole: string | undefined;

      if (dto.deviceToken) {
        const hash = await this.hashDeviceToken(dto.deviceToken);
        const devRes = await qr.query(
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

      // 2. Find User via SECURITY DEFINER function to respect RLS
      const userRows = await qr.query(
        `SELECT * FROM auth_lookup_user_for_login($1, $2)`,
        [dto.username, deviceTenantId ?? null],
      );

      if (userRows.length > 1) {
        throw new UnauthorizedException('Ambiguous username. Device token is required.');
      }

      if (userRows.length === 0) {
        this.logger.warn(`Login failed: user not found for username=${dto.username}`);
        throw new UnauthorizedException('Invalid credentials');
      }

      const user = userRows[0];
      const tenantId = user.tenant_id;

      // Check tenant status (ADR-0003)
      if (user.tenant_status !== 'active') {
        await this.logAuthEventWithRls(qr, tenantId, {
          tenantId,
          userId: user.id,
          deviceId: did,
          action: 'auth.login_failed',
          before: { reason: 'tenant_inactive' },
        });
        throw new ForbiddenException({
          code: 'TENANT_SUSPENDED',
          message: 'ร้านนี้ถูกระงับการใช้งาน',
        });
      }

      // Check user active
      if (!user.is_active) {
        await this.logAuthEventWithRls(qr, tenantId, {
          tenantId,
          userId: user.id,
          deviceId: did,
          action: 'auth.login_failed',
          before: { reason: 'user_inactive' },
        });
        throw new UnauthorizedException('User is inactive');
      }

      // Verify Password (Argon2id)
      let valid = false;
      try {
        valid = await argon2.verify(user.password_hash, dto.password);
      } catch (err) {
        this.logger.warn(`Password verification failed to parse hash for userId=${user.id}: ${err}`);
        valid = false;
      }
      if (!valid) {
        await this.logAuthEventWithRls(qr, tenantId, {
          tenantId,
          userId: user.id,
          deviceId: did,
          action: 'auth.login_failed',
          before: { reason: 'invalid_password' },
        });
        throw new UnauthorizedException('Invalid credentials');
      }

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

      const accessToken = this.jwtSigner.sign(payload, '15m');
      
      const refreshPayload = { ...payload, typ: 'refresh' as const, jti: crypto.randomUUID() };
      const expUnix = this.calculateRefreshExpiry(user.timezone || 'Asia/Bangkok');
      const refreshToken = this.jwtSigner.sign(refreshPayload, expUnix);

      // Log success
      await this.logAuthEventWithRls(qr, tenantId, {
        tenantId,
        userId: user.id,
        deviceId: did,
        action: 'auth.login',
      });

      return {
        accessToken,
        refreshToken,
        user: {
          id: user.id,
          username: user.username,
          role: user.role,
          displayName: user.display_name,
        },
      };
    } finally {
      await qr.release();
    }
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
      await qr.query(`SET LOCAL app.tenant_id = $1`, [tenantId]);

      // Check tenant and user under RLS
      const userRows = await qr.query(
        `SELECT u.is_active, t.status, t.timezone FROM users u JOIN tenants t ON u.tenant_id = t.id WHERE u.tenant_id = $1 AND u.id = $2`,
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

  private async logAuthEventWithRls(
    qr: any,
    tenantId: string,
    params: Parameters<AuditService['log']>[1],
  ): Promise<void> {
    try {
      await qr.startTransaction();
      await qr.query(`SET LOCAL app.tenant_id = $1`, [tenantId]);
      await this.audit.log(qr.manager, params);
      await qr.commitTransaction();
    } catch (err) {
      if (qr.isTransactionActive) {
        await qr.rollbackTransaction();
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
