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
import type { Redis } from 'ioredis';
import { DataSource } from 'typeorm';
import { DeviceRoleForbiddenException } from '../device-role-forbidden.exception.js';
import { REDIS_CACHE } from '../../infra/redis.module.js';
import { setRequestTenant } from '../request-context.js';

export async function hashDeviceToken(token: string): Promise<string> {
  const hash = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(token),
  );
  return Buffer.from(hash).toString('hex');
}

/**
 * Guard for `POST /sync/push` (08_PHASE2_SPEC §8.1):
 * - Accepts `X-Device-Token` header.
 * - Resolves device via `auth_lookup_device_by_token(hash)`.
 * - Requires `role === 'pos'` and `retired_at IS NULL`.
 * - Checks tenant status is 'active'.
 * - Finds single active user of tenant. If none -> 403 FORBIDDEN ("No active user found for tenant").
 * - Sets tenant on request scope via `setRequestTenant`.
 */
@Injectable()
export class DeviceTokenGuard implements CanActivate {
  private readonly logger = new Logger(DeviceTokenGuard.name);

  constructor(
    @Inject(REDIS_CACHE) private readonly redisCache: Redis,
    private readonly ds: DataSource,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest();

    const rawToken = request.headers['x-device-token'];
    const deviceToken = Array.isArray(rawToken) ? rawToken[0] : rawToken;
    if (!deviceToken || typeof deviceToken !== 'string' || !deviceToken.trim()) {
      throw new UnauthorizedException('Missing or invalid X-Device-Token header');
    }

    const tokenHash = await hashDeviceToken(deviceToken.trim());

    // 1. Lookup device, tenant status, and active user via SECURITY DEFINER function
    const rows = (await this.ds.query(
      `SELECT tenant_id, id, role, retired_at, tenant_status, active_user_id
         FROM auth_lookup_device_and_active_user($1)`,
      [tokenHash],
    )) as {
      tenant_id: string;
      id: string;
      role: string;
      retired_at: Date | null;
      tenant_status: string;
      active_user_id: string | null;
    }[];

    if (rows.length === 0) {
      throw new UnauthorizedException('Invalid device token');
    }

    const dev = rows[0];
    if (dev.retired_at !== null) {
      throw new UnauthorizedException('Device has been retired');
    }

    if (dev.role !== 'pos') {
      throw new DeviceRoleForbiddenException();
    }

    if (dev.tenant_status !== 'active') {
      throw new HttpException(
        { code: 'TENANT_SUSPENDED', message: 'ร้านนี้ถูกระงับการใช้งาน' },
        HttpStatus.FORBIDDEN,
      );
    }

    if (!dev.active_user_id) {
      throw new HttpException(
        {
          code: 'FORBIDDEN',
          message: 'No active user found for tenant',
        },
        HttpStatus.FORBIDDEN,
      );
    }

    // 2. Name tenant on request scope
    setRequestTenant(dev.tenant_id);

    // 3. Attach user/device context to request
    request.user = {
      userId: dev.active_user_id,
      tenantId: dev.tenant_id,
      role: 'owner',
      deviceId: dev.id,
      deviceRole: dev.role,
    };
    request.device = {
      id: dev.id,
      role: dev.role,
    };

    return true;
  }
}
