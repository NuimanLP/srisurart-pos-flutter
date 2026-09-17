import { Queue, Worker, type Job } from 'bullmq';
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config/config.js';
import { DEFAULT_JOB_OPTIONS } from '../src/queue/queue.constants.js';

/**
 * #201: a prior version of `DEFAULT_JOB_OPTIONS.backoff.type` was the custom
 * `'exponential-jitter'`, which is not one of BullMQ's builtin strategies. Against real
 * Redis/BullMQ 6.3.4, a Worker with no matching `settings.backoffStrategy` throws `Unknown
 * backoff strategy exponential-jitter` from inside `moveToFailed`, and the job is left stuck
 * `active` with `attemptsMade` 0 — it neither retries nor fails. The fix (queue.constants.ts)
 * switches to BullMQ's own builtin `{ type: 'exponential', delay: 1000, jitter: 1 }`, which is
 * the same full-jitter formula and needs nothing registered on any Worker — so this suite
 * proves it with **no** `settings` on the test Worker at all, exactly like the four real
 * `@Processor`s.
 *
 * Runs against real Redis, on a private queue (`test-backoff-201`) no other suite touches — the
 * retry/failure mechanics here are BullMQ's own plumbing, not business logic any of the four
 * real processors add, and a synthetic handler that fails only while `job.attemptsMade === 0` is
 * the only way to control exactly which attempt fails without faking tenant/Postgres state a
 * real processor would need.
 *
 * Falsification (see PR description for the recorded red run): setting `backoff.type` back to
 * the unregistered `'exponential-jitter'` reproduces the pre-fix bug exactly — both cases go red
 * because the job never leaves `active`.
 */
describe('#201: the default backoff is BullMQ\'s own builtin, not a custom type', () => {
  const QUEUE_NAME = 'test-backoff-201';
  // Defaults match server/.env.example / docker-compose.dev.yml; `...process.env` lets a real
  // shell override them. Without this, `loadConfig()` throws `Missing required environment
  // variable DATABASE_URL` in CI, which sets none of these for a suite that needs no Postgres at
  // all — same pattern as `test/health.e2e-spec.ts` / `test/idempotency.e2e-spec.ts`.
  const config = loadConfig({
    DATABASE_URL: 'postgres://pos_app:dev-only-pos-app@127.0.0.1:5432/pos',
    REDIS_CACHE_URL: 'redis://:dev-only-redis@127.0.0.1:6379',
    REDIS_QUEUE_URL: 'redis://:dev-only-redis@127.0.0.1:6380',
    JWT_PRIVATE_KEY: 'dummy',
    JWT_PUBLIC_KEYS: 'dummy',
    ...process.env,
  });
  const url = new URL(config.redisQueueUrl);
  // Same shape `queue.module.ts`'s `BullModule.forRootAsync` factory builds — this suite talks
  // to the real dev redis-queue instance, not a mock.
  const connection = {
    host: url.hostname,
    port: Number(url.port || 6379),
    password: url.password || undefined,
    username: url.username || undefined,
    maxRetriesPerRequest: null,
    enableReadyCheck: false,
  };

  let queue: Queue;
  let worker: Worker | undefined;

  async function waitFor(fn: () => Promise<boolean>, timeoutMs = 15_000): Promise<void> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      if (await fn()) return;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error(`Timeout waiting for condition after ${timeoutMs}ms`);
  }

  beforeAll(async () => {
    queue = new Queue(QUEUE_NAME, { connection, defaultJobOptions: DEFAULT_JOB_OPTIONS });
    await queue.waitUntilReady();
    await queue.obliterate({ force: true });
  });

  afterEach(async () => {
    await worker?.close();
    worker = undefined;
  });

  afterAll(async () => {
    // Assert the private queue is clean BEFORE obliterating it, or the assertions are vacuous.
    expect(await queue.getJobSchedulers()).toEqual([]);
    expect(await queue.getActiveCount()).toBe(0);
    expect(await queue.isPaused()).toBe(false);
    await queue.obliterate({ force: true });
    await queue.close();
  });

  it('retries a job that fails once (default options, no worker settings) and completes on attempt 2', async () => {
    worker = new Worker(
      QUEUE_NAME,
      async (job: Job) => {
        if (job.attemptsMade === 0) {
          throw new Error('synthetic failure on first attempt');
        }
        return 'ok';
      },
      { connection },
    );
    await worker.waitUntilReady();

    const job = await queue.add('retry-once', {}, { jobId: 'retry-once-201' });

    await waitFor(async () => (await job.getState()) === 'completed');
    const finished = await queue.getJob(job.id!);
    expect(finished?.attemptsMade).toBe(2);
    expect(finished?.returnvalue).toBe('ok');
  });

  it('a job failing every attempt ends failed, not stuck active', async () => {
    worker = new Worker(
      QUEUE_NAME,
      async (): Promise<string> => {
        throw new Error('synthetic permanent failure');
      },
      { connection },
    );
    await worker.waitUntilReady();

    const job = await queue.add(
      'always-fails',
      {},
      { jobId: 'always-fails-201', attempts: 2, backoff: DEFAULT_JOB_OPTIONS.backoff },
    );

    await waitFor(async () => (await job.getState()) === 'failed');
    const finished = await queue.getJob(job.id!);
    expect(finished?.attemptsMade).toBe(2);
    expect(finished?.failedReason).toContain('synthetic permanent failure');
  });
});
