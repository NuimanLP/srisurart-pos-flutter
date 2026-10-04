import type { ModuleRef } from '@nestjs/core';
import { getQueueToken } from '@nestjs/bullmq';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { ALL_QUEUES } from '../queue/queue.constants.js';
import { MetricsService } from './metrics.service.js';
import { RuntimeMetricsService } from './runtime-metrics.service.js';

const POOL = { inUse: 1, idle: 4, waiting: 0, max: 5 };

/** A ModuleRef whose queues answer `getJobCounts` with `counts(name)`. */
function fakeModuleRef(counts: (name: string) => Promise<Record<string, number>>) {
  const tokens = new Map<string | symbol, unknown>(
    ALL_QUEUES.map((name) => [
      getQueueToken(name),
      { name, getJobCounts: vi.fn(() => counts(name)) },
    ]),
  );
  const get = vi.fn((token: string | symbol) => tokens.get(token));
  return { moduleRef: { get } as unknown as ModuleRef, get, tokens };
}

function start(counts: (name: string) => Promise<Record<string, number>>) {
  const metrics = new MetricsService();
  const ref = fakeModuleRef(counts);
  new RuntimeMetricsService(metrics, () => POOL, ref.moduleRef).onModuleInit();
  return { metrics, ...ref };
}

describe('RuntimeMetricsService', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('feeds the pool reader to the pool gauges', async () => {
    const { metrics } = start(async () => ({}));
    const text = await metrics.metrics();
    expect(text).toContain('pos_db_pool_connections{state="idle"} 4');
    expect(text).toContain('pos_db_pool_max_connections 5');
  });

  it('looks up every queue non-strictly and reads the four states from each', async () => {
    const { metrics, get, tokens } = start(async (name) => ({
      waiting: name.length,
      active: 0,
      delayed: 0,
      failed: 0,
    }));
    expect(get).toHaveBeenCalledTimes(ALL_QUEUES.length);
    for (const name of ALL_QUEUES) {
      expect(get).toHaveBeenCalledWith(getQueueToken(name), { strict: false });
    }

    const text = await metrics.metrics();
    for (const name of ALL_QUEUES) {
      expect(text).toContain(`pos_queue_jobs{queue="${name}",state="waiting"} ${name.length}`);
      const queue = tokens.get(getQueueToken(name)) as { getJobCounts: ReturnType<typeof vi.fn> };
      expect(queue.getJobCounts).toHaveBeenCalledWith('waiting', 'active', 'delayed', 'failed');
    }
  });

  it('drops the queue samples when any one queue read fails', async () => {
    const { metrics } = start(async (name) => {
      if (name === ALL_QUEUES[0]) throw new Error('NOAUTH');
      return { waiting: 1 };
    });
    expect(await metrics.metrics()).not.toMatch(/^pos_queue_jobs\{/m);
  });

  it('wraps a non-Error rejection and still drops the samples', async () => {
    const { metrics } = start(() => Promise.reject('boom'));
    expect(await metrics.metrics()).not.toMatch(/^pos_queue_jobs\{/m);
  });

  it('gives up on a queue read after 1s so a silent redis-queue cannot hang the scrape', async () => {
    vi.useFakeTimers();
    // maxRetriesPerRequest: null — a command against an unreachable Redis never settles.
    const { metrics } = start(() => new Promise(() => {}));
    const scrape = metrics.metrics();
    await vi.advanceTimersByTimeAsync(1000);
    const text = await scrape;
    expect(text).not.toMatch(/^pos_queue_jobs\{/m);
    expect(text).toContain('pos_db_pool_max_connections 5');
  });
});
