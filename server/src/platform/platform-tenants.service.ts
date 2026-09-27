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
import { generateTempPassword, hashPassword } from '../common/password.js';
import { returning } from '../common/sql.js';
import { AuditService } from './audit.service.js';

export class CreateTenantDto {
  code!: string;
  shopName!: string;
  shopNameEn?: string;
  plan?: 'basic' | 'demo' | 'loadtest';
  timezone?: string;
  ownerUsername!: string;
  ownerDisplayName!: string;
}

/**
 * #443 PR3 (v2 condition 2, owner decision 2026-09-26): a temporary owner password lives
 * 7 days from provisioning and 24 hours from a reset. Unused past that, the platform team
 * issues a new one.
 */
const CREATE_TEMP_PASSWORD_TTL_HOURS = 7 * 24;
const RESET_TEMP_PASSWORD_TTL_HOURS = 24;


export const SEED_CATEGORIES = [
  'เครื่องยนต์',
  'ไฟฟ้า',
  'น้ำมัน',
  'เบรก',
  'ตัวถัง',
] as const;

/**
 * #443 PR2: a non-UUID `:id` used to reach Postgres unvalidated and come back as a driver-level
 * 22P02 — a 500, not a 400 — on `updateStatus`; the two new methods below would have had the
 * same bug. Validate the shape before any query (CLAUDE.md: validate first, then use).
 */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function assertValidTenantId(tenantId: string): void {
  if (!UUID_RE.test(tenantId)) {
    throw new BadRequestException({
      code: 'INVALID_TENANT_ID',
      message: 'tenantId must be a valid UUID',
    });
  }
}

/**
 * Owner decision 2026-09-27 (#443 PR2, Q3): a reissued code lives 7 days, the same as the
 * first device's code from `createTenant` below — not 15 minutes like `POST /devices`,
 * because a platform admin reissuing one is handing it to a shop over the phone or in
 * person, not a browser that will redeem it within the next few minutes.
 */
