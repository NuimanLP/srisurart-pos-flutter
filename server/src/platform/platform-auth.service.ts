import { Inject, Injectable, UnauthorizedException } from '@nestjs/common';
import { DataSource } from 'typeorm';
import { ADMIN_DATA_SOURCE } from '../infra/db.module.js';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { signJwt } from '../common/jwt.js';
import { verifyPassword } from '../common/password.js';
import { AuditService } from './audit.service.js';

@Injectable()
export class PlatformAuthService {
  constructor(
    @Inject(ADMIN_DATA_SOURCE) private readonly adminDs: DataSource,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    private readonly auditService: AuditService,
  ) {}

  async login(username: string, password: string, ip?: string) {
    const res = await this.adminDs.query(
      `SELECT id, username, password_hash, display_name, is_active FROM platform_admins WHERE username = $1`,
      [username],
    );

    const admin = res[0];
    if (!admin || !admin.is_active || !verifyPassword(password, admin.password_hash)) {
      throw new UnauthorizedException('Invalid platform admin credentials');
    }

    const token = signJwt(
      {
        iss: 'srisurart-pos',
        aud: 'platform',
        sub: admin.id,
        username: admin.username,
        exp: Math.floor(Date.now() / 1000) + 86400,
      },
      this.config.jwtPlatformSecret,
    );

    // Platform audit log requirement
    await this.auditService.log({
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
