import { getQueueToken } from '@nestjs/bullmq';
import { Queue } from 'bullmq';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  IDEM_CLEANUP_INTERVAL_MS,
  IDEM_CLEANUP_SCHEDULER_ID,
  JOB_IDEM_CLEANUP,
  QUEUE_MAINTENANCE,
} from '../src/queue/queue.constants.js';
import { QueueProcessorsModule, QueueSchedulerModule } from '../src/queue/queue.module.js';
import { JobSchedulerService } from '../src/queue/job-scheduler.service.js';
import { createTestApp, resetTenant, type TestApp } from './support/fixture.js';

/**
 * #182: nothing scheduled the global `idem.cleanup` job (#169's fan-out deletes real rows under
 * RLS, proved by the two-tenant case in `worker-jobs.e2e-spec.ts`, but only once something
 * enqueues it). This proves the repeatable scheduler itself, against real BullMQ/Redis: it
 * registers on boot under a stable id, its own run actually deletes expired rows across two
 * tenants (the scheduler's real job shape — no `data`, default TTL, `repeat:` parent id), and
 * re-registering — a restart, or a second worker replica booting — never leaves more than one
 * scheduler behind.
 *
 * This suite mounts both `QueueProcessorsModule` (the real `MaintenanceProcessor`, so the
 * scheduled job actually runs) and `QueueSchedulerModule` (the scheduler itself) — the two
 * modules the review split apart specifically so *other* e2e files that only need the former
 * (`backup.e2e-spec.ts`, `worker-jobs.e2e-spec.ts`) never register the latter.
 */
describe('#182: idem.cleanup job scheduler (e2e)', () => {
  let fixture: TestApp;
  let maintenanceQueue: Queue;

  const TENANT_A = 'aaaaaaaa-1829-4182-9182-918291829182';
  const TENANT_B = 'bbbbbbbb-1829-4182-9182-918291829182';

  async function waitFor(fn: () => Promise<boolean>, timeoutMs = 8000): Promise<void> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      if (await fn()) return;
      await new Promise((resolve) => setTimeout(resolve, 150));
    }
    throw new Error(`Timeout waiting for condition after ${timeoutMs}ms`);
  }

  /**
   * No job actually running or about to be picked up — safe to close the app (or remove the
   * scheduler) without orphaning an active parent mid-execution. Deliberately excludes
   * `delayed`: a live scheduler always keeps exactly one future occurrence sitting there by
   * design, so waiting on it to reach zero would never resolve.
   */
  async function drainQueue(): Promise<void> {
    await waitFor(async () => {
      const jobs = await maintenanceQueue.getJobs(['active', 'waiting']);
      return jobs.length === 0;
    });
  }

  beforeAll(async () => {
    fixture = await createTestApp([QueueProcessorsModule, QueueSchedulerModule]);
    maintenanceQueue = fixture.app.get<Queue>(getQueueToken(QUEUE_MAINTENANCE));
    // Boot already registered a scheduler and — against real Redis/BullMQ 6.3.4, `every` with no
    // prior run fires immediately, not an hour out — may already be fanning out over whatever
    // tenants exist. Wipe all of it (force: an active job from that boot may still be running)
    // before seeding the actual test fixtures, so this test controls exactly one run.
    await maintenanceQueue.removeJobScheduler(IDEM_CLEANUP_SCHEDULER_ID);
    await maintenanceQueue.obliterate({ force: true });
  });

  afterAll(async () => {
    await drainQueue();
    // Leave no global schedule or job behind for the next e2e file / run to trip over.
    await maintenanceQueue.removeJobScheduler(IDEM_CLEANUP_SCHEDULER_ID);
    await maintenanceQueue.obliterate({ force: true });
    await fixture.app.close();
  });

  it('registers on boot, and its own run deletes expired idempotency keys across two tenants while keeping fresh ones', async () => {
    await resetTenant(fixture.admin, TENANT_A, { cache: fixture.cache });
    await resetTenant(fixture.admin, TENANT_B, { cache: fixture.cache });
    const stamp = Date.now();
    const seed = (tenantId: string, key: string, age: string) =>
      fixture.admin.query(
        `INSERT INTO idempotency_keys (tenant_id, key, endpoint, request_hash, status, response_code, response_body, created_at)
         VALUES ($1::uuid, $2, '/sales', 'hash', 'done', 201, '{"ok":true}', now() - $3::interval)`,
        [tenantId, key, age],
      );
    await seed(TENANT_A, `g-exp-a-${stamp}`, '25 hours');
    await seed(TENANT_B, `g-exp-b-${stamp}`, '25 hours');
    await seed(TENANT_A, `g-fresh-a-${stamp}`, '1 hour');

    const remaining = async (): Promise<string[]> =>
      (
        await fixture.admin.query(
          `SELECT key FROM idempotency_keys WHERE key LIKE $1 ORDER BY key`,
          [`g-%-${stamp}`],
        )
      ).map((r: { key: string }) => r.key);

    expect(await remaining()).toEqual([
      `g-exp-a-${stamp}`,
      `g-exp-b-${stamp}`,
      `g-fresh-a-${stamp}`,
    ]);

    // Re-register against the now-clean queue: with no prior run in Redis this fires the fan-out
    // immediately (the behaviour the review measured), which is what actually deletes the rows.
    const scheduler = fixture.app.get(JobSchedulerService);
    await scheduler.onApplicationBootstrap();

    await waitFor(async () => (await remaining()).length === 1);
    expect(await remaining()).toEqual([`g-fresh-a-${stamp}`]);

    const registered = await maintenanceQueue.getJobScheduler(IDEM_CLEANUP_SCHEDULER_ID);
    expect(registered?.name).toBe(JOB_IDEM_CLEANUP);
    expect(registered?.every).toBe(IDEM_CLEANUP_INTERVAL_MS);

    await drainQueue();
  });

  it('a second registration (restart, or another worker replica) upserts the same id, not a duplicate', async () => {
    const scheduler = fixture.app.get(JobSchedulerService);

    await scheduler.onApplicationBootstrap();
    await scheduler.onApplicationBootstrap();
    await drainQueue();

    const schedulers = await maintenanceQueue.getJobSchedulers();
    const idemSchedulers = schedulers.filter((s) => s.key === IDEM_CLEANUP_SCHEDULER_ID);
    expect(idemSchedulers).toHaveLength(1);
    expect(idemSchedulers[0]?.every).toBe(IDEM_CLEANUP_INTERVAL_MS);
  });
});
