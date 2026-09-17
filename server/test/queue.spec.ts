import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  ALL_QUEUES,
  DEFAULT_JOB_OPTIONS,
  QUEUE_BACKUP,
  QUEUE_DLQ,
  QUEUE_INVENTORY,
  QUEUE_MAINTENANCE,
  QUEUE_SALE_POST,
  QUEUE_TENANT_IMPORT,
} from '../src/queue/queue.constants.js';

describe('queue substrate (unit)', () => {
  it('AC6: no bull package is installed alongside bullmq', () => {
    const pkgPath = resolve(__dirname, '../package.json');
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf-8'));
    const allDeps = {
      ...pkg.dependencies,
      ...pkg.devDependencies,
    };

    expect(allDeps).toHaveProperty('bullmq');
    expect(allDeps).toHaveProperty('@nestjs/bullmq');
    expect(allDeps).not.toHaveProperty('bull');
    expect(allDeps).not.toHaveProperty('@nestjs/bull');
  });

  it('registers all 6 required queues (5 operational + 1 DLQ)', () => {
    expect(ALL_QUEUES).toEqual([
      QUEUE_SALE_POST,
      QUEUE_INVENTORY,
      QUEUE_MAINTENANCE,
      QUEUE_BACKUP,
      // #239: its own queue, not a `tenant.import` job name on QUEUE_BACKUP — see that
      // constant's comment (two `@Processor` classes on one queue name would race for
      // every job).
      QUEUE_TENANT_IMPORT,
      QUEUE_DLQ,
    ]);
  });

  it('AC5: job options age out completed jobs and retain failed jobs for evidence', () => {
    expect(DEFAULT_JOB_OPTIONS.attempts).toBe(3);
    expect(DEFAULT_JOB_OPTIONS.removeOnFail).toBe(false);
    expect(DEFAULT_JOB_OPTIONS.removeOnComplete).toEqual({
      age: 3600,
      count: 1000,
    });
    // #201: BullMQ's own builtin 'exponential' strategy with jitter: 1 is full jitter
    // (minDelay = maxDelay * (1 - jitter) = 0) — see the comment on DEFAULT_JOB_OPTIONS.
    expect(DEFAULT_JOB_OPTIONS.backoff).toEqual({
      type: 'exponential',
      delay: 1000,
      jitter: 1,
    });
  });
});
