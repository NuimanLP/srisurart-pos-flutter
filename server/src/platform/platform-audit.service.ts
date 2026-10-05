import {
  BadRequestException,
  Inject,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { DataSource } from 'typeorm';
import { ADMIN_DATA_SOURCE } from '../infra/db.module.js';
import { UUID_ANY_CASE_RE } from '../common/ids.js';
import { AuditService } from './audit.service.js';

export const AUDIT_PAGE_DEFAULT = 50;
export const AUDIT_PAGE_MAX = 200;

/** `created_at` at Postgres' full microsecond precision, always UTC, then the bigint id. */
const CURSOR_RE = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z)\|(\d{1,19})$/;
const BIGINT_MAX = 9223372036854775807n;

export interface AuditCursor {
  createdAt: string;
  id: string;
}

/**
 * The page cursor is opaque to callers (base64url of `<created_at μs ISO>|<id>`). Microseconds
 * matter: rows written by one transaction share `now()`, and a millisecond cursor would skip
 * or re-serve them (same reason as `GET /products`' keyset cursor).
 */
export function encodeAuditCursor(c: AuditCursor): string {
  return Buffer.from(`${c.createdAt}|${c.id}`, 'utf8').toString('base64url');
}

/** Validated before any SQL: a malformed cursor is a 400, never a Postgres 22007/22P02 → 500. */
export function decodeAuditCursor(raw: unknown): AuditCursor {
  const invalid = () =>
    new BadRequestException({ code: 'INVALID_AUDIT_CURSOR', message: 'before is not a valid cursor' });
  // A repeated `?before=` arrives as an array — only one plain string is a cursor.
  if (typeof raw !== 'string' || !/^[A-Za-z0-9_-]{1,200}$/.test(raw)) throw invalid();
  const m = CURSOR_RE.exec(Buffer.from(raw, 'base64url').toString('utf8'));
  if (!m) throw invalid();
  const [, createdAt, id] = m;
  // The regex admits "2026-13-45T…"; a real date must survive a round trip to the millisecond.
  const ms = Date.parse(createdAt);
  if (Number.isNaN(ms) || new Date(ms).toISOString().slice(0, 23) !== createdAt.slice(0, 23)) {
    throw invalid();
  }
  if (BigInt(id) > BIGINT_MAX) throw invalid();
  return { createdAt, id };
}

/** Validate first, then clamp (CLAUDE.md): garbage is a 400; only a well-formed large value clamps. */
export function parseAuditLimit(raw: unknown): number {
  if (raw === undefined || raw === '') return AUDIT_PAGE_DEFAULT;
  if (typeof raw !== 'string' || !/^\d{1,6}$/.test(raw) || Number(raw) < 1) {
    throw new BadRequestException({
      code: 'INVALID_AUDIT_LIMIT',
      message: `limit must be an integer from 1 to ${AUDIT_PAGE_MAX}`,
    });
  }
  return Math.min(Number(raw), AUDIT_PAGE_MAX);
}

export type AuditActor =
  | { type: 'platform_admin'; id: string; username: string | null }
  | { type: 'user'; id: string; username: string | null }
  | { type: 'device'; id: string; label: string | null; deviceNo: number | null }
  | { type: 'system' };

export interface AuditEntry {
  id: string;
  action: string;
  entity: string | null;
  entityId: string | null;
  actor: AuditActor;
  /** Present when a device acted alongside a user/admin actor (e.g. a sale rung on `pos1`). */
  device: { id: string; label: string | null; deviceNo: number | null } | null;
  ip: string | null;
  createdAt: string;
}

export interface AuditRow {
  id: string;
  action: string;
  entity: string | null;
  entity_id: string | null;
  platform_admin_id: string | null;
  admin_username: string | null;
  user_id: string | null;
  user_username: string | null;
  device_id: string | null;
  device_label: string | null;
  device_no: number | null;
  ip: string | null;
  created_at_cursor: string;
}

/** Who did it: platform admin, else user, else device, else a `system.*` row. */
export function toAuditEntry(r: AuditRow): AuditEntry {
  const device = r.device_id
    ? { id: r.device_id, label: r.device_label, deviceNo: r.device_no }
    : null;
  let actor: AuditActor;
  if (r.platform_admin_id) {
    actor = { type: 'platform_admin', id: r.platform_admin_id, username: r.admin_username };
  } else if (r.user_id) {
    actor = { type: 'user', id: r.user_id, username: r.user_username };
  } else if (device) {
    actor = { type: 'device', ...device };
  } else {
    actor = { type: 'system' };
  }
  return {
    id: String(r.id),
    action: r.action,
    entity: r.entity,
    entityId: r.entity_id,
    actor,
    device: actor.type === 'device' ? null : device,
    ip: r.ip,
    createdAt: r.created_at_cursor,
  };
}

