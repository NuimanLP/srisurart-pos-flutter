import { Injectable } from '@nestjs/common';
import { DataSource, EntityManager } from 'typeorm';
import { toInet } from '../common/client-ip.js';

/** Platform-wide rows (list, probing a tenant that does not exist) have no tenant to hang on. */
export const PLATFORM_AUDIT_TENANT_ID = '00000000-0000-0000-0000-000000000000';

export interface AuditLogInput {
  tenantId: string;
  platformAdminId?: string;
  userId?: string;
  deviceId?: string;
  action: string;
  entity?: string;
  entityId?: string;
  before?: Record<string, unknown> | null;
  after?: Record<string, unknown> | null;
  ip?: string;
}

@Injectable()
export class AuditService {
  /** Pass the business transaction's manager so a failed audit rolls the write back (#123). */
  async log(runner: EntityManager | DataSource, input: AuditLogInput): Promise<void> {
    const cleanIp = toInet(input.ip);

    await runner.query(
      `INSERT INTO audit_log (tenant_id, platform_admin_id, user_id, device_id, action, entity, entity_id, before, after, ip)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
      [
        input.tenantId,
        input.platformAdminId ?? null,
        input.userId ?? null,
        input.deviceId ?? null,
        input.action,
        input.entity ?? null,
        input.entityId ?? null,
        input.before ? JSON.stringify(input.before) : null,
        input.after ? JSON.stringify(input.after) : null,
        cleanIp,
      ],
    );
  }

  /**
   * A platform read that found no such tenant (owner decision 2026-10-03: a 404 is a probing
   * signal, a 400 is not). `requestedId` MUST already have passed UUID validation. Best-effort
   * like the success-path read audit — the caller runs this on the autocommit admin source
   * *before* throwing, so the row is committed on its own and the 404 cannot roll it back.
   */
  async logReadNotFound(
    runner: DataSource,
    input: { action: string; requestedId: string; platformAdminId: string; ip?: string },
  ): Promise<void> {
    await this.log(runner, {
      tenantId: PLATFORM_AUDIT_TENANT_ID,
      platformAdminId: input.platformAdminId,
      action: input.action,
      entity: 'tenants',
      entityId: input.requestedId,
      after: { outcome: 'not_found' },
      ip: input.ip,
    });
  }
}
