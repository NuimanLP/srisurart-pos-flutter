import {
  BadRequestException,
  ConflictException,
  Inject,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { DataSource } from 'typeorm';
import { createHash, randomBytes } from 'node:crypto';
import type { Redis } from 'ioredis';
import { ADMIN_DATA_SOURCE } from '../infra/db.module.js';
import { REDIS_CACHE } from '../infra/redis.module.js';
import {
  hashPassword,
  passwordPolicyMessage,
  passwordPolicyViolation,
} from '../common/password.js';
import { AuditService } from './audit.service.js';

export class CreateTenantDto {
  code!: string;
  shopName!: string;
  shopNameEn?: string;
  plan?: 'basic' | 'demo' | 'loadtest';
  timezone?: string;
  ownerUsername!: string;
  ownerPassword!: string;
  ownerDisplayName!: string;
}


export const SEED_CATEGORIES = [
  'เครื่องยนต์',
  'ไฟฟ้า',
  'น้ำมัน',
  'เบรก',
  'ตัวถัง',
] as const;

@Injectable()
export class PlatformTenantsService {
  private readonly logger = new Logger(PlatformTenantsService.name);

  constructor(
    @Inject(ADMIN_DATA_SOURCE) private readonly adminDs: DataSource,
    @Inject(REDIS_CACHE) private readonly redisCache: Redis,
    private readonly auditService: AuditService,
  ) {}

  async createTenant(
    dto: CreateTenantDto,
    adminId: string,
    ip?: string,
  ) {
    // Everything below this comment runs BEFORE the argon2 hash and BEFORE the
    // transaction opens (#364): argon2 costs 64 MiB and ~100 ms, and a refusal that
    // happened mid-transaction would have already burnt that and taken a pool
    // connection with it. Validate the input first, then use it (CLAUDE.md).
    if (!dto.code || !dto.shopName || !dto.ownerUsername) {
      throw new BadRequestException('code, shopName, and ownerUsername are required');
    }

    // The same floor `bootstrap:admin` enforces, from the same function — this is a
    // shop's `owner` account, the highest-privileged login in that tenant, and until
    // #364 the endpoint accepted `1234`. `WEAK_PASSWORD` is the client-translatable
    // code from `02_API_SCREENS.md §8.1`; the English `message` is for the operator
    // running the provisioning call.
    const pwViolation = passwordPolicyViolation(dto.ownerPassword);
    if (pwViolation) {
      throw new BadRequestException({
        code: 'WEAK_PASSWORD',
        message: passwordPolicyMessage(pwViolation, 'ownerPassword'),
      });
    }

    const plan = dto.plan ?? 'basic';
    const timezone = dto.timezone ?? 'Asia/Bangkok';
    const shopNameEn = dto.shopNameEn ?? '';
    const enrolCode = randomBytes(4).toString('hex').toUpperCase(); // e.g. "A1B2C3D4"
    // Hashed out here rather than inside the transaction: argon2id at 64 MiB / 3 passes
    // is the slowest thing on this path, and holding an open transaction (and its pool
    // connection) across it buys nothing — the hash depends on no row we read.
    const ownerPasswordHash = await hashPassword(dto.ownerPassword);

    let tenantId: string;

    try {
      tenantId = await this.adminDs.transaction(async (manager) => {
        // 1. Tenants table
        const tenantRes = await manager.query(
          `INSERT INTO tenants (code, shop_name, shop_name_en, plan, status, timezone)
           VALUES ($1, $2, $3, $4, 'active', $5)
           RETURNING id`,
          [dto.code, dto.shopName, shopNameEn, plan, timezone],
        );
        const tid = tenantRes[0].id;

        // 2. Owner user
        await manager.query(
          `INSERT INTO users (tenant_id, username, password_hash, display_name, role, is_active)
           VALUES ($1, $2, $3, $4, 'owner', true)`,
          [tid, dto.ownerUsername, ownerPasswordHash, dto.ownerDisplayName || dto.ownerUsername],
        );

        // 3. Settings row
        await manager.query(
          `INSERT INTO settings (tenant_id, shop_name, shop_name_en, tax_rate, quote_valid_days)
           VALUES ($1, $2, $3, 7, 30)`,
          [tid, dto.shopName, shopNameEn],
        );

        // 4. 5 Seed categories
        for (let i = 0; i < SEED_CATEGORIES.length; i++) {
          await manager.query(
            `INSERT INTO categories (tenant_id, name, position) VALUES ($1, $2, $3)`,
            [tid, SEED_CATEGORIES[i], i],
          );
        }

        // 5. Initial POS Device (device_no = 1, role = 'pos')
        const enrolExpires = new Date(Date.now() + 7 * 86400 * 1000);
        const enrolCodeHash = createHash('sha256').update(enrolCode).digest('hex');
        await manager.query(
          `INSERT INTO devices (tenant_id, id, label, device_no, role, enrol_code_hash, enrol_expires_at)
           VALUES ($1, $2, $3, 1, 'pos', $4, $5)`,
          [tid, 'pos1', 'POS #1', enrolCodeHash, enrolExpires],
        );

        // 6. Audit log inside the business transaction
        await this.auditService.log(manager, {
          tenantId: tid,
          platformAdminId: adminId,
          action: 'platform.tenant.create',
          after: { code: dto.code, shopName: dto.shopName, plan, timezone },
          ip,
        });

        return tid;
      });
    } catch (err: unknown) {
      const error = err as { code?: string; message?: string };
      if (error.code === '23505') {
        throw new ConflictException('Tenant code or username already exists');
      }
      throw error;
    }

    return {
      tenantId,
      code: dto.code,
      shopName: dto.shopName,
      ownerUsername: dto.ownerUsername,
      enrolCode,
    };
  }

  async updateStatus(
    tenantId: string,
    status: 'active' | 'suspended' | 'closed',
    adminId: string,
    ip?: string,
  ) {
    if (!['active', 'suspended', 'closed'].includes(status)) {
      throw new BadRequestException('Status must be active, suspended, or closed');
    }

    await this.adminDs.transaction(async (manager) => {
      const res = await manager.query(
        `UPDATE tenants SET status = $1 WHERE id = $2 RETURNING id, status`,
        [status, tenantId],
      );

      if (!res || res.length === 0) {
        throw new NotFoundException(`Tenant ${tenantId} not found`);
      }

      await this.auditService.log(manager, {
        tenantId,
        platformAdminId: adminId,
        action: 'platform.tenant.update_status',
        after: { status },
        ip,
      });
    });

    // Immediately purge status cache
    await this.redisCache.del(`t:${tenantId}:status`);

    return { tenantId, status };
  }

  async listTenants(adminId: string, ip?: string) {
    const tenants = await this.adminDs.query(
      `SELECT id, code, shop_name, shop_name_en, plan, status, timezone, created_at FROM tenants ORDER BY created_at DESC`,
    );

    try {
      await this.auditService.log(this.adminDs, {
        tenantId: '00000000-0000-0000-0000-000000000000',
        platformAdminId: adminId,
        action: 'platform.tenant.list',
        ip,
      });
    } catch (err) {
      // In read endpoints like listTenants, do not fail requests on audit logging errors
      this.logger.warn(`Failed to write audit log for listTenants: ${err}`);
    }

    return tenants;
  }

  async getTenantStatus(tenantId: string): Promise<string> {
    const cacheKey = `t:${tenantId}:status`;
    const cached = await this.redisCache.get(cacheKey);
    if (cached) return cached;

    const res = await this.adminDs.query(
      `SELECT status FROM tenants WHERE id = $1`,
      [tenantId],
    );

    if (!res || res.length === 0) {
      return 'suspended';
    }

    const status = res[0].status;
    await this.redisCache.setex(cacheKey, 300, status);
    return status;
  }
}
