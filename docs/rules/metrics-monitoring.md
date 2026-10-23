# Metrics, monitoring and alerting

> Moved verbatim from `CLAUDE.md` on 2026-10-23 (docs review R9). These rules still bind; `CLAUDE.md`'s index says when to read this file.
> Scope: `server/src/metrics/`, `deploy/prometheus/`, `deploy/grafana/`, Gatus, Discord alerting.

**Metrics (`server/src/metrics/`, `deploy/prometheus/`, `deploy/grafana/`) — landed 2026-09-21:**
- `http_requests_total` and `http_request_duration_seconds` are **named by the existing
  Grafana panel expressions** — renaming either silently blanks the dashboard.
- The counting happens in **middleware**, not an interceptor, because requests a guard
  rejects (401/429) must still be counted, and `route` must be the pattern, not the
  concrete path. `GET /metrics` returns text format and is **not** wrapped in the
  envelope; Nginx answers `location = /metrics` with 404 (exactly `=`, not `^~`, which
  would also block any future path merely starting with `/metrics`).
- `/metrics`, `/health/live` and `/health/ready` are **excluded from the SLI**
  (`UNMEASURED_PATHS`). Owner-approved 2026-09-21 as an addendum to #335 D6: scrape every
  15 s × 3 instances plus healthchecks manufactures ~36 guaranteed `200`s a minute, and
  the success-rate and p95 panels average every series, so a day where every real bill
  failed would still read ~92% healthy.
- `pos_idempotency_replay_total` carries **no `tenant_id` label** (panels use
  `sum()`/`increase()`), and is incremented **only inside `onTransactionCommit`** in the
  replay branch, so a rolled-back write is never counted. `MetricsService` is a
  **required** dependency of `IdempotencyService` — if that wiring is ever loosened back
  to `@Optional()`, a broken graph silently zeroes the counter instead of failing at
  bootstrap.
- **Business/runtime metrics (2026-10-04):** `pos_documents_total{kind=sale|void|return}`,
  `pos_db_pool_connections{state=in_use|idle|waiting}` + `pos_db_pool_max_connections`,
  `pos_queue_jobs{queue,state}` — all named by `pos-overview.json` panels (ids 20–26).
  Documents follow the replay counter's rules: **no `tenant_id` label**, counted **only in
  `onTransactionCommit`**, placed after the existing-sale early return so a replayed key never
  counts twice; `void` = a clerk's void only (the auto-void of a fully returned bill is a
  `return`). `MetricsService` is a required dependency of `SalesService`/`VoidService`/
  `ReturnsService`. The pool gauge reads the `DB_POOL_STATS` reader (`db.module.ts`), never the
  `DataSource` — `tenant-door.spec.ts` refuses that. Queue depth lives in Redis, so all three
  instances report the same numbers: panels take `max()`, never `sum()`; the read has a 1 s
  timeout and drops its samples on error rather than serving stale counts.
  `RuntimeMetricsModule` is imported by `AppModule` only (the worker builds none of this).

- **App metrics (#597, 2026-10-04, deployed `41a8f19`):** `pos_documents_total{kind}` (counted in
  `onTransactionCommit`), `pos_db_pool_connections{state}` + `pos_db_pool_max_connections`,
  `pos_queue_jobs{queue,state}` (redis-queue read under a 1 s `withTimeout`) — named by
  `pos-overview.json` (29 panels), same rename rule as above. Queue reads are single-flight
  (`withTimeout` cannot cancel `getJobCounts`): a scrape joins a still-pending read instead of
  issuing new commands that would pile up in ioredis during a redis-queue outage — never remove it.
