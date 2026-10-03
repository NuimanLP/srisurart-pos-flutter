# Loki — local log store

Services `loki` and `alloy` in [`../compose/observability.yml`](../compose/observability.yml).
**Local development only** — they are not part of the VM deploy.

Logs are read in Grafana (<http://127.0.0.1:3000>) → *Explore* → datasource **Loki**. Every
container of this compose project is collected, labelled by compose service name:

```logql
{service="api-1"}                      # one service
{service=~"api-.*"} |= "error"         # all API instances, lines containing "error"
{service="postgres"}
```

Retention is 7 days (`loki.yml`). On the very first start Alloy also tries to send each
container's older backlog; Loki refuses lines older than 7 days with `timestamp too old` —
that is expected, once, and not a fault.

What Alloy found and is sending: its debug UI at <http://127.0.0.1:12345>.
