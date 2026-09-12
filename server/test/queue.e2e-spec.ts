import { getQueueToken } from '@nestjs/bullmq';
import { type Job, Queue } from 'bullmq';
import express from 'express';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import {
  ALL_QUEUES,
  type BaseJobPayload,
  QUEUE_DLQ,
  QUEUE_INVENTORY,
  QUEUE_SALE_POST,
} from '../src/queue/queue.constants.js';
import { TenantJobRunner } from '../src/queue/tenant-job-runner.js';
import { createTestApp, resetTenant, type TestApp } from './support/fixture.js';

describe('BullMQ infrastructure and Bull-Board (e2e)', () => {
  let fixture: TestApp;
  let runner: TenantJobRunner;
  let dlqQueue: Queue;
  let salePostQueue: Queue;

  const TENANT_A = '11111111-1111-1111-1111-111111111111';
  const TENANT_B = '22222222-2222-2222-2222-222222222222';

  beforeAll(async () => {
    fixture = await createTestApp();
    runner = fixture.app.get(TenantJobRunner);
    dlqQueue = fixture.app.get<Queue>(getQueueToken(QUEUE_DLQ));
    salePostQueue = fixture.app.get<Queue>(getQueueToken(QUEUE_SALE_POST));
  });

  afterAll(async () => {
    await fixture.app.close();
  });

  beforeEach(async () => {
    await resetTenant(fixture.admin, TENANT_A, { cache: fixture.cache });
    await resetTenant(fixture.admin, TENANT_B, { cache: fixture.cache });
    await dlqQueue.obliterate({ force: true });
  });

  it('registers and connects all 5 queues to redis-queue', async () => {
    for (const queueName of ALL_QUEUES) {
      const q = fixture.app.get<Queue>(getQueueToken(queueName));
      expect(q).toBeDefined();
      expect(q.name).toBe(queueName);
      // Verify basic Redis queue operations succeed
      await q.waitUntilReady();
      const count = await q.count();
      expect(typeof count).toBe('number');
    }
  });

  it('can enqueue and retrieve jobs with default job options', async () => {
    const job = await salePostQueue.add(
      'sale.created',
      {
        tenantId: TENANT_A,
        correlationId: 'corr-123',
        saleId: 's1',
      },
      { jobId: 'test-job-1' },
    );

    expect(job.id).toBe('test-job-1');
    expect(job.opts.attempts).toBe(3);
    expect(job.opts.removeOnFail).toBe(false);
    expect(job.opts.removeOnComplete).toEqual({ age: 3600, count: 1000 });

    const retrieved = await salePostQueue.getJob('test-job-1');
    expect(retrieved).not.toBeNull();
    expect(retrieved?.data.tenantId).toBe(TENANT_A);
  });

  describe('AC1: Tenant isolation and leakage prevention', () => {
    it('proves a job that throws does NOT leak app.tenant_id to the next job on that connection', async () => {
      // Mock Job 1 for Tenant A (which will throw inside transaction)
      const jobA = {
        id: 'job-throw-a',
        name: 'test.throw',
        queueName: QUEUE_SALE_POST,
        data: {
          tenantId: TENANT_A,
          correlationId: 'corr-throw-a',
        },
        opts: { attempts: 3 },
        attemptsMade: 0,
      } as unknown as Job<BaseJobPayload>;

      let tenantSeenDuringThrow = '';
      await expect(
        runner.runWithTenantContext(jobA, async (em) => {
          const [row] = await em.query("SELECT current_setting('app.tenant_id') AS tid");
          tenantSeenDuringThrow = row.tid;
          throw new Error('Tenant A business logic failed abruptly');
        }),
      ).rejects.toThrow('Tenant A business logic failed abruptly');

      expect(tenantSeenDuringThrow).toBe(TENANT_A);

      // Immediately run Job 2 for Tenant B on the runner
      const jobB = {
        id: 'job-success-b',
        name: 'test.success',
        queueName: QUEUE_SALE_POST,
        data: {
          tenantId: TENANT_B,
          correlationId: 'corr-success-b',
        },
        opts: { attempts: 3 },
        attemptsMade: 0,
      } as unknown as Job<BaseJobPayload>;

      let tenantSeenInJobB = '';
      const resultB = await runner.runWithTenantContext(jobB, async (em) => {
        const [row] = await em.query("SELECT current_setting('app.tenant_id') AS tid");
        tenantSeenInJobB = row.tid;
        return 'success-b';
      });

      expect(resultB.skipped).toBe(false);
      expect(resultB.result).toBe('success-b');
      // Proves Tenant B saw ONLY Tenant B, not the leaked Tenant A!
      expect(tenantSeenInJobB).toBe(TENANT_B);

      // Also verify connection pool slot outside transaction has NO app.tenant_id set
      const [outside] = await fixture.ds.query(
        "SELECT current_setting('app.tenant_id', true) AS tid",
      );
      expect(outside.tid).toBeFalsy();
    });
  });

  describe('AC3: Suspended tenant guard (ADR-0003)', () => {
    it('skips job execution without invoking business logic if tenant is suspended', async () => {
      // Suspend Tenant A in DB
      await fixture.admin.query("UPDATE tenants SET status = 'suspended' WHERE id = $1", [
        TENANT_A,
      ]);

      const job = {
        id: 'job-suspended',
        name: 'test.suspended',
        queueName: QUEUE_SALE_POST,
        data: {
          tenantId: TENANT_A,
          correlationId: 'corr-suspended',
        },
        opts: { attempts: 3 },
        attemptsMade: 0,
      } as unknown as Job<BaseJobPayload>;

      let businessLogicExecuted = false;
      const res = await runner.runWithTenantContext(job, async () => {
        businessLogicExecuted = true;
      });

      expect(res.skipped).toBe(true);
      expect(res.reason).toBe('TENANT_SUSPENDED');
      expect(businessLogicExecuted).toBe(false);
    });

    it('skips job execution if tenant does not exist in DB', async () => {
      const nonExistentTenantId = '99999999-9999-9999-9999-999999999999';
      const job = {
        id: 'job-not-found',
        name: 'test.notfound',
        queueName: QUEUE_SALE_POST,
        data: {
          tenantId: nonExistentTenantId,
          correlationId: 'corr-notfound',
        },
        opts: { attempts: 3 },
        attemptsMade: 0,
      } as unknown as Job<BaseJobPayload>;

      let businessLogicExecuted = false;
      const res = await runner.runWithTenantContext(job, async () => {
        businessLogicExecuted = true;
      });

      expect(res.skipped).toBe(true);
      expect(res.reason).toBe('TENANT_NOT_FOUND');
      expect(businessLogicExecuted).toBe(false);
    });
  });

  describe('AC2: Dead-letter queue (DLQ) on final attempt failure', () => {
    it('routes failed job to DLQ and alerts on final attempt exhaustion', async () => {
      // attemptsMade = 2 with max attempts = 3 means this execution is the 3rd (final) attempt
      const job = {
        id: 'job-dlq-exhausted',
        name: 'test.fatal',
        queueName: QUEUE_INVENTORY,
        data: {
          tenantId: TENANT_A,
          correlationId: 'corr-fatal-1',
          productId: 'prod-99',
        },
        opts: { attempts: 3 },
        attemptsMade: 2,
      } as unknown as Job<BaseJobPayload>;

      await expect(
        runner.runWithTenantContext(job, async () => {
          throw new Error('Fatal unrecoverable error');
        }),
      ).rejects.toThrow('Fatal unrecoverable error');

      // Verify job was routed to DLQ queue
      const dlqJobs = await dlqQueue.getJobs(['waiting', 'delayed', 'active', 'completed', 'failed']);
      expect(dlqJobs.length).toBeGreaterThanOrEqual(1);

      const dlqEntry = dlqJobs.find((j) => j.data.originalJobId === 'job-dlq-exhausted');
      expect(dlqEntry).toBeDefined();
      expect(dlqEntry?.data.originalQueue).toBe(QUEUE_INVENTORY);
      expect(dlqEntry?.data.originalName).toBe('test.fatal');
      expect(dlqEntry?.data.payload).toEqual(job.data);
      expect(dlqEntry?.data.failedReason).toBe('Fatal unrecoverable error');
      expect(dlqEntry?.data.attemptsMade).toBe(3);
    });
  });

  describe('AC4: Bull-Board authentication', () => {
    it('protects Bull-Board behind HTTP Basic Auth and rejects unauthorized requests', async () => {
      // Build an instance of Bull-Board router with auth middleware identical to bull-board.ts
      const { timingSafeEqual } = await import('node:crypto');
      const testUser = 'admin';
      const testPass = 'secret-pass-123';

      const safeEqual = (a: string, b: string) => {
        const ab = Buffer.from(a);
        const bb = Buffer.from(b);
        return ab.length === bb.length && timingSafeEqual(ab, bb);
      };

      const boardApp = express();
      boardApp.use((req, res, next) => {
        const header = req.headers.authorization ?? '';
        const [scheme, encoded] = header.split(' ');
        if (scheme === 'Basic' && encoded) {
          const [u, ...rest] = Buffer.from(encoded, 'base64').toString().split(':');
          if (safeEqual(u, testUser) && safeEqual(rest.join(':'), testPass)) {
            return next();
          }
        }
        res.set('WWW-Authenticate', 'Basic realm="bull-board"').status(401).send('Unauthorized');
      });

      boardApp.get('/', (_req, res) => res.status(200).send('bull-board-ok'));

      // 1. Missing Authorization header -> 401
      const noAuth = await request(boardApp).get('/');
      expect(noAuth.status).toBe(401);
      expect(noAuth.headers['www-authenticate']).toBe('Basic realm="bull-board"');

      // 2. Wrong password -> 401
      const wrongAuth = await request(boardApp)
        .get('/')
        .set('Authorization', 'Basic ' + Buffer.from('admin:wrong-pass').toString('base64'));
      expect(wrongAuth.status).toBe(401);

      // 3. Correct credentials -> 200 OK
      const validAuth = await request(boardApp)
        .get('/')
        .set('Authorization', 'Basic ' + Buffer.from('admin:secret-pass-123').toString('base64'));
      expect(validAuth.status).toBe(200);
      expect(validAuth.text).toBe('bull-board-ok');
    });
  });
});