/**
 * `GET /platform/tenants/:id/audit` (#443) — one tenant's `audit_log`, newest first, keyset
 * paged on `(created_at, id)`.
 *
 * 🔴 `before`/`after` are never returned. Those JSONB columns hold whatever each writer chose
 * to put there, and nothing stops a future writer from putting a secret in one; an allowlist
 * here would have to track every writer's payload shape and would fail open the day one
 * changes. Omitting them is the one option that cannot leak. `action`/`entity`/`entityId`
 * already say what happened and to which row.
 *
 * Runs on `ADMIN_DATA_SOURCE` like every other platform read (`getTenantDetail`): the admin
 * role bypasses RLS, so the `tenant_id = $1` predicate is the isolation and every join is on
 * the full `(tenant_id, id)` key. The queries run one after another on the 2-slot admin pool
 * — no transaction, never two connections at once.
 */
@Injectable()
export class PlatformAuditService {
  private readonly logger = new Logger(PlatformAuditService.name);

  constructor(
    @Inject(ADMIN_DATA_SOURCE) private readonly adminDs: DataSource,
    private readonly auditService: AuditService,
  ) {}

  async listTenantAudit(
    tenantId: string,
    query: { before?: unknown; limit?: unknown },
    adminId: string,
    ip?: string,
  ): Promise<{ items: AuditEntry[]; nextCursor: string | null }> {
    if (!UUID_ANY_CASE_RE.test(tenantId)) {
      throw new BadRequestException({ code: 'INVALID_TENANT_ID', message: 'tenantId must be a valid UUID' });
    }
    const limit = parseAuditLimit(query.limit);
    const cursor =
      query.before === undefined || query.before === '' ? null : decodeAuditCursor(query.before);

    const tenant = await this.adminDs.query(`SELECT 1 FROM tenants WHERE id = $1`, [tenantId]);
    if (tenant.length === 0) {
      try {
        // Probing signal (2026-10-03); autocommit source, written before the throw.
        await this.auditService.logReadNotFound(this.adminDs, {
          action: 'platform.tenant.audit.read_not_found',
          requestedId: tenantId,
          platformAdminId: adminId,
          ip,
        });
      } catch (err) {
        this.logger.warn(`Failed to write audit log for listTenantAudit not-found: ${err}`);
      }
      throw new NotFoundException(`Tenant ${tenantId} not found`);
    }

    const params: unknown[] = [tenantId, limit + 1];
    let keyset = '';
    if (cursor) {
      params.push(cursor.createdAt, cursor.id);
      keyset = `AND (a.created_at, a.id) < ($3::timestamptz, $4::bigint)`;
    }
    const rows: AuditRow[] = await this.adminDs.query(
      `SELECT a.id, a.action, a.entity, a.entity_id,
              a.platform_admin_id, pa.username AS admin_username,
              a.user_id, u.username AS user_username,
              a.device_id, d.label AS device_label, d.device_no,
              host(a.ip) AS ip,
              to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at_cursor
         FROM audit_log a
         LEFT JOIN platform_admins pa ON pa.id = a.platform_admin_id
         LEFT JOIN users u ON u.tenant_id = a.tenant_id AND u.id = a.user_id
         LEFT JOIN devices d ON d.tenant_id = a.tenant_id AND d.id = a.device_id
        WHERE a.tenant_id = $1 ${keyset}
        ORDER BY a.created_at DESC, a.id DESC
        LIMIT $2`,
      params,
    );

    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;
    const last = page[page.length - 1];

    // Owner decision: reading the audit log is itself audited. Written after the page query,
    // so it never appears in the page it describes; best-effort like getTenantDetail/listTenants.
    try {
      await this.auditService.log(this.adminDs, {
        tenantId,
        platformAdminId: adminId,
        action: 'platform.tenant.audit.read',
        entity: 'audit_log',
        after: { limit, paged: cursor !== null, returned: page.length },
        ip,
      });
    } catch (err) {
      this.logger.warn(`Failed to write audit log for listTenantAudit: ${err}`);
    }

    return {
      items: page.map(toAuditEntry),
      nextCursor: hasMore && last ? encodeAuditCursor({ createdAt: last.created_at_cursor, id: String(last.id) }) : null,
    };
  }
}
