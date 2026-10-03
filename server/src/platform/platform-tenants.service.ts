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
import { newId } from '../common/ids.js';
import { returning } from '../common/sql.js';
import { ReviewItemsService } from '../review-items/review-items.service.js';
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

/** Same limits as the shop-side `POST /devices` (`devices.controller.ts`, `devices.service.ts`). */
const DEVICE_LABEL_MAX_LENGTH = 100;
const MAX_DEVICE_NO = 99;

export interface ReplaceDeviceResult {
  retiredDeviceId: string;
  retiredAt: string;
  device: { id: string; label: string; role: 'pos' | 'backoffice'; deviceNo: number };
  enrolCode: string;
  enrolExpiresAt: string;
}

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
      // Owner decision 2026-10-03 (#443): `closed` is terminal — no transition out of it, and
      // closed → closed is refused too. The guard sits in the UPDATE itself so a concurrent
      // close cannot slip between a read and the write. `returning()`: an UPDATE comes back
      // as `[rows, count]` (common/sql.ts) — reading `.length` off the raw result made the
      // 404 below unreachable before this change.
      const res = returning<{ id: string }>(
        await manager.query(
          `UPDATE tenants SET status = $1 WHERE id = $2 AND status <> 'closed' RETURNING id`,
          [status, tenantId],
        ),
      );

      if (res.length === 0) {
        const existing = await manager.query(`SELECT status FROM tenants WHERE id = $1`, [tenantId]);
        if (existing.length === 0) {
          throw new NotFoundException(`Tenant ${tenantId} not found`);
        }
        throw new ConflictException({
          code: 'TENANT_CLOSED',
          message: 'This tenant is closed; closed is terminal and its status cannot be changed.',
        });
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
   * `POST /platform/tenants/:id/devices/:deviceId/replace` (#476) — the ops escape hatch for
   * a shop whose only enrolled device is gone (browser data cleared, machine lost). With no
   * enrolled browser left, the shop's own `/devices` routes are unreachable (they need `did`,
   * ADR-0004), and `reissueEnrolCode` above refuses an enrolled device by design. This retires
   * the lost device and creates its replacement — same role, a **new** `device_no` (F8) — and
   * returns the replacement's one-time enrolment code. Not a shop-facing feature.
   *
   * One transaction, the same order and checks as the shop's own retire + create
   * (`DevicesService.retireIn`/`createIn`, `ShiftsService.openIn`):
   *   1. the per-tenant `devices:` advisory lock `createIn` takes, so `device_no = max + 1`
   *      cannot race a shop-side `POST /devices`;
   *   2. the device row `FOR NO KEY UPDATE` (serialises against `auth_enrol_device`, a shop
   *      retire, and `POST /shifts/open`), then its active shift `FOR UPDATE` (devices → shifts);
   *   3. an open drawer or unsent offline ops refuse with 409 unless `force` with a `note` —
   *      the platform admin cannot count a drawer, so a forced open drawer is archived
   *      uncounted (`auto_archived`) with a `shift_uncounted` review item, exactly what the
   *      device's next `POST /shifts/open` would have done; forced unsent ops leave a
   *      `device_force_retired` review item, as the shop-side force does;
   *   4. retire (enrol code cleared), insert the replacement, two `audit_log` rows naming the
   *      platform admin. The code is never logged or audited.
   *
   * Not idempotent, like every platform route: a lost response is recovered with
   * `reissueEnrolCode` on the replacement, which has never been enrolled.
   */
  async replaceDevice(
    tenantId: string,
    deviceId: string,
    input: { force?: unknown; note?: unknown; label?: unknown },
    adminId: string,
    ip?: string,
  ): Promise<ReplaceDeviceResult> {
    assertValidTenantId(tenantId);
    if (input.force !== undefined && typeof input.force !== 'boolean') {
      throw new BadRequestException('force must be a boolean');
    }
    const force = input.force === true;
    let note: string | null = null;
    if (force) {
      if (typeof input.note !== 'string' || input.note.trim() === '') {
        throw new BadRequestException('note is required when force is true');
      }
      note = input.note.trim();
    }
    let label: string | null = null;
    if (input.label !== undefined && input.label !== null) {
      if (typeof input.label !== 'string' || input.label.trim() === '') {
        throw new BadRequestException('label must be a non-empty string');
      }
      label = input.label.trim();
      if (label.length > DEVICE_LABEL_MAX_LENGTH) {
        throw new BadRequestException(
          `label must be at most ${DEVICE_LABEL_MAX_LENGTH} characters`,
        );
      }
    }

    const enrolCode = randomBytes(4).toString('hex').toUpperCase();
    const enrolCodeHash = createHash('sha256').update(enrolCode).digest('hex');

    return this.adminDs.transaction(async (manager) => {
      await manager.query(`SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, [
        `devices:${tenantId}`,
      ]);

      const devices = (await manager.query(
        `SELECT id, label, device_no, role, retired_at, token_hash IS NOT NULL AS enrolled,
                unsynced_ops, unsynced_reported_at
           FROM devices
          WHERE tenant_id = $1 AND id = $2
            FOR NO KEY UPDATE`,
        [tenantId, deviceId],
      )) as Array<{
        id: string;
        label: string;
        device_no: number;
        role: 'pos' | 'backoffice';
        retired_at: Date | null;
        enrolled: boolean;
        unsynced_ops: number;
        unsynced_reported_at: Date | null;
      }>;
      if (devices.length === 0) {
        throw new NotFoundException({ code: 'DEVICE_NOT_FOUND', message: 'Device not found' });
      }
      const old = devices[0];
      if (old.retired_at !== null) {
        throw new ConflictException({
          code: 'DEVICE_ALREADY_RETIRED',
          message: 'This device is already retired.',
          details: { retiredAt: new Date(old.retired_at).toISOString() },
        });
      }
      if (!old.enrolled) {
        // Nothing is lost: the row can still be enrolled. Retiring it would only burn a
        // device number (F8) — reissuing its code is the right tool.
        throw new ConflictException({
          code: 'DEVICE_NOT_ENROLLED',
          message:
            'This device has never been enrolled; issue it a new enrolment code instead (enrol-code).',
        });
      }

      const shifts = (await manager.query(
        `SELECT id, closed_at, starting_cash, opened_at FROM shifts
          WHERE tenant_id = $1 AND device_id = $2 AND is_active
          ORDER BY opened_at DESC
          LIMIT 1
            FOR UPDATE`,
        [tenantId, deviceId],
      )) as Array<{ id: string; closed_at: Date | null; starting_cash: string; opened_at: Date }>;
      const openShift = shifts.length > 0 && shifts[0].closed_at === null ? shifts[0] : null;
      const unsyncedOps = Number(old.unsynced_ops ?? 0);

      if (!force && openShift) {
        throw new ConflictException({
          code: 'DEVICE_HAS_OPEN_SHIFT',
          message:
            'This device still has an open shift. Retry with force and a note to archive it uncounted.',
          details: { shiftId: openShift.id },
        });
      }
      if (!force && unsyncedOps > 0) {
        throw new ConflictException({
          code: 'DEVICE_HAS_UNSYNCED_OPS',
          message:
            'This device reported offline ops not yet sent. Retry with force and a note to retire it anyway.',
          details: {
            unsyncedOps,
            reportedAt: old.unsynced_reported_at
              ? new Date(old.unsynced_reported_at).toISOString()
              : null,
          },
        });
      }

      if (shifts.length > 0) {
        // A retired device never opens again, so a drawer left `is_active` would stay on
        // screen forever (`ShiftsService.closeForRetirementIn`). Archive it; flag it
        // uncounted if nobody closed it — never invent a physical count.
        await manager.query(
          `UPDATE shifts
              SET is_active = FALSE,
                  auto_archived = auto_archived OR $3,
                  archived_at = COALESCE(archived_at, now())
            WHERE tenant_id = $1 AND id = $2`,
          [tenantId, shifts[0].id, openShift !== null],
        );
      }
      if (openShift) {
        await ReviewItemsService.insertIn(manager, tenantId, {
          kind: 'shift_uncounted',
          refId: openShift.id,
          details: {
            shiftId: openShift.id,
            deviceId,
            startingCash: openShift.starting_cash,
            openedAt: new Date(openShift.opened_at).toISOString(),
          },
        });
      }
      if (unsyncedOps > 0) {
        await ReviewItemsService.insertIn(manager, tenantId, {
          kind: 'device_force_retired',
          refId: deviceId,
          details: {
            deviceId,
            unsyncedOps,
            reportedAt: old.unsynced_reported_at
              ? new Date(old.unsynced_reported_at).toISOString()
              : null,
            note,
          },
        });
      }

      const retired = returning<{ retired_at: Date }>(
        await manager.query(
          `UPDATE devices
              SET retired_at = now(), enrol_code_hash = NULL, enrol_expires_at = NULL
            WHERE tenant_id = $1 AND id = $2
          RETURNING retired_at`,
          [tenantId, deviceId],
        ),
      );

      const next = (await manager.query(
        `SELECT COALESCE(MAX(device_no), 0) + 1 AS n FROM devices WHERE tenant_id = $1`,
        [tenantId],
      )) as Array<{ n: number }>;
      const deviceNo = Number(next[0].n);
      if (deviceNo > MAX_DEVICE_NO) {
        throw new ConflictException({
          code: 'DEVICE_NO_EXHAUSTED',
          message: `All ${MAX_DEVICE_NO} device numbers of this shop have been used.`,
        });
      }

      const newDeviceId = newId('dv');
      // An omitted label is named by the NEW device_no (RC<nn> receipts follow it), never the
      // retired device's label, so "POS #3" cannot front a device that numbers RC04.
      const newLabel = label ?? `${old.role === 'pos' ? 'POS' : 'Backoffice'} #${deviceNo}`;
      const created = (await manager.query(
        `INSERT INTO devices (tenant_id, id, label, device_no, role, enrol_code_hash, enrol_expires_at)
              VALUES ($1, $2, $3, $4, $5, $6, now() + make_interval(days => $7))
           RETURNING enrol_expires_at`,
        [
          tenantId,
          newDeviceId,
          newLabel,
          deviceNo,
          old.role,
          enrolCodeHash,
          REISSUE_ENROL_CODE_TTL_DAYS,
        ],
      )) as Array<{ enrol_expires_at: Date }>;
      const enrolExpiresAt = new Date(created[0].enrol_expires_at).toISOString();
      const retiredAt = new Date(retired[0].retired_at).toISOString();

      await this.auditService.log(manager, {
        tenantId,
        platformAdminId: adminId,
        action: 'device.retire',
        entity: 'devices',
        entityId: deviceId,
        before: { role: old.role, deviceNo: Number(old.device_no) },
        after: {
          retiredAt,
          shiftId: shifts[0]?.id ?? null,
          replacedBy: newDeviceId,
          ...(force ? { forced: true, note } : {}),
        },
        ip,
      });
      // Never the code itself (same rule as `DevicesService.createIn`).
      await this.auditService.log(manager, {
        tenantId,
        platformAdminId: adminId,
        action: 'device.create',
        entity: 'devices',
        entityId: newDeviceId,
        after: {
          label: newLabel,
          role: old.role,
          deviceNo,
          enrolExpiresAt,
          replaces: deviceId,
        },
        ip,
      });

      return {
        retiredDeviceId: deviceId,
        retiredAt,
        device: { id: newDeviceId, label: newLabel, role: old.role, deviceNo },
        enrolCode,
        enrolExpiresAt,
      };
    });
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
      await this.auditNotFound(tenantId, 'platform.tenant.read_not_found', adminId, ip);
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

    // Owner-account panel (#443 UX pass): the one active owner (`uq_users_one_active`). Only
    // lifecycle facts — never `password_hash`, and the temp password itself is never stored.
    const ownerRows = await this.adminDs.query(
      `SELECT username, display_name, must_change_password, temp_password_expires_at,
              password_changed_at
         FROM users
        WHERE tenant_id = $1 AND is_active`,
      [tenantId],
    );

    // `result` is ImportJobResult — tombstone counts + a dropped-supplier count, no secret.
    const importJobRows = await this.adminDs.query(
      `SELECT id, status, error, result, created_at, started_at, finished_at
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

    const owner = ownerRows[0] as
      | {
          username: string;
          display_name: string;
          must_change_password: boolean;
          temp_password_expires_at: Date | null;
          password_changed_at: Date | null;
        }
      | undefined;
    const iso = (d: Date | null) => (d ? new Date(d).toISOString() : null);

    return {
      tenant: tenantRows[0],
      owner: owner
        ? {
            username: owner.username,
            displayName: owner.display_name,
            mustChangePassword: owner.must_change_password,
            tempPasswordExpiresAt: iso(owner.temp_password_expires_at),
            passwordChangedAt: iso(owner.password_changed_at),
          }
        : null,
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

  /** Probing signal (2026-10-03): best-effort, on the autocommit admin source, before the throw. */
  private async auditNotFound(tenantId: string, action: string, adminId: string, ip?: string) {
    try {
      await this.auditService.logReadNotFound(this.adminDs, {
        action,
        requestedId: tenantId,
        platformAdminId: adminId,
        ip,
      });
    } catch (err) {
      this.logger.warn(`Failed to write audit log for ${action}: ${err}`);
    }
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