- **Local observability overlay (#600/#604, 2026-10-04) is dev-only:** `deploy/compose/observability.yml`,
  `local-api.yml`, `deploy/{alloy,loki,grafana-local,prometheus-local}/` are never referenced by Ansible.
  The production `deploy/prometheus/prometheus.yml` loads `scrape.d/*.yml` (absent on `mob04`).
  🔴 `deploy.yml` only **warns** if Prometheus/Grafana fail after a deploy, so the
  `promtool check config` step in `server.yml` `nginx-check` is the real gate — keep its image
  digest equal to `monitoring.yml`'s. Keep local-only files out of `deploy/prometheus/` and
  `deploy/grafana/` (deploy.yml copies those trees wholesale).
- ~~Uptime heartbeat (#596, Healthchecks.io)~~ — **retired 2026-10-13** (not the team's account):
  script/test deleted, `provision.yml` removes the cron (same `name:`, `state: absent`) and the VM copy.
  🔴 **Removed from `mob04` 2026-10-18** by hand over SSH (cron, script, `HEALTHCHECKS_PING_URL`) after the account owner paused
  the check; backups `/opt/pos/.env.bak-20261018T024347Z`, `/opt/pos/.deploy.cron.bak-20261018T024347Z` (07 §10.5).
- **Alerting → Discord + Gatus (2026-10-13, ADR-0013 addendum *Accepted* 2026-10-18; 07 §10.5; released in `main` `21ad935` via PR #727 —
  on `mob04` since 2026-10-17: Gatus 9/9 success, 10 rules Normal, `node-textfile` created by hand; Discord webhook set + tested 2026-10-18).**
  Grafana built-in alerting, file-provisioned in `deploy/grafana/provisioning/alerting/pos-alerts.yml` (contact
  point + policy + 10 rules on datasource uid `Prometheus`; Alertmanager still rejected). Gatus (`monitoring.yml`,
  `deploy/gatus/config.yaml`, `127.0.0.1:3300`, 64m) checks `/health/ready` through Nginx+TLS (+ cert > 14 days),
  platform-ui (**403** = up: its nginx allows only the bridge gateway, so every container gets 403), bull-board (401),
  Postgres/Redis×2/etcd TCP, Grafana, Prometheus. Rules: API instance down uses
  `up{job="api-metrics"}` (the always-0 `api-readiness` job was removed 2026-10-21 — Prometheus 3 refuses its JSON); anything a rolling deploy can trip has `for:` ≥ 5m;
  deleting a rule from the file does not delete it (use `deleteRules:`); annotations are not env-interpolated and
  never carry tenant/customer data. `ALERT_DISCORD_WEBHOOK` is a secret (`/opt/pos/.env` only); unset = a
  placeholder (Grafana refuses an empty Discord URL) + `provision.yml` warning. Gatus trusts the private CA via
  `SSL_CERT_DIR=/pos-ca` (never `SSL_CERT_FILE`); `deploy/gatus-ca/pos-ca.crt` must stay a byte copy of
  `frontend/assets/certs/pos-ca.crt` (CI `cmp`); config dir-mounted, never a single file. **Backup freshness:**
  `backup-db.sh` writes `pos_backup_last_success_timestamp_seconds` to `/opt/pos/node-textfile` (0755, from
  `provision.yml`) only on a green run that is not DB-only (`BACKUP_VOLUMES=0`); rule "backup stale" > 26h, no data
  = Alerting. 🔴 **First-release order (07 §10.5):** merge `develop`→`main` first (Deploy waits for approval) → in that
  window run `provision.yml` as `cloud` from a **clean `origin/main`** worktree (before the merge `origin/main` holds the
  old playbook: heartbeat cron back, no `node-textfile`, old `backup-db.sh`) → seed the gauge by running `backup-db.sh`
  once as `deploy` in cron's env → then approve. `deploy.yml` warns (never fails) when `node-textfile` is missing or
  `/opt/pos/scripts/backup-db.sh` differs from the release's copy. Before provision (the Healthchecks.io check is
  paused and the heartbeat gone from `mob04` since 2026-10-18), compare the
  local `DEMO_ENV_FILE` sha256 with the VM's `/opt/pos/.env` (stale file = wrong DB/etcd passwords). The nightly
  `backup-db.sh` also prunes `/opt/pos/backups-pre-migrate` past 30 days (top level only; those dumps hold customer
  data — PDPA, owner's retention call). 🔴 **Rollback past this release** (old `deploy.yml`) leaves an orphan `gatus`
  container and the 10 file-provisioned rules in Grafana (which never deletes a rule whose file vanished) → "Gatus
  down"/"backup stale" page every 4h: `docker rm -f` the gatus container and drop a `deleteRules:` file (07 §7 row
  "rollback ข้าม release alerting"); the provisioning API cannot delete a `file`-provenance rule. CI: `monitoring-alerting.test.sh`
  (nginx-check) boots prometheus+grafana+gatus from `monitoring.yml` and checks rules load and evaluate without
  `error`, Gatus config loads, and the Gatus amd64 binary is `GOAMD64=v1` (mob04 = qemu64). 🔴 Gatus runs on the host
  it watches: a dead host is caught only by the owner-PC watchdog (#733), so it pages nobody while the owner PC is
  off — documented, not claimed. Owner steps on
  `mob04` (Discord egress `curl -v https://discord.com/api/v10/gateway`, webhook, `DEMO_ENV_FILE`, provision) in 07 §10.5.
  🔴 A webhook send that fails at the network level puts the **full webhook URL (token) in `docker logs gatus`** (Go
  error text) — never paste those logs unredacted; leaked = rotate the webhook. Every rule is `execErrState: Alerting`,
  never `Error` (Grafana 11.2's Error skips `for:` — one failed evaluation while a deploy recreates Prometheus would
  page a DatasourceError), and none is `for: 0s`. p95 and 5xx rules only evaluate above 0.05 req/s.