const REISSUE_ENROL_CODE_TTL_DAYS = 7;

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
    // #443 PR3 (owner decision 2026-09-26/27): the admin never chooses — or knows past this
    // one response — the owner's password. A caller still sending `ownerPassword` is running
    // the old contract and is refused loudly rather than having the field silently ignored.
    if (dto && Object.prototype.hasOwnProperty.call(dto, 'ownerPassword')) {
      throw new BadRequestException({
        code: 'OWNER_PASSWORD_NOT_ACCEPTED',
        message:
          'ownerPassword is no longer accepted: the server generates a temporary password and returns it once',
      });
    }
    if (!dto.code || !dto.shopName || !dto.ownerUsername) {
      throw new BadRequestException('code, shopName, and ownerUsername are required');
    }

    const plan = dto.plan ?? 'basic';
    const timezone = dto.timezone ?? 'Asia/Bangkok';
    const shopNameEn = dto.shopNameEn ?? '';
    const enrolCode = randomBytes(4).toString('hex').toUpperCase(); // e.g. "A1B2C3D4"
    // Server-generated (CSPRNG, v2 condition 1), returned once below, never logged or audited.
    const tempPassword = generateTempPassword();
    // Hashed out here rather than inside the transaction: argon2id at 64 MiB / 3 passes
    // is the slowest thing on this path, and holding an open transaction (and its pool
    // connection) across it buys nothing — the hash depends on no row we read.
    const ownerPasswordHash = await hashPassword(tempPassword);
    let tempPasswordExpiresAt!: Date;

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

        // 2. Owner user — on a temporary password that must be changed at first login.
        const userRes = await manager.query(
          `INSERT INTO users (tenant_id, username, password_hash, display_name, role, is_active,
                              must_change_password, temp_password_expires_at)
           VALUES ($1, $2, $3, $4, 'owner', true,
                   true, now() + make_interval(hours => $5))
           RETURNING temp_password_expires_at`,
          [
            tid,
            dto.ownerUsername,
            ownerPasswordHash,
            dto.ownerDisplayName || dto.ownerUsername,
            CREATE_TEMP_PASSWORD_TTL_HOURS,
          ],
        );
        tempPasswordExpiresAt = userRes[0].temp_password_expires_at;

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
      // Shown exactly once. The admin hands it to the shop in person/by phone; the owner
      // must replace it at first login (v2 condition 3).
      tempPassword,
      tempPasswordExpiresAt: new Date(tempPasswordExpiresAt).toISOString(),
      enrolCode,
    };
  }

  /**
   * `POST /platform/tenants/:id/owner/temp-password` (#443 PR3, v2 condition 7) — the answer
   * to "the owner forgot the password" after the team has verified the caller out of band
   * (a call back to the number/e-mail recorded at provisioning — never the incoming one).
   *
   * Issues a new server-generated temporary password (24 h). The old password — temporary or
   * the owner's own — stops working in the same UPDATE, and `password_changed_at = now()`
   * kills every refresh token issued before it (ADR-0009 addendum 2026-09-26) and every
   * `pwchange` token of an earlier temp password. Generated and hashed before the
   * transaction; the audit row names the admin and never carries the secret.
   */
  async issueOwnerTempPassword(tenantId: string, adminId: string, ip?: string) {
    assertValidTenantId(tenantId);

    const tempPassword = generateTempPassword();
    const passwordHash = await hashPassword(tempPassword);

    const row = await this.adminDs.transaction(async (manager) => {
      // One active user per tenant (`uq_users_one_active`), so this touches at most one row.
      const rows = returning<{ id: string; username: string; temp_password_expires_at: Date }>(
        await manager.query(
          `UPDATE users SET password_hash = $2,
                  must_change_password = TRUE,
                  temp_password_expires_at = now() + make_interval(hours => $3),
                  password_changed_at = now()
            WHERE tenant_id = $1 AND is_active
          RETURNING id, username, temp_password_expires_at`,
          [tenantId, passwordHash, RESET_TEMP_PASSWORD_TTL_HOURS],
        ),
      );
      if (rows.length === 0) {
        const tenant = await manager.query(`SELECT 1 FROM tenants WHERE id = $1`, [tenantId]);
        throw new NotFoundException(
          tenant.length === 0
            ? `Tenant ${tenantId} not found`
            : { code: 'OWNER_NOT_FOUND', message: 'This tenant has no active owner' },
        );
      }
      await this.auditService.log(manager, {
        tenantId,
        platformAdminId: adminId,
        action: 'platform.owner.temp_password_issued',
        entity: 'users',
        entityId: rows[0].id,
        after: { tempPasswordExpiresAt: rows[0].temp_password_expires_at },
        ip,
      });
      return rows[0];
    });

    return {
      tenantId,
      ownerUsername: row.username,
      tempPassword,
      tempPasswordExpiresAt: new Date(row.temp_password_expires_at).toISOString(),
    };
  }

  async updateStatus(
    tenantId: string,
    status: 'active' | 'suspended' | 'closed',
    adminId: string,
    ip?: string,
  ) {
    assertValidTenantId(tenantId);
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

  /**
   * `POST /platform/tenants/:id/devices/:deviceId/enrol-code` (#443 PR2) — the answer to
   * "the shop's first device's enrolCode expired and it never enrolled": a platform admin
   * can issue a fresh one, but only for a device row that has **never** been enrolled
   * (`token_hash IS NULL`) and is not retired. Once a device is enrolled, adding a second
   * POS-role device or re-provisioning is `POST /devices` from an already-bound session
   * (ADR-0004) — this endpoint never touches a device that already has an owner-visible
   * token, so it can never be used to silently swap out a shop's working device.
   *
   * Single `UPDATE … WHERE token_hash IS NULL AND retired_at IS NULL`, atomic against a
   * concurrent `POST /auth/device` (`auth_enrol_device` takes `FOR UPDATE` on the same row)
   * and against a concurrent retire: whichever commits first decides the row, and the loser
   * sees the post-image (rows.length === 0, then the SELECT below explains why).
   *
   * The code itself is generated and hashed exactly as `createTenant` (above) and
   * `DevicesService.createIn` do — 8 upper-case hex characters, SHA-256 hex at rest — and,
   * like both of those, it is returned to the caller exactly once and never logged or put
   * in `audit_log`.
   */
  async reissueEnrolCode(
    tenantId: string,
    deviceId: string,
    adminId: string,
    ip?: string,
  ): Promise<{ deviceId: string; enrolCode: string; enrolExpiresAt: string }> {
    assertValidTenantId(tenantId);

    const enrolCode = randomBytes(4).toString('hex').toUpperCase();
    const enrolCodeHash = createHash('sha256').update(enrolCode).digest('hex');

    const enrolExpiresAt = await this.adminDs.transaction(async (manager) => {
      // `returning()`: TypeORM's Postgres driver hands `manager.query` back as
      // `[rows, affectedCount]` for an UPDATE, not `rows` directly (common/sql.ts) — reading
      // `rows[0]` straight off the raw result silently yields `undefined` here.
      const rows = returning<{ enrol_expires_at: Date }>(
        await manager.query(
          `UPDATE devices
              SET enrol_expires_at = now() + make_interval(days => $4), enrol_code_hash = $3
            WHERE tenant_id = $1 AND id = $2
              AND token_hash IS NULL AND retired_at IS NULL
          RETURNING enrol_expires_at`,
          [tenantId, deviceId, enrolCodeHash, REISSUE_ENROL_CODE_TTL_DAYS],
        ),
      );

      if (rows.length === 0) {
        // Distinguish "no such device" from "this device already has an owner" — the SELECT
        // costs nothing extra (the UPDATE above already proved there is no row to lock) and
        // ops needs to know which one it is. Neither message is shown to a shop.
        const existing = await manager.query(
          `SELECT 1 FROM devices WHERE tenant_id = $1 AND id = $2`,
          [tenantId, deviceId],
        );
        if (existing.length === 0) {
          throw new NotFoundException({
            code: 'DEVICE_NOT_FOUND',
            message: 'Device not found',
          });
        }
        throw new ConflictException({
          code: 'DEVICE_ALREADY_ENROLLED',
          message:
            'This device has already been enrolled, or is retired; a new enrolment code cannot be issued for it.',
        });
      }

      // Never the code itself: `audit_log` is read by people who must not be able to enrol
      // (same rule as `DevicesService.createIn`).
      await this.auditService.log(manager, {
        tenantId,
        platformAdminId: adminId,
        action: 'platform.device.enrol_code_reissued',
        entity: 'devices',
        entityId: deviceId,
        after: { enrolExpiresAt: rows[0].enrol_expires_at },
        ip,
      });

      return rows[0].enrol_expires_at as Date;
    });

    return {
      deviceId,
      enrolCode,
      enrolExpiresAt: new Date(enrolExpiresAt).toISOString(),
    };
  }

  /**
   * `GET /platform/tenants/:id` (#443 PR2) — the tenant row, its devices (never a secret or
   * a hash), and its 20 most recent import jobs. This is the read the platform CLI/UI needs
   * to show a shop's device ids before calling `reissueEnrolCode` above, and to see whether
   * an import ever failed — neither is answerable from `GET /platform/tenants` today.
   */
  async getTenantDetail(tenantId: string, adminId: string, ip?: string) {
    assertValidTenantId(tenantId);

    const tenantRows = await this.adminDs.query(
      `SELECT id, code, shop_name, shop_name_en, plan, status, timezone, created_at
         FROM tenants WHERE id = $1`,
      [tenantId],
    );
    if (tenantRows.length === 0) {
      throw new NotFoundException(`Tenant ${tenantId} not found`);
    }

    const deviceRows = await this.adminDs.query(
      `SELECT id, label, role,
              token_hash IS NOT NULL AS enrolled,
              -- Raw, even when past: "never enrolled, code expired" is exactly the case ops
              -- needs to see before reissuing (auth_enrol_device NULLs it on enrol anyway).
              enrol_expires_at,
              retired_at
         FROM devices
        WHERE tenant_id = $1
        ORDER BY device_no`,
      [tenantId],
    );

    const importJobRows = await this.adminDs.query(
      `SELECT id, status, error, created_at, started_at, finished_at
         FROM import_jobs
        WHERE tenant_id = $1
        ORDER BY created_at DESC
        LIMIT 20`,
      [tenantId],
    );

    try {
      await this.auditService.log(this.adminDs, {
        tenantId,
        platformAdminId: adminId,
        action: 'platform.tenant.read',
        ip,
      });
    } catch (err) {
      // Same rule as listTenants below: a read must not fail the request over an audit hiccup.
      this.logger.warn(`Failed to write audit log for getTenantDetail: ${err}`);
    }

    return {
      tenant: tenantRows[0],
      devices: (deviceRows as Array<{
        id: string;
        label: string;
        role: string;
        enrolled: boolean;
        enrol_expires_at: Date | null;
        retired_at: Date | null;
      }>).map((d) => ({
        id: d.id,
        label: d.label,
        role: d.role,
        enrolled: d.enrolled,
        enrolExpiresAt: d.enrol_expires_at ? new Date(d.enrol_expires_at).toISOString() : null,
        retiredAt: d.retired_at ? new Date(d.retired_at).toISOString() : null,
      })),
      importJobs: importJobRows,
    };
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
