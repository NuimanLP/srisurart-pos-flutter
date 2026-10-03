import { Inject, Injectable, Logger, type OnModuleInit } from '@nestjs/common';
import { ModuleRef } from '@nestjs/core';
import { getQueueToken } from '@nestjs/bullmq';
import type { Queue } from 'bullmq';
import { DataSource } from 'typeorm';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { HealthService, withTimeout, type ReadinessChecks } from '../health/health.service.js';
import { ADMIN_DATA_SOURCE } from '../infra/db.module.js';
import { ALL_QUEUES } from '../queue/queue.constants.js';
import { AuditService } from './audit.service.js';

/** `listTenants` writes its platform-wide audit row under this id too — no tenant is touched. */
const NO_TENANT = '00000000-0000-0000-0000-000000000000';
const QUEUE_COUNT_TIMEOUT_MS = 2000;
// BullMQ 6 has no `paused` state any more (a paused queue keeps its jobs in `waiting`).
const JOB_STATES = ['waiting', 'prioritized', 'active', 'delayed', 'failed', 'completed'] as const;

export type QueueCounts = Record<(typeof JOB_STATES)[number], number>;

/**
 * Fixed on purpose (owner decision): the api container cannot see `/opt/pos/backups` and is
 * not given a mount for it, and no backup leaves the VM while #363 is parked. This says so
 * instead of guessing — never word it as "backups ready".
 */
export const BACKUP_STATUS = {
  offsite: 'not_configured',
  message:
    'Offsite backup is not configured (#363 parked): nightly dumps stay on the VM only. ' +
    'This server cannot see the backup directory; check backup-cron.log on the VM.',
} as const;

export interface SystemStatus {
  gitSha: string | null;
  ready: boolean;
  checks: ReadinessChecks;
  queues: Array<{ name: string; counts: QueueCounts | null }>;
  backup: typeof BACKUP_STATUS;
  checkedAt: string;
}

/**
 * `GET /platform/system` (#443) — what is deployed and whether it can serve.
 * Readiness is `HealthService.readiness()`, the same checks `/health/ready` gates on.
 */
@Injectable()
export class PlatformSystemService implements OnModuleInit {
  private readonly logger = new Logger(PlatformSystemService.name);
  private queues: Array<{ name: string; queue: Queue }> = [];

  constructor(
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    @Inject(ADMIN_DATA_SOURCE) private readonly adminDs: DataSource,
    private readonly health: HealthService,
    private readonly auditService: AuditService,
    private readonly moduleRef: ModuleRef,
  ) {}

  /**
   * Resolved once at boot, not per request inside a `catch`: a queue missing from the app's
   * (global) `QueueModule` must fail the boot loudly, not read as "unknown" counts forever.
   */
  onModuleInit(): void {
    this.queues = ALL_QUEUES.map((name) => ({
      name,
      queue: this.moduleRef.get<Queue>(getQueueToken(name), { strict: false }),
    }));
  }

  async status(adminId: string, ip?: string): Promise<SystemStatus> {
    const [checks, queues] = await Promise.all([this.health.readiness(), this.queueCounts()]);

    try {
      await this.auditService.log(this.adminDs, {
        tenantId: NO_TENANT,
        platformAdminId: adminId,
        action: 'platform.system.read',
        ip,
      });
    } catch (err) {
      this.logger.warn(`Failed to write audit log for system status: ${err}`);
    }

    return {
      gitSha: this.config.gitSha ?? null,
      ready: Object.values(checks).every((c) => c === 'up'),
      checks,
      queues,
      backup: BACKUP_STATUS,
      checkedAt: new Date().toISOString(),
    };
  }

  /**
   * BullMQ's own connection has no `commandTimeout` (redis.module.ts: it must not), so a
   * silent `redis-queue` would hang `getJobCounts` forever — bounded here, `null` = unknown.
   */
  private queueCounts(): Promise<Array<{ name: string; counts: QueueCounts | null }>> {
    return Promise.all(
      this.queues.map(async ({ name, queue }) => {
        try {
          const counts = await withTimeout(queue.getJobCounts(...JOB_STATES), QUEUE_COUNT_TIMEOUT_MS);
          return {
            name,
            counts: Object.fromEntries(JOB_STATES.map((s) => [s, counts[s] ?? 0])) as QueueCounts,
          };
        } catch {
          return { name, counts: null };
        }
      }),
    );
  }
}
