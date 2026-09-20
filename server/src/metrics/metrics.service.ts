import { Injectable } from '@nestjs/common';
import {
  collectDefaultMetrics,
  Counter,
  Histogram,
  Registry,
} from 'prom-client';

const HTTP_METRIC_LABELS = ['method', 'route', 'status_code'] as const;

@Injectable()
export class MetricsService {
  private readonly registry = new Registry();

  private readonly httpRequestsTotal: Counter<'method' | 'route' | 'status_code'>;
  private readonly httpRequestDurationSeconds: Histogram<
    'method' | 'route' | 'status_code'
  >;
  private readonly idempotencyReplayTotal: Counter<string>;

  constructor() {
    collectDefaultMetrics({ register: this.registry });

    // Metric names are pinned by existing Grafana panel queries (pos-overview.json:86,104).
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
