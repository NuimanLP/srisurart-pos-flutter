# Uptime Kuma — local uptime checks

Service `uptime-kuma` in [`../compose/observability.yml`](../compose/observability.yml).
**Local development only** — it is not part of the VM deploy.

Open <http://127.0.0.1:3001>. The first visit asks you to create the admin account; that
account and every monitor live in the `uptime-kuma-data` volume. Uptime Kuma has no config
file for monitors, so they are added by hand in the UI — once per volume.

## Monitors to add

Uptime Kuma runs inside the compose network, so it reaches the other services by their
compose service name, not through `localhost`.

| Name | Type | Target | What a failure means |
|---|---|---|---|
| API 1 ready | HTTP(s) | `http://api-1:3000/health/ready` | that instance cannot serve (DB/Redis unreachable or process down) |
| API 2 ready | HTTP(s) | `http://api-2:3000/health/ready` | same, instance 2 |
| API 3 ready | HTTP(s) | `http://api-3:3000/health/ready` | same, instance 3 |
| Nginx (front door) | HTTP(s) | `https://nginx/health/live` — tick *Ignore TLS/SSL errors* (dev certificate) | the path every client actually uses is down |
| Postgres | TCP Port | host `postgres`, port `5432` | database is not accepting connections |
| Redis cache | TCP Port | host `redis-cache`, port `6379` | cache is down |
| Redis queue | TCP Port | host `redis-queue`, port `6379` | background jobs cannot be queued |
| Prometheus | HTTP(s) | `http://prometheus:9090/-/healthy` | metrics are not being collected |
| Grafana | HTTP(s) | `http://grafana:3000/api/health` | dashboard is down |
| Loki | HTTP(s) | `http://loki:3100/ready` | logs are not being stored |

A 20–60 s heartbeat interval is plenty locally. The uptime percentage and response-time
history per monitor are on each monitor's own page.

## Logs

Logs are not in Uptime Kuma — they are in Grafana (<http://127.0.0.1:3000>) → *Explore* →
datasource **Loki**. Every container of this compose project is collected, labelled by
compose service name:

```logql
{service="api-1"}                      # one service
{service=~"api-.*"} |= "error"         # all API instances, lines containing "error"
{service="postgres"}
```

Retention is 7 days (`../loki/loki.yml`). On the very first start Alloy also tries to send
each container's older backlog; Loki refuses lines older than 7 days with
`timestamp too old` — that is expected, once, and not a fault.
