import {
  CanActivate,
  ExecutionContext,
  ForbiddenException,
  Inject,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { DataSource } from 'typeorm';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { verifyJwt } from '../common/jwt.js';
import { PlatformTenantsService } from '../platform/platform-tenants.service.js';

@Injectable()
export class TenantGuard implements CanActivate {
  constructor(
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    private readonly tenantsService: PlatformTenantsService,
    private readonly ds: DataSource,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const req = context.switchToHttp().getRequest();
    const authHeader = req.headers['authorization'];
    if (!authHeader || typeof authHeader !== 'string') {
      throw new UnauthorizedException('Missing Authorization header');
    }

    const [scheme, token] = authHeader.split(' ');
    if (scheme !== 'Bearer' || !token) {
      throw new UnauthorizedException('Invalid Authorization header format');
    }

    const payload = verifyJwt(token, this.config.jwtTenantSecret);
    if (!payload) {
      throw new UnauthorizedException('Invalid or expired tenant token');
    }

    if (payload.aud !== 'tenant' || !payload.tid) {
      throw new ForbiddenException('Token audience is not tenant or missing tenant ID');
    }

    const status = await this.tenantsService.getTenantStatus(payload.tid);
    if (status !== 'active') {
      throw new ForbiddenException('TENANT_SUSPENDED: ร้านค้าอยู่ในสถานะถูกระงับการใช้งาน');
    }

    // Attach to request
    req.tenantId = payload.tid;
    req.user = {
      id: payload.sub,
      role: payload.role,
    };
    req.device = {
      id: payload.did,
      role: payload.drole,
    };

    // Execute SET LOCAL app.tenant_id
    await this.ds.query(`SELECT set_config('app.tenant_id', $1, true)`, [payload.tid]);

    return true;
  }
}
