# Observability + Security add-on: research (2026-09-29 → 10-01)

> ℹ️ **This is research, not a plan we have committed to.** Nothing in this folder has been built or deployed yet.
> Every version, price and quota was correct on the day it was checked. Re-verify before using any of it.
> Each doc went through one round of `/scrutinize` with corrections applied. Both were reviewed against mob04's real specs:
> **4 vCPU / 6 GB RAM / 48 GB disk**. The `mem_limit` values already add up to **4,256 MB** (`07_CICD_DEPLOY.md:211, :226-229`).

| File | Content |
|---|---|
| [`observability-logs-traces-uptime.md`](observability-logs-traces-uptime.md) | Logs, traces, uptime and alerts, with a RAM/disk budget table |
| [`security-secrets-api.md`](security-secrets-api.md) | Secrets plus a gap analysis against the OWASP API Top 10 (2023) |

## Recommended toolset (summary)

### Monitoring
| Area | Tool | Status | RAM on VM |
|---|---|---|---|
| Metrics / dashboard | Prometheus + node-exporter + Grafana 11.2.0 | already have | 832 MB (existing) |
| App logs | pino (JSON + redaction + `correlationId`) | already have | — |
| Prevent disk-full from logs | Docker `json-file` rotation (`max-size` / `max-file`) | new · can do today (config only) | 0 |
| Uptime (no second machine) | Healthchecks.io heartbeat: a cron on mob04 calls `https://127.0.0.1/health/ready` and then pings out | new · **check egress on mob04 first** | 0 |
| Alerts for problems inside the VM | Grafana alerting (file provisioning in `provisioning/alerting`) | new · **needs owner OK against ADR-0013** | 0 |
| Alert channel | Telegram (primary) + email (fallback) | new | 0 |
| Central log store | VictoriaLogs + shipper (syslog driver / Alloy / vlagent, chosen after testing) | conditional · only if rotation + grep isn't enough, and docker.io must be exempted first | ~256 MB |
| Traces | OpenTelemetry + Tempo | **deferred** (`instrumentation-nestjs-core` 0.68.0 supports `<12` while the repo uses Nest 12; RAM) | — |

### Security
| Area | Tool | Priority |
|---|---|---|
| Dependency alerts | Dependabot alerts (currently **off**, so `dependabot.yml` does nothing) | P0, owner turns it on |
| Secret scanning | GitHub secret scanning + push protection (currently **off**, although `07 §4:183` and `ADR-0013:52` say on) | P1, owner turns it on |
| Scan secrets in git history | gitleaks in CI (`runs-on: ubuntu-latest` only) | P1 |
| SAST | CodeQL default setup | P1 |
| HTTP headers | Nginx `server_tokens off` + nosniff / Referrer-Policy / X-Frame-Options | P1 |
| CORS | Set `CORS_ORIGINS` on mob04 (today reflects any Origin; low risk because there are no cookies) | P2 |
| Secret storage | `deploy/demo.env.example` (key names only) + team password manager · SOPS+age optional | P2 |
| Supply chain | Pin third-party Actions by SHA | P2 |
| Already have | Trivy, pnpm audit, OSV-Scanner, digest pinning, RLS, argon2, Helmet, rate limit, body cap | ✅ |

The whole security set adds **0 MB** to the VM: every item is a CI job, a laptop tool, a GitHub setting or nginx config.

### Considered and not used
Uptime Kuma / Gatus / blackbox_exporter (need a second machine) · UptimeRobot (mob04 has no public IP) ·
Loki (docs list no size cap) · Alertmanager / Wazuh / ELK (rejected by ADR-0013) · Vault / Infisical
(4–16 GB RAM) · WAF (Coraza's nginx connector is experimental) · ZAP (the server has no OpenAPI spec) ·
HSTS (the VM is reached by IP, and browsers ignore HSTS for IP hosts per RFC 6797 §8.1.1) · Grafana's "Line" contact point (LINE Notify shut down 2025-03-31).

## Budget
| Plan | Total mem_limit | Share of 6 GB |
|---|---|---|
| Today | 4,256 MB | 69% |
| + heartbeat + Grafana alerting | 4,256 MB | 69% |
| + VictoriaLogs (syslog shipper) | ≈4,512 MB | 73% |
| + VictoriaLogs (Alloy shipper) | ≈4,640 MB | 76% |

⚠️ These figures are sums of caps, not measurements (#380). They do not yet account for the OS, dockerd, Postgres page cache or the future self-hosted runner (#67).

## Open — needs a person to decide or act
1. **Owner:** may Grafana alerting run against ADR-0013 ("no Alertmanager")? Grafana has its own built-in Alertmanager.
2. **Owner:** is Telegram + email without LINE acceptable? (Healthchecks.io has no LINE integration.)
3. **Owner:** is a US-hosted SaaS heartbeat acceptable? Only a ping goes out, no customer data.
4. **Owner:** turn on Dependabot alerts / secret scanning / CodeQL, and fix `07 §4:183` and `ADR-0013:52` to match reality.
5. **On mob04:** test egress to `hc-ping.com` and `api.telegram.org` (commands in §3.4 of the observability doc). If the issuer is Fortinet with no SAN, they are blocked like ghcr.io.
6. Is a central log store needed at all? Try rotation + `docker compose logs | grep correlationId` first.

## Rollout order (when work starts)
1. Log rotation → 2. Egress check on mob04 → 3. Heartbeat (cron in `provision.yml`, `HC_PING_URL` in `.env`) →
4. Grafana alerts (file provisioning, token via env `:-`) → 5. Central log store (conditional) → 6. Traces (deferred)

Security, in parallel: P0/P1 settings by the owner → gitleaks + CodeQL + nginx headers → P2.
