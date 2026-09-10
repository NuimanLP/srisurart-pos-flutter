import { Injectable, CanActivate, ExecutionContext, UnauthorizedException, ForbiddenException, Logger } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { JwtVerifier } from '../../auth/jwt-keys.service.js';
import { REQUIRE_DEVICE_ROLE_KEY } from '../decorators/device-role.decorator.js';
import { DataSource } from 'typeorm';

@Injectable()
export class TenantGuard implements CanActivate {
  private readonly logger = new Logger(TenantGuard.name);

  constructor(
    private readonly jwtVerifier: JwtVerifier,
    private readonly reflector: Reflector,
    private readonly ds: DataSource,
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
      // 2. Verify Token
      const payload = this.jwtVerifier.verify(token, 'access');

      // 3. Check Audience
      if (payload.aud !== 'tenant') {
        throw new ForbiddenException('Invalid token audience');
      }

      if (!payload.tid) {
        throw new ForbiddenException('Token missing tenant id');
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
        [context.getHandler(), context.getClass()]
      );

      if (requiredDeviceRole) {
        if (!payload.drole) {
          throw new ForbiddenException('Endpoint requires a device role, but token has none');
        }
        // If it requires 'pos', only 'pos' is allowed.
        // If it requires 'backoffice', actually 'both' means any device role can access.
        // The ADR says pos-only endpoints need 'pos'.
        if (requiredDeviceRole === 'pos' && payload.drole !== 'pos') {
          throw new ForbiddenException('Endpoint requires a POS device');
        }
      }

      // 6. Check Tenant Status (ADR-0003)
      // Check if tenant is active
      const res = await this.ds.query(`SELECT status FROM tenants WHERE id = $1`, [payload.tid]);
      if (res.length === 0) {
        throw new ForbiddenException('Tenant not found');
      }
      if (res[0].status !== 'active') {
        throw new ForbiddenException(`Tenant is ${res[0].status}`);
      }

      return true;
    } catch (err) {
      if (err instanceof ForbiddenException || err instanceof UnauthorizedException) {
        throw err;
      }
      this.logger.warn(`Token validation failed: ${err}`);
      throw new UnauthorizedException('Invalid token');
    }
  }
}
