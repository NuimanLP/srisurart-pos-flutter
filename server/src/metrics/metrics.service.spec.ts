import { describe, expect, it } from 'vitest';
import { MetricsService } from './metrics.service.js';

/** The value of one sample line, e.g. `pos_documents_total{kind="sale"} 2` → 2. */
function sample(text: string, series: string): number | undefined {
  const line = text.split('\n').find((l) => l.startsWith(`${series} `));
  return line === undefined ? undefined : Number(line.slice(series.length + 1));
}

const POOL = { inUse: 3, idle: 2, waiting: 1, max: 20 };

describe('MetricsService', () => {
  it('serves the Prometheus text format', () => {
    expect(new MetricsService().contentType).toContain('text/plain');
  });

  describe('pos_documents_total', () => {
    it('starts every kind at 0 so increase() has a first sample', async () => {
      const text = await new MetricsService().metrics();
      for (const kind of ['sale', 'void', 'return']) {
        expect(sample(text, `pos_documents_total{kind="${kind}"}`)).toBe(0);
      }
    });

    it('counts each kind on its own', async () => {
      const m = new MetricsService();
      m.recordDocument('sale');
      m.recordDocument('sale');
      m.recordDocument('void');
      m.recordDocument('return');
      const text = await m.metrics();
      expect(sample(text, 'pos_documents_total{kind="sale"}')).toBe(2);
      expect(sample(text, 'pos_documents_total{kind="void"}')).toBe(1);
      expect(sample(text, 'pos_documents_total{kind="return"}')).toBe(1);
    });

    it('carries no tenant label', async () => {
      const m = new MetricsService();
      m.recordDocument('sale');
      const lines = (await m.metrics())
        .split('\n')
        .filter((l) => l.startsWith('pos_documents_total{'));
      expect(lines).toHaveLength(3);
      for (const l of lines) expect(l).not.toContain('tenant');
    });
  });

  it('counts replays', async () => {
    const m = new MetricsService();
    m.recordReplay();
    m.recordReplay();
    expect(sample(await m.metrics(), 'pos_idempotency_replay_total')).toBe(2);
  });

  it('records a request in both the counter and the histogram, under the same labels', async () => {
    const m = new MetricsService();
    m.recordRequest('POST', '/api/v1/sales', 201, 0.03);
    const text = await m.metrics();
    const labels = 'method="POST",route="/api/v1/sales",status_code="201"';
    expect(sample(text, `http_requests_total{${labels}}`)).toBe(1);
    expect(sample(text, `http_request_duration_seconds_count{${labels}}`)).toBe(1);
    expect(sample(text, `http_request_duration_seconds_bucket{le="0.025",${labels}}`)).toBe(0);
    expect(sample(text, `http_request_duration_seconds_bucket{le="0.05",${labels}}`)).toBe(1);
  });

  describe('DB pool gauges', () => {
    it('have no per-state samples until a reader is attached', async () => {
      const text = await new MetricsService().metrics();
      expect(text).not.toMatch(/^pos_db_pool_connections\{/m);
      // A gauge without labels always exports one sample, so the size reads 0 until then.
      expect(sample(text, 'pos_db_pool_max_connections')).toBe(0);
    });

    it('report every state and the pool size from the reader', async () => {
      const m = new MetricsService();
      m.observeDbPool(() => POOL);
      const text = await m.metrics();
      expect(sample(text, 'pos_db_pool_connections{state="in_use"}')).toBe(3);
      expect(sample(text, 'pos_db_pool_connections{state="idle"}')).toBe(2);
      expect(sample(text, 'pos_db_pool_connections{state="waiting"}')).toBe(1);
      expect(sample(text, 'pos_db_pool_max_connections')).toBe(20);
    });

    it('read the pool at scrape time, not when the reader is attached', async () => {
      const m = new MetricsService();
      let inUse = 0;
      m.observeDbPool(() => ({ ...POOL, inUse }));
      expect(sample(await m.metrics(), 'pos_db_pool_connections{state="in_use"}')).toBe(0);
      inUse = 7;
      expect(sample(await m.metrics(), 'pos_db_pool_connections{state="in_use"}')).toBe(7);
    });
  });

  describe('pos_queue_jobs', () => {
    it('has no samples until a reader is attached', async () => {
      expect(await new MetricsService().metrics()).not.toMatch(/^pos_queue_jobs\{/m);
    });

    it('reports every state per queue, a state the reader left out as 0', async () => {
      const m = new MetricsService();
      m.observeQueues(async () => ({
        'sale-post': { waiting: 4, active: 1, delayed: 0, failed: 2 },
        backup: { failed: 1 },
      }));
      const text = await m.metrics();
      expect(sample(text, 'pos_queue_jobs{queue="sale-post",state="waiting"}')).toBe(4);
      expect(sample(text, 'pos_queue_jobs{queue="sale-post",state="failed"}')).toBe(2);
      expect(sample(text, 'pos_queue_jobs{queue="backup",state="failed"}')).toBe(1);
      expect(sample(text, 'pos_queue_jobs{queue="backup",state="waiting"}')).toBe(0);
      expect(sample(text, 'pos_queue_jobs{queue="backup",state="active"}')).toBe(0);
    });

    it('drops the samples instead of serving stale counts when the reader fails', async () => {
      const m = new MetricsService();
      let fail = false;
      m.observeQueues(async () => {
        if (fail) throw new Error('redis-queue unreachable');
        return { backup: { waiting: 9 } };
      });
      expect(sample(await m.metrics(), 'pos_queue_jobs{queue="backup",state="waiting"}')).toBe(9);
      fail = true;
      const text = await m.metrics();
      expect(text).not.toMatch(/^pos_queue_jobs\{/m);
      // The rest of the scrape still answers.
      expect(sample(text, 'pos_documents_total{kind="sale"}')).toBe(0);
    });
  });
});
