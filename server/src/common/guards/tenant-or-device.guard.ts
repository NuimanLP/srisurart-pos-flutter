import {
  Injectable,
  CanActivate,
  ExecutionContext,
  UnauthorizedException,
} from '@nestjs/common';
import type { Request } from 'express';
import { DeviceTokenGuard } from './device-token.guard.js';
import { TenantGuard } from './tenant.guard.js';

@Injectable()
export class TenantOrDeviceTokenGuard implements CanActivate {
  constructor(
    private readonly tenantGuard: TenantGuard,
    private readonly deviceTokenGuard: DeviceTokenGuard,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const req = context.switchToHttp().getRequest<Request>();
    const authHeader = req.headers.authorization;
    if (authHeader && authHeader.startsWith('Bearer ')) {
      return this.tenantGuard.canActivate(context);
    }
    const rawDeviceToken = req.headers['x-device-token'];
    if (rawDeviceToken) {
      return this.deviceTokenGuard.canActivate(context);
    }
    throw new UnauthorizedException(
      'Missing Authorization or X-Device-Token header',
    );
  }
}
