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
} from '../src/queue/queue.constants.js';
import { calculateJitterBackoff } from '../src/queue/jitter-backoff.js';

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

  it('registers all 5 required queues (4 operational + 1 DLQ)', () => {
    expect(ALL_QUEUES).toEqual([
      QUEUE_SALE_POST,
      QUEUE_INVENTORY,
      QUEUE_MAINTENANCE,
      QUEUE_BACKUP,
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
    expect(DEFAULT_JOB_OPTIONS.backoff).toEqual({
      type: 'exponential-jitter',
      delay: 1000,
    });
  });

  describe('jitter-backoff', () => {
    it('calculates exponential delay with jitter bounded in [0, maxForAttempt]', () => {
      // attempt 1: base = 1000 * 2^0 = 1000
      expect(calculateJitterBackoff(1, 1000, 30000, () => 0.5)).toBe(500);
      expect(calculateJitterBackoff(1, 1000, 30000, () => 1.0)).toBe(1000);
      expect(calculateJitterBackoff(1, 1000, 30000, () => 0.0)).toBe(0);

      // attempt 2: base = 1000 * 2^1 = 2000
      expect(calculateJitterBackoff(2, 1000, 30000, () => 0.5)).toBe(1000);

      // attempt 3: base = 1000 * 2^2 = 4000
      expect(calculateJitterBackoff(3, 1000, 30000, () => 0.75)).toBe(3000);

      // attempt 0 or negative returns 0
      expect(calculateJitterBackoff(0, 1000, 30000)).toBe(0);
    });

    it('caps delay at maxDelay', () => {
      // attempt 10: 1000 * 2^9 = 512,000 -> capped at 30,000
      const capped = calculateJitterBackoff(10, 1000, 30000, () => 1.0);
      expect(capped).toBe(30000);
    });
  });
});
