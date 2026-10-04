import { Injectable } from '@nestjs/common';
import {
  collectDefaultMetrics,
  Counter,
  Gauge,
  Histogram,
  Registry,
} from 'prom-client';

import type { DbPoolStats } from '../infra/db.module.js';

const HTTP_METRIC_LABELS = ['method', 'route', 'status_code'] as const;
type HttpMetricLabel = (typeof HTTP_METRIC_LABELS)[number];

const DOCUMENT_KINDS = ['sale', 'void', 'return'] as const;
export type DocumentKind = (typeof DOCUMENT_KINDS)[number];

const QUEUE_JOB_STATES = ['waiting', 'active', 'delayed', 'failed'] as const;
export type QueueJobState = (typeof QUEUE_JOB_STATES)[number];
export type QueueJobCounts = Record<string, Partial<Record<QueueJobState, number>>>;

@Injectable()
export class MetricsService {
  private readonly registry = new Registry();

  private readonly httpRequestsTotal: Counter<HttpMetricLabel>;
  private readonly httpRequestDurationSeconds: Histogram<HttpMetricLabel>;
  private readonly idempotencyReplayTotal: Counter<string>;
  private readonly documentsTotal: Counter<'kind'>;
  private readonly dbPoolConnections: Gauge<'state'>;
  private readonly dbPoolMax: Gauge<string>;
  private readonly queueJobs: Gauge<'queue' | 'state'>;

  // Set by `RuntimeMetricsService` once the pool and the queues exist. Until then the two
  // gauges below simply have no samples — `MetricsService` itself stays dependency-free.
  private dbPoolReader?: () => DbPoolStats;
  private queueReader?: () => Promise<QueueJobCounts>;

  constructor() {
    collectDefaultMetrics({ register: this.registry });

    // Metric names are pinned by the exprs of the *API success rate* and *API p95 latency*
    // panels in deploy/grafana/dashboards/pos-overview.json — renaming either one here is a
    // two-sided change (D4 #335).
    this.httpRequestsTotal = new Counter({
      name: 'http_requests_total',
      help: 'Total number of HTTP requests',
      labelNames: HTTP_METRIC_LABELS,
      registers: [this.registry],
    });

    this.httpRequestDurationSeconds = new Histogram({
      name: 'http_request_duration_seconds',
      help: 'HTTP request duration in seconds',
      labelNames: HTTP_METRIC_LABELS,
      buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
      registers: [this.registry],
    });

    // Business counter per D5 of #335: counts idempotent request replays after commit.
    // Intentionally carries NO tenant_id label to avoid cardinality explosion and preserve privacy.
    this.idempotencyReplayTotal = new Counter({
      name: 'pos_idempotency_replay_total',
      help: 'Total number of idempotent request replays',
      registers: [this.registry],
    });

    // Business documents written, counted at commit like the replay counter above and, for
    // the same reason, with NO tenant_id label. `sale` also covers a quote converted to a
    // sale and a bill replayed in through /sync/push; `void` is a clerk's void only — the
    // automatic void of a fully-returned bill is a `return`.
    this.documentsTotal = new Counter({
      name: 'pos_documents_total',
      help: 'Business documents committed, by kind (sale, void, return)',
      labelNames: ['kind'],
      registers: [this.registry],
    });
    // Zero-initialised so `increase()` has a starting sample before the first bill.
    for (const kind of DOCUMENT_KINDS) this.documentsTotal.inc({ kind }, 0);

    // The request pool of THIS process (#162: a pool with every connection held and callers
    // still waiting is a deadlock in the making). Read at scrape time, never polled.
    this.dbPoolConnections = new Gauge({
      name: 'pos_db_pool_connections',
      help: 'Request-pool connections of this process, by state (in_use, idle, waiting)',
      labelNames: ['state'],
      registers: [this.registry],
      collect: () => {
        const stats = this.dbPoolReader?.();
        if (!stats) return;
        this.dbPoolConnections.set({ state: 'in_use' }, stats.inUse);
        this.dbPoolConnections.set({ state: 'idle' }, stats.idle);
        this.dbPoolConnections.set({ state: 'waiting' }, stats.waiting);
      },
    });

    this.dbPoolMax = new Gauge({
      name: 'pos_db_pool_max_connections',
      help: 'Configured size of the request pool of this process (DB_POOL_SIZE)',
      registers: [this.registry],
      collect: () => {
        const stats = this.dbPoolReader?.();
        if (stats) this.dbPoolMax.set(stats.max);
      },
    });

    // Queue depth lives in Redis, so all three api instances report the same numbers —
    // dashboards take max(), never sum(). A reader that fails or times out drops the samples
    // rather than failing the scrape or serving stale counts.
    this.queueJobs = new Gauge({
      name: 'pos_queue_jobs',
      help: 'BullMQ jobs per queue, by state (waiting, active, delayed, failed)',
      labelNames: ['queue', 'state'],
      registers: [this.registry],
      collect: async () => {
        if (!this.queueReader) return;
        try {
          const counts = await this.queueReader();
          for (const [queue, byState] of Object.entries(counts)) {
            for (const state of QUEUE_JOB_STATES) {
              this.queueJobs.set({ queue, state }, byState[state] ?? 0);
            }
          }
        } catch {
          this.queueJobs.reset();
        }
      },
    });
  }

  observeDbPool(reader: () => DbPoolStats): void {
    this.dbPoolReader = reader;
  }

  observeQueues(reader: () => Promise<QueueJobCounts>): void {
    this.queueReader = reader;
  }

  get contentType(): string {
    return this.registry.contentType;
  }

  metrics(): Promise<string> {
    return this.registry.metrics();
  }

  recordReplay(): void {
    this.idempotencyReplayTotal.inc();
  }

  /** Call from `onTransactionCommit` only — a rolled-back write is not a document. */
  recordDocument(kind: DocumentKind): void {
    this.documentsTotal.inc({ kind });
  }

  recordRequest(
    method: string,
    route: string,
    statusCode: number,
    durationSeconds: number,
  ): void {
    const labels = {
      method,
      route,
      status_code: String(statusCode),
    };
    this.httpRequestsTotal.inc(labels);
    this.httpRequestDurationSeconds.observe(labels, durationSeconds);
  }
}
