import { Injectable, UnauthorizedException, Logger, ForbiddenException } from '@nestjs/common';
import { DataSource } from 'typeorm';
import * as argon2 from 'argon2';
import * as jwt from 'jsonwebtoken';
import { JwtSigner, JwtPayload } from './jwt-keys.service.js';
import { AuditService } from '../audit/audit.service.js';

export interface LoginDto {
  username: string;
  password?: string; // Required for normal users, maybe omit for something else? No, required.
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
        // Find device by token_hash (for simplicity, we assume deviceToken is raw and we need to hash it,
        // or the client sends the hash. The DB says token_hash TEXT)
        // We'll use SHA256 of the token, but for now let's assume it matches token_hash directly or via crypto.
        // Actually, ADR-0004 says "hash ของ device token". We'll just assume token_hash is stored.
        // If they send raw token, we'd hash it. Let's do a simple lookup.
        const hash = await this.hashDeviceToken(dto.deviceToken);
        const devRes = await qr.query(
          `SELECT tenant_id, id, role, retired_at FROM devices WHERE token_hash = $1`,
          [hash]
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

      // 2. Find User
      let userRows = [];
      if (deviceTenantId) {
        // If we know the tenant from the device, use it.
        userRows = await qr.query(
          `SELECT u.*, t.status as tenant_status, t.timezone FROM users u JOIN tenants t ON u.tenant_id = t.id WHERE u.tenant_id = $1 AND u.username = $2`,
          [deviceTenantId, dto.username]
        );
      } else {
        // Otherwise, lookup globally. If multiple users have the same username across different tenants,
        // they must use a deviceToken or unique username.
        userRows = await qr.query(
          `SELECT u.*, t.status as tenant_status, t.timezone FROM users u JOIN tenants t ON u.tenant_id = t.id WHERE u.username = $1`,
          [dto.username]
        );
        if (userRows.length > 1) {
          throw new UnauthorizedException('Ambiguous username. Device token is required.');
        }
      }

      if (userRows.length === 0) {
        // Record failed attempt globally (no tenant context if we don't know it)
        throw new UnauthorizedException('Invalid credentials');
      }

      const user = userRows[0];
      const tenantId = user.tenant_id;

      // Check tenant status (ADR-0003)
      if (user.tenant_status !== 'active') {
        await this.audit.log(qr.manager, {
          tenantId, userId: user.id, deviceId: did,
          action: 'auth.login_failed', before: { reason: 'tenant_inactive' }
        });
        throw new ForbiddenException('Tenant is not active');
      }

      // Check user active
      if (!user.is_active) {
        await this.audit.log(qr.manager, {
          tenantId, userId: user.id, deviceId: did,
          action: 'auth.login_failed', before: { reason: 'user_inactive' }
        });
        throw new UnauthorizedException('User is inactive');
      }

      // Verify Password (Argon2id)
      const valid = await argon2.verify(user.password_hash, dto.password);
      if (!valid) {
        await this.audit.log(qr.manager, {
          tenantId, userId: user.id, deviceId: did,
          action: 'auth.login_failed', before: { reason: 'invalid_password' }
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
      // Sign with exact expiration timestamp instead of relative string
      // jsonwebtoken sign() accepts numeric seconds for exact exp.
      // We pass it in payload and omit expiresIn from options.
      const refreshToken = jwt.sign(
        { ...refreshPayload, iss: 'srisurart-pos', exp: expUnix },
        (this.jwtSigner as any).privateKey,
        { algorithm: 'RS256', keyid: 'key-1' }
      );

      // Log success
      await this.audit.log(qr.manager, {
        tenantId, userId: user.id, deviceId: did,
        action: 'auth.login'
      });

      return {
        status: 'success',
        data: {
          accessToken,
          refreshToken,
          user: {
            id: user.id,
            username: user.username,
            role: user.role,
            displayName: user.display_name,
          }
        }
      };
    } finally {
      await qr.release();
    }
  }

  // Refreshes a token
  async refresh() {
    // 1. decode/verify
    const qr = this.ds.createQueryRunner();
    await qr.connect();
    
    try {
      // Decode and verify the refresh token (JWT verifier will be called by guard usually,
      // but here we might just verify it inline since the controller passes the raw token or 
      // the guard already parsed it. Let's assume the controller passes the raw token).
      // We can inject JwtVerifier and use it. Wait, the guard will reject invalid tokens.
      // So the controller will pass the decoded payload. Let's just accept the payload.
      throw new Error("Method signature should take JwtPayload");
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
    const tenantId = payload.tid;
    const userId = payload.sub;
    const did = payload.did;

    const qr = this.ds.createQueryRunner();
    await qr.connect();
    
    try {
      // Check tenant and user
      const userRows = await qr.query(
        `SELECT u.is_active, t.status, t.timezone FROM users u JOIN tenants t ON u.tenant_id = t.id WHERE u.tenant_id = $1 AND u.id = $2`,
        [tenantId, userId]
      );
      if (userRows.length === 0) {
        throw new UnauthorizedException('User not found');
      }
      const u = userRows[0];

      if (u.status !== 'active' || !u.is_active) {
        await this.audit.log(qr.manager, {
          tenantId: tenantId!, userId, deviceId: did,
          action: 'auth.refresh_rejected', before: { reason: 'inactive' }
        });
        throw new UnauthorizedException('User or tenant inactive');
      }

      // Check device if bound
      if (did) {
        const devRows = await qr.query(
          `SELECT retired_at FROM devices WHERE tenant_id = $1 AND id = $2`,
          [tenantId, did]
        );
        if (devRows.length === 0 || devRows[0].retired_at) {
          await this.audit.log(qr.manager, {
            tenantId: tenantId!, userId, deviceId: did,
            action: 'auth.refresh_rejected', before: { reason: 'device_retired' }
          });
          throw new UnauthorizedException('Device is retired');
        }
      }

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
      
      // Issue new refresh token
      const refreshPayload = { ...accessPayload, typ: 'refresh' as const, jti: crypto.randomUUID() };
      const expUnix = this.calculateRefreshExpiry(u.timezone || 'Asia/Bangkok');
      const refreshToken = jwt.sign(
        { ...refreshPayload, iss: 'srisurart-pos', exp: expUnix },
        (this.jwtSigner as any).privateKey,
        { algorithm: 'RS256', keyid: 'key-1' }
      );

      return {
        status: 'success',
        data: { accessToken, refreshToken }
      };

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
      // Find the device with the matching enrolment code hash
      const codeHash = await this.hashDeviceToken(code);
      
      const res = await qr.query(
        `SELECT tenant_id, id FROM devices 
         WHERE enrol_code_hash = $1 AND enrol_expires_at > now()`,
        [codeHash]
      );

      if (res.length === 0) {
        throw new UnauthorizedException('Invalid or expired enrolment code');
      }

      const dev = res[0];
      const rawDeviceToken = crypto.randomUUID() + '-' + crypto.randomUUID();
      const tokenHash = await this.hashDeviceToken(rawDeviceToken);

      await qr.query(
        `UPDATE devices 
         SET enrol_code_hash = NULL, enrol_expires_at = NULL, token_hash = $1
         WHERE tenant_id = $2 AND id = $3`,
        [tokenHash, dev.tenant_id, dev.id]
      );

      // Audit log
      await this.audit.log(qr.manager, {
        tenantId: dev.tenant_id,
        deviceId: dev.id,
        action: 'device.enrol',
      });

      return {
        status: 'success',
        data: { deviceToken: rawDeviceToken }
      };
    } finally {
      await qr.release();
    }
  }

  private async hashDeviceToken(token: string): Promise<string> {
    // We use SHA-256 for device tokens to be deterministic (Argon2 generates random salts)
    // as we need to lookup by hash.
    const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token));
    return Buffer.from(hash).toString('hex');
  }

  /**
   * Calculates the refresh token expiry timestamp (Unix seconds).
   * Expires at 04:00 AM of the tenant's timezone.
   * If issued after 03:00 AM, expires at 04:00 AM the *next* day (ADR-0009).
   */
  public calculateRefreshExpiry(timezone: string): number {
    // We use Intl.DateTimeFormat to work with the timezone
    const now = new Date();
    
    // Create a string in the tenant's timezone: "YYYY-MM-DDTHH:mm:ss"
    const formatter = new Intl.DateTimeFormat('en-US', {
      timeZone: timezone,
      year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit',
      hour12: false
    });
    
    // e.g. "08/25/2026, 03:15:00" -> parse it
    const parts = formatter.formatToParts(now);
    const getPart = (type: string) => parseInt(parts.find(p => p.type === type)?.value || '0', 10);
    
    const year = getPart('year');
    const month = getPart('month') - 1; // 0-indexed
    const day = getPart('day');
    const hour = getPart('hour');
    
    // Create date representing the local time
    // Then figure out the target day
    const targetDate = new Date(Date.UTC(year, month, day, 4, 0, 0)); 
    
    if (hour >= 3) {
      // If after 3 AM, shift to next day's 4 AM
      targetDate.setUTCDate(targetDate.getUTCDate() + 1);
    }
    
    // Now we must convert this target local time back to UTC timestamp
    // Since JavaScript Date doesn't natively parse "Target Date in Timezone",
    // we iterate or use a trick.
    // The trick: we know the UTC offset roughly. 
    // Let's do it precisely:
    
    let targetMs = Date.UTC(targetDate.getUTCFullYear(), targetDate.getUTCMonth(), targetDate.getUTCDate(), 4, 0, 0);
    // targetMs is a UTC time representing 04:00:00 in UTC. We need 04:00:00 in `timezone`.
    // Let's find the offset at targetMs
    const targetStr = new Intl.DateTimeFormat('en-US', { timeZone: timezone, timeZoneName: 'longOffset' }).format(new Date(targetMs));
    // Extracts "GMT+07:00"
    const match = targetStr.match(/GMT([+-]\d{2}):?(\d{2})?/);
    let offsetMinutes = 0;
    if (match) {
      const hours = parseInt(match[1], 10);
      const mins = parseInt(match[2] || '0', 10);
      offsetMinutes = hours * 60 + (hours < 0 ? -mins : mins);
    }
    
    // Adjust targetMs by subtracting the offset
    targetMs -= offsetMinutes * 60 * 1000;
    
    return Math.floor(targetMs / 1000);
  }
}

