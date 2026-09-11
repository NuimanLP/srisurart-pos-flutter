import { Injectable, Logger } from '@nestjs/common';
import * as net from 'node:net';
import { EntityManager } from 'typeorm';

export interface AuditLogParams {
  tenantId: string;
  userId?: string;
  platformAdminId?: string;
  deviceId?: string;
  action: string;
  entity?: string;
  entityId?: string;
  before?: Record<string, any>;
  after?: Record<string, any>;
  ip?: string;
}

@Injectable()
export class AuditService {
  private readonly logger = new Logger(AuditService.name);

  /**
   * Writes an audit log entry. This should usually be called within a transaction (passing the manager),
   * so that if the transaction rolls back, the audit log rolls back too, EXCEPT for auth events
   * where we want to record the failure anyway (in those cases, call it outside the business transaction).
   */
  async log(manager: EntityManager, params: AuditLogParams): Promise<void> {
    try {
      let cleanIp: string | null = null;
      if (params.ip) {
        const candidate = params.ip.split(',')[0].trim();
        if (candidate && net.isIP(candidate) !== 0) {
          cleanIp = candidate;
        }
      }

      await manager.query(
        `
        INSERT INTO audit_log (
          tenant_id, user_id, platform_admin_id, device_id,
          action, entity, entity_id, before, after, ip
        ) VALUES (
          $1, $2, $3, $4, $5, $6, $7, $8, $9, $10
        )
        `,
        [
          params.tenantId,
          params.userId ?? null,
          params.platformAdminId ?? null,
          params.deviceId ?? null,
          params.action,
          params.entity ?? null,
          params.entityId ?? null,
          params.before ? JSON.stringify(params.before) : null,
          params.after ? JSON.stringify(params.after) : null,
          cleanIp,
        ]
      );
    } catch (err) {
      // We log the error but don't crash the main process if audit logging fails,
      // though typically in a strict environment we might want to rollback.
      this.logger.error(`Failed to write audit log: ${err}`, err instanceof Error ? err.stack : undefined);
      throw err; // For this project, failing audit log should fail the action.
    }
  }
}
