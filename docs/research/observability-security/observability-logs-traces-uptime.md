# Observability add-ons: logs, traces, uptime (research, 2026-09-29)

> **This is a recommendation, not a decision.** It was written for the owner's note asking about logs,
> traces and uptime monitoring (the note named Uptime Kuma as "uptime puma"). Nothing here is built, and no
> ticket was opened. **ADR-0013 still binds.** It rejects ELK/Wazuh and Alertmanager
> (`docs/Backend_design/adr/0013-cicd-toolchain.md`, `07_CICD_DEPLOY.md §1, §5, §10.2`). Every proposal
> below is checked against that, and any new container on `mob04` needs an **ADR-0013 addendum**.
>
> **Hard constraint (owner, 2026-09-29):** everything must fit `mob04`: 4 vCPU, 6 GB RAM, 48 GB disk
> (`07_CICD_DEPLOY.md §5`). Every number is labelled **official** (quoted from vendor docs) or
> **estimate** (my own number, still unmeasured). The real RSS of the stack has **never been measured**
> (#380), so every RAM line here is a `mem_limit` cap, the same convention `07 §5` uses. None of them is
> a measured usage.
>
> ⏱️ **Point-in-time facts.** Every version number, release date, and the LINE quota (300 msgs/month in
> Thailand) was read on **2026-09-29** from GitHub releases, the npm registry, or the vendor's page.
> **Re-verify them before acting on this doc.**

## TL;DR

| Concern | Recommendation | Runner-up | Why the runner-up lost |
|---|---|---|---|
| **Step 0 (logs, do first; deliverable today)** | **Docker log rotation** (`logging:` with `max-size`/`max-file` on every service), plus `docker compose logs … \| grep <correlationId>` | none | This is not optional. Today **no service has any `logging:` block** and Docker's `json-file` default is **unlimited** (§1.1), so the POS disk can fill up with logs. It is config only, costs 0 MB of RAM and needs no image pull. |
| **Logs (central store): CONDITIONAL** | **Only if step 0 proves insufficient.** Then **VictoriaLogs** (single binary, **hard disk cap**, memory flags that size its caches, built-in web UI). **The shipper is chosen after testing** among the Docker `syslog` driver (no extra container), Grafana Alloy, and `vlagent` (§1.3). Needs an **ADR-0013 addendum**. | Grafana Loki (monolithic) + Alloy | **This is a judgement call.** VictoriaLogs has a documented hard disk cap. Loki's docs list only time-based retention, though Loki could be capped indirectly with a filesystem quota. Against VictoriaLogs: Loki is native to Grafana, and VictoriaLogs adds a second query language (LogsQL). Loki is a valid runner-up that is heavier to operate here. |
| **Traces** | **Defer. Do not add on `mob04` now.** Keep the existing `correlationId` (Nginx → pino) as the cross-instance join key. | When revisited: Grafana **Tempo** (monolithic); runner-up Jaeger v2 | See §2. ESM needs an **experimental** loader. There is no official overhead figure. The RAM budget fails once the SDK runs in 3 API instances plus a Tempo container. The currently *published* Nest instrumentation also does not cover Nest 12 (the fix is on `main` only). |
| **Uptime ("VM/API is gone")** | **Owner decision 2026-09-29: no second machine.** Use an **outbound heartbeat to Healthchecks.io** as a dead-man's switch. A cron job on `mob04`, installed by `provision.yml`, pings every 5 minutes, but only if `/health/ready` passes. With no ping inside period + grace, Healthchecks alerts on Telegram/email. **0 MB on the VM.** 🔴 **VM-gated:** it only works if the FortiGate lets `hc-ping.com` through (§3.4). | Uptime Kuma or Gatus on a second campus machine, **only if one appears later** | The owner ruled out a second machine. A probe on `mob04` itself cannot report `mob04` down, and SaaS probes cannot reach the campus-internal VM. An *outbound* heartbeat reverses the direction, so only a ping leaves the VM. |
| **In-VM alerts (container down, disk, 5xx, p95)** | **Grafana alerting** (built into the Grafana 11.2 already deployed; no Alertmanager container), rules + Telegram contact point **provisioned as files** with the token from env | a separate Prometheus Alertmanager | ADR-0013 says "ไม่มี Alertmanager". Grafana's built-in Alertmanager adds no container, but **needs an owner OK against ADR-0013** (§6). |
| **Alert channel** | **Telegram bot** (supported by Healthchecks.io and Grafana), plus **email** | LINE Messaging API. Healthchecks.io has no LINE integration; Gatus/Uptime Kuma do. | **LINE Notify was shut down on 2025-03-31.** Grafana's built-in "Line" contact point still posts to the dead LINE Notify API (§3.6), so **never use it**. |

**Budget verdict (§4):** the verdicts are **caps-based arithmetic, not measurements**. Step 0 plus
VictoriaLogs on the VM (with the syslog driver, or with Alloy), plus the heartbeat and Grafana alerting
(+0 MB each), come to about
**4.5–4.64 GB of mem_limit caps out of 6 GB. That is a PASS on paper, conditional on #380.** What remains,
*at most* about 1.5 GB, is shared by the host OS, dockerd, Postgres's page cache and the planned
self-hosted runner (#67), so the real margin is smaller and unknown. Adding **traces fails** the budget:
about 5.0–5.3 GB of caps, with an unknown per-process SDK cost inside the 384 MB API caps. **Disk: PASS**,
adding about 3.5 GB of bounded data.

**Delivery:** step 0 (rotation) can ship today. The heartbeat and Grafana alerting need no new image,
but they can ship only once the §3.4 connectivity check on `mob04` passes for `hc-ping.com` and
`api.telegram.org`. The central log store is **blocked on the FortiGate
exemption for `registry-1.docker.io`**, and also `quay.io` if that mirror is used; `quay.io` is not on the
exemption list in `07`. The monitoring overlay itself has **never** been deployed to `mob04` via a pull.

---

## 0. What exists today (verified in the repo)

- **Logger:** `pino` 10.3.1 + `pino-http` 11 (`server/package.json`, `pnpm-lock.yaml`), in
  `server/src/common/logger.ts`. It writes **single-line JSON to stdout**. `PinoNestLogger` adapts Nest's
  framework logs into the same stream, and `api`, `worker` and `bull-board` all use `createLogger`.
  **Redaction exists already:** `authorization`, `cookie`, `x-device-token` headers, plus `password`,
  `pin`, `newPassword`, `currentPassword`, `ownerPassword`, `tempPassword`, `passwordChangeToken`,
  `refreshToken`, `deviceToken` and `enrolCode`, both under `req.body.*` and as `*.<field>`, plus
  `req.body.code`. Request bodies are never serialised. **So `nestjs-pino` is not needed.** It would only
  replace an adapter that already works.
- **Correlation:** Nginx mints or forwards `X-Correlation-ID` (`server/docker/nginx/nginx.conf:18-20, 72`)
  and writes its access log as JSON with `correlation_id` (`nginx.conf:10-15`). `pino-http` puts it on every
  request line as `correlationId` (`logger.ts` `requestLogger`). **That already joins one bill's lines
  across `api-1..3`.**
- **Metrics:** Prometheus 2.55.1 (512m, 7d / 2GB retention) + Grafana 11.2.0 (256m) + node-exporter (64m) in
  `deploy/compose/monitoring.yml`. All three are loopback-only and reached over an SSH tunnel (`07 §5, §10`).
  `server/src/metrics/` exports `http_requests_total`, `http_request_duration_seconds` and
  `pos_idempotency_replay_total`, which has **no tenant label on purpose** (CLAUDE.md "Metrics").
- **No log rotation anywhere.** Grepping `server/docker-compose.yml`, `deploy/compose/*.yml` and
  `deploy/ansible/*.yml` finds no `logging:`, no `max-size` and no `daemon.json`.
- **No uptime check that can see "the VM is down".** The `api-readiness` scrape job reads **DOWN** even when
  the API is up, because `/health/ready` returns JSON (`deploy/prometheus/prometheus.yml` comment).
  Nothing pages anyone (`07 §10`: "ไม่มี Alertmanager").
- **Earlier decisions on record:** ADR-0013 and `07 §10.2` reject Wazuh/ELK for RAM (4–5 GB) and reject
  Alertmanager. `docs/study/18_capstone.md` has a *hypothetical example* ADR ("Loki: possible, but no
  problem needs it yet"). It is teaching material, not a decision. `04_QA_SCRUTINY.md:543` (A09) lists
  "alerting ไม่มี" as a known gap.
- **Network:** `mob04` (`172.30.58.20`) is **campus-internal, with no public address** (`07 §5`). The
  campus FortiGate breaks TLS to `ghcr.io`. The exemption request in `07` covers `ghcr.io`,
  `registry-1.docker.io` and `gcr.io`, **not `quay.io`**. Whether inspection also breaks the other
  registries, or alert APIs such as `api.line.me` and `api.telegram.org`, is **unverified**
  (`docs/handoff_log/handoff_demo-335-merge-and-cd-blocked_21_09_2026.md` §"ไม่รู้ว่า inspection ครอบทุก host").
  The monitoring overlay (Prometheus/Grafana/node-exporter) has **never** been pulled onto `mob04`.

---

## 1. Logs

### 1.1 Step 0: rotation (do this whatever else is chosen)

Docker's `json-file` driver has a `max-size` that "Defaults to -1 (unlimited)" [D1]. Docker's own docs
advise using the `local` driver "to prevent disk-exhaustion. By default, no log-rotation is performed" [D2].
The repo never sets either, so every container's stdout grows without limit on the 48 GB disk. That is
the same failure mode the Prometheus comment warns about ("a service without a cap is what turns a full
disk into a dead POS").

**Fit:** add one `x-logging: &logging` anchor with `driver: json-file`, `options: {max-size: "10m",
max-file: "3"}` to `server/docker-compose.yml` and `deploy/compose/monitoring.yml`, and `<<: *logging` on
every service. **Disk cap (estimate):** about **18 containers** (15 services in
`server/docker-compose.yml`, including one-shots such as `certgen`, `migrate` and `etcd-init`, plus 3 in
`monitoring.yml`) × 30 MB ≈ **0.55 GB**. It is config only: no new image, and it can ship today.
`docker compose logs api-1 api-2 api-3 | grep <correlationId>` already answers "find one bill across
three instances" at zero RAM.

**What step 0 does NOT solve:** logs belong to the container. `deploy.yml` recreates containers on every
release, and a recreated container starts with a new log file. So an incident that straddles a deploy
loses the pre-deploy lines. This is standard Docker behaviour, not quoted from a doc. **Verify on
`mob04`** with `docker inspect -f '{{.LogPath}}' <c>` before and after a deploy. That gap, plus "search
across days" (the capstone example's own `(−)` point), is the **trigger** for §1.2. If neither hurts in
practice, stop at step 0.

### 1.2 Central store (conditional): VictoriaLogs vs Loki

| | **VictoriaLogs v1.52.0** (2026-07-16) | **Grafana Loki v3.7.8** (2026-09-17) |
|---|---|---|
| Shape | "a single zero-config executable" [V1] | monolithic mode: all components in one process, `-target=all`, fits "up to approximately 20GB per day" [L1] |
| **Disk cap** | ✅ `-retention.maxDiskSpaceUsageBytes` or `-retention.maxDiskUsagePercent`, plus `-retentionPeriod` (default 7d) [V2] | ⚠️ The retention docs list only `retention_period` and `retention_stream` (time or selector) via the compactor [L2]. **The docs list no size cap**, which is a docs-based negative, not a tested one. It could be capped **indirectly**, with a filesystem quota or a size-limited volume under Loki's data dir. That is extra ops work, and a full volume turns into ingest errors rather than orderly deletion (not tested). |
| Memory | `-memory.allowedBytes` / `-memory.allowedPercent` (default 60%) [V2]. These **size its internal caches and do not cap RSS**. The only real cap is the container `mem_limit`, and exceeding it means an OOM kill. | No official small-deployment sizing. The smallest documented tier totals 59 Gi across components [L3], and nothing official covers a VM of this size. The only cap is again `mem_limit`. |
| RAM claim | vendor claim: "up to 30x less RAM and up to 15x less disk space than … Elasticsearch and Grafana Loki" [V1] (**vendor claim, not independently verified**) | none official |
| UI / query language | built-in UI at `/select/vmui/` [V3], **LogsQL**, a second query language beside PromQL | Grafana (built-in core datasource, "you don't need to install a plugin" [L4]); **LogQL** (PromQL-like) |
| Grafana | plugin `victoriametrics-logs-datasource` [V4]. It must be installed, which is another download through the FortiGate (unverified). **Optional, because vmui exists.** | built-in; derived fields can link a `trace_id` to Tempo [L5] |
| Ingestion | **syslog listener** (`-syslog.listenAddr.tcp/udp`, RFC3164/5424) [V8], Loki push API ("Promtail (aka … Grafana Alloy)"), OTLP, Fluent Bit, Vector, own `vlagent` [V5] | Alloy (Promtail is **EOL as of 2026-03-02** [L6]) |
| Images | `docker.io/victoriametrics/victoria-logs`, and also on `quay.io` (quay API HTTP 200) | `docker.io/grafana/loki` only (no public quay repo, HTTP 401) |
| High-cardinality | "`ip`, `user_id` and `trace_id` **must never be associated with log streams**" [V6] | "Do not extract ephemeral values like a trace ID … into a label" [L7]; use structured metadata |

**Pick (judgement call): VictoriaLogs.** On this VM I weight the documented hard disk cap and the query
UI that needs no plugin download above Loki's Grafana-native integration. The cost is a second query
language, and it needs an ADR-0013 addendum. **Loki is a legitimate runner-up**, just heavier to operate
here: it needs an indirect disk cap, and it has no official small sizing. **Revisit** if traces are ever
adopted with Tempo, because Loki + Tempo in one Grafana has the stronger story.

### 1.3 Shipper: choose after testing (three candidates)

| Option | Extra container / RAM | Host access | Container name | Status |
|---|---|---|---|---|
| **(c) Docker `syslog` logging driver → VictoriaLogs syslog listener** | **none** | **none**: no socket, no `/var/lib/docker` mount | Docker's syslog `tag` "By default, Docker uses the first 12 characters of the container ID" [D3]. A name needs a custom `tag`, which lands in `app_name`, a VictoriaLogs stream field [V8]. **UNTESTED.** | 🔴 **UNTESTED.** Docker documents "dual logging" as on by default, so `docker logs` should still work via a local cache of "5 files of 20 MB each" per container [D4]. It also warns that on network issues "no `write` to the local cache occurs" [D4]. Not tested: whether containers still start while VictoriaLogs is down, and what happens to lines emitted during that time. It also means one image pull fewer. |
| (a) Grafana Alloy v1.20.1, `loki.source.docker` | +1 container, **128m estimate** (from the official "120 MiB" per "1 MiB/second of logs" [A3]) | 🔴 Docker socket, which is **root-equivalent even with `:ro`** [A1] | ✅ from the Docker API | documented; positions file survives restarts [A1] |
| (a′) Alloy, `loki.source.file` + `stage.docker` | +1 container, 128m est. | read-only `/var/lib/docker/containers` mount | ❌ not in the file; needs `json-file` `labels`/`tag` options | documented [A2] |
| (b) `vlagent` | +1 container, no official figure | file tail | unverified | can tail files [V7]; handling of Docker json-file is **unverified** |

**Recommendation:** test (c) first because it adds nothing to run. Fall back to Alloy (a′, then a) only if
(c) fails the `docker logs`, naming or startup tests. Alloy images are on `docker.io/grafana/alloy`
only [A4].

### 1.4 App-side changes (small)

- **No new logger library.** pino is already JSON with redaction (§0).
- Stream/label fields: `service` (compose service), `instance` (already in pino `base`). These are bounded
  values. **`tenant_id`, `correlationId`, `trace_id`, IPs → ordinary fields, never stream fields**
  [V6][L7]. This matches the reasoning behind `pos_idempotency_replay_total` having no tenant label.
- **PDPA:** everything stays self-hosted on `mob04`, and no SaaS log product sees the data. The existing
  rule "business modules log ids, not names or phones" (`logger.ts` header) is what makes central storage
  acceptable. Nginx's JSON access log carries client IPs, and retention bounds how long they are kept.
  Access stays SSH-tunnel-only, like Grafana.

---

## 2. Traces (recommendation: defer)

**What adoption would look like:** `@opentelemetry/sdk-node` 0.222.0 + `@opentelemetry/auto-instrumentations-node`
0.80.0 (both 2026-08-31, npm registry). The bundle includes http, express, pg, ioredis, pino and
nestjs-core instrumentations (checked in its `package.json` dependencies). BullMQ uses its own
`bullmq-otel` 2.0.1 add-on (peer `bullmq >=6`) [T1]. `@opentelemetry/instrumentation-pino` injects
`trace_id`, `span_id` and `trace_flags` into pino records ("log correlation") [T2]. Backend: Tempo v3.0.3
(2026-08-13), monolithic, "commonly used for … small-scale deployments" [T3], `block_retention` default
336h [T4], time only.

**Why defer:**

1. **The server is ESM** (`"type": "module"`, `module: nodenext`). ESM instrumentation needs
   `--experimental-loader=@opentelemetry/instrumentation/hook.mjs` plus `--import`, and OTel's own doc
   calls the loader experimental [T6]. That means a new `CMD`/`NODE_OPTIONS` in `server/Dockerfile`,
   which is shared by `api`, `worker`, `migrate` and `bull-board`.
2. **No official overhead figure.** Neither OpenTelemetry's zero-code JS page [T7] nor the package
   READMEs give a CPU or RAM number. The only performance note is that debug logging "can negatively
   impact application performance" [T7]. Any overhead number here would be a guess, and it would land
   **inside** the existing 384 MB cap of each of the three API containers (`server/docker-compose.yml`
   `x-api`) plus the 256 MB worker.
3. **Budget:** see §4. Tempo (with no official sizing, estimate 384m) plus SDK headroom pushes caps to
   about 5.0–5.3 GB of 6 GB. **FAIL.**
4. **Little to gain on one VM.** The request path is Nginx → one of `api-1..3` → Postgres/Redis on the same
   host. `correlationId` already joins Nginx and API lines, and the Prometheus histogram already gives
   p95.
5. **A version detail, not a blocker.** `auto-instrumentations-node` 0.80.0 pins
   `@opentelemetry/instrumentation-nestjs-core ^0.68.0`. The **published 0.68.0** hard-codes
   `supportedVersions = ['>=4.0.0 <12']` (`build/src/instrumentation.js` in the npm tarball) [T5]. The repo
   runs `@nestjs/core@12.0.1`, so today you would get http/express/pg/ioredis spans but **no Nest
   controller spans** (inferred from the range; not run). The `main`-branch README already says `>=4.0.0 <13`
   and documents Nest 12/ESM [T9], so this gap should close with the next release. Re-check then.

Other libraries are inside their supported ranges: Express 5 (`>=4 <6`), pg 8 (`>=8.0.3 <9`), ioredis 6
(`>=2 <7`), pino 10 (`>=5.14 <11`) [T5].

**Revisit when** a real latency problem cannot be explained by the p95 panel plus `correlationId` greps,
**or** after #380 has measured real RSS. Then pick **Tempo** (native Grafana datasource, and Loki
derived-field links [L5]). **Jaeger v2** (v2.21.0, 2026-09-14) is the runner-up. It is built on the
OTel Collector, has its own UI and Badger local storage [T8], but it would be a second UI to learn next to
Grafana.

---

## 3. Uptime and alerting (owner decision 2026-09-29: no second machine)

### 3.1 Why the direction has to be outbound

- A checker on `mob04` **cannot report `mob04` down**, whether the VM dies, Docker dies or the disk
  fills. It dies with the thing it watches.
- `mob04` has **no public address** (`07 §5`), so SaaS probes (UptimeRobot and the like) **cannot
  reach it at all**.
- The owner ruled out a second machine. What remains is to **reverse the direction**: `mob04` pushes a
  heartbeat *out*, and an outside service alerts when the heartbeats **stop**. Outbound NAT works
  (`07 §5`), subject to the FortiGate (§3.4).

### 3.2 Primary: Healthchecks.io heartbeat (dead-man's switch), 0 MB on the VM

**What Healthchecks.io offers (point-in-time, 2026-09-29):**
- **Free "Hobbyist" plan:** "Monitor 20 jobs", "100 log entries per job", no SMS/WhatsApp or phone
  credits [H1]. The pricing page states **no team-member limit** for any plan, so this is unverified.
  **Re-verify before relying on it.**
- **Ping URLs** [H2]:
  - UUID form: `https://hc-ping.com/<uuid>`, plus `/start`, `/fail`, `/log` and `/<exit-status>`
    (reports a script's exit code).
  - Slug form: `https://hc-ping.com/<ping-key>/<slug>`, with the same suffixes. A non-unique slug
    returns `409 Conflict`, and slug URLs can auto-create a check.
- **Period / grace:** "Period is the expected time between pings", and "Grace Time is the additional
  time to wait before sending an alert when a check is late" [H3]. The check goes down when no ping
  arrives within period + grace.
- **Integrations:** `email` and `telegram` are both in the integration list (`hc/integrations/` in the
  source [H4]; Telegram also appears on the home page). **There is no LINE integration.** The LINE Notify
  integration was removed ("Remove LINE Notify onboarding form (as LINE Notify is shutting down on Apr
  1, 2025)", CHANGELOG [H5]), and no LINE Messaging API integration exists in `hc/integrations/`. A
  generic `webhook` integration exists, but wiring it to LINE's push API is untested.
- **Self-hostable fallback:** it is open source under **BSD-3-Clause** ("licensed under the BSD 3-clause
  license" [H6]; GitHub reports `BSD-3-Clause`). The latest release is v4.4 (2026-08-31). A self-hosted
  copy would need a machine *off* `mob04`, which this decision rules out, so it is only a future option.

**What the check does on `mob04`** (the owner's design, with one correction):

```sh
# every 5 min; ping only if the API is really ready
curl -fsSk -m 10 https://127.0.0.1/health/ready \
  && curl -fsS -m 10 --retry 3 "$HC_PING_URL"
```

🔴 **Correction to the owner's draft command:** `http://127.0.0.1/health/ready` hits Nginx's
`listen 80` server, which is only `return 301 https://…` (`server/docker/nginx/nginx.conf:41-44`).
`curl -f` treats a 301 as success (it fails only on ≥400), so the heartbeat would keep pinging with the
API down. Use `https://127.0.0.1/health/ready` with `-k`, since the cert is self-signed (`certgen`). The
readiness check covers Postgres plus both Redis instances (`server/src/health/health.controller.ts`).
`/health/` is not rate-limited (`nginx.conf:76-79`). A failed readiness check can instead call
`"$HC_PING_URL/fail"`, which alerts at once instead of waiting out the grace time.

**What it covers:** the VM being dead or frozen, the NAT/network being down, Docker or Nginx being down,
the API not being ready, and Postgres/Redis being unreachable. It is one signal: it says *that* something
broke, not *what*. **What leaves the VM:** one HTTP request to a fixed URL, with no body and no customer
data. That is PDPA-clean.

**Where the timer lives:** `deploy.yml` runs as `deploy`, which has **no sudo**. `provision.yml` runs with
`become: true` (`deploy/ansible/provision.yml:11`) and already installs the backup cron for the `deploy`
user with `ansible.builtin.cron` (`provision.yml:231-238`). The heartbeat cron (`minute: "*/5"`)
therefore **belongs in `provision.yml`**, next to the backup job. A systemd timer would also be
provision-only. Cron is the simpler of the two and matches the existing pattern.

**Secret handling:** the ping URL (UUID, or ping-key + slug) is a secret, because anyone holding it can
fake "healthy".
- Put it in `DEMO_ENV_FILE` as `HC_PING_URL=…`. It then reaches `/opt/pos/.env` (mode 0600) through
  `provision.yml`, like every other secret (`07 §5`).
- The cron job reads it from `/opt/pos/.env` at run time, so the URL is **not** written into the
  crontab line.
- **Never commit it.** Make it optional in `provision.yml`'s key check: a missing key gives a
  `debug`/warning, the same way `PLATFORM_ADMINS` is handled, and does not fail provisioning.

### 3.3 Secondary: Grafana alerting for in-VM problems

- **Built in, no new container:** "Grafana includes a built-in Alertmanager to handle notifications"
  [G1]. It is the default for Grafana-managed alerts.
- **File provisioning is supported on the pinned version.** Files go in `provisioning/alerting`. Alert
  rules, contact points, notification policies, mute timings and templates can all be provisioned, and
  "Provisioning interpolates environment variables using the `$variable` syntax" [G2]. The v11.2 page
  exists and says the same [G3]; `deploy/compose/monitoring.yml` pins `grafana/grafana:11.2.0`.
  Grafana's general provisioning also accepts `$ENV_VAR` / `${ENV_VAR}` and escapes a literal `$` as
  `$$` [G4].
- **Fit:** add `deploy/grafana/provisioning/alerting/` next to the existing `datasources/` and
  `dashboards/` (today only those two exist). It is already mounted read-only through
  `${MONITORING_CONFIG_DIR:-../deploy}/grafana/provisioning:/etc/grafana/provisioning:ro`, so no compose
  mount change is needed.
- **Secrets follow the existing Grafana pattern.** `monitoring.yml` passes the admin password as
  `GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD:?…}` in `environment:` from `.env`. Do the same
  with `GRAFANA_TELEGRAM_BOT_TOKEN` and `GRAFANA_TELEGRAM_CHAT_ID`, and reference them in the contact
  point as `bottoken: $GRAFANA_TELEGRAM_BOT_TOKEN`. The Telegram example in [G2] uses `bottoken` and
  `chatid`. Use `:-` rather than `:?` so a missing token does not stop monitoring from starting.
  Record the keys in `07 §5`'s `DEMO_ENV_FILE` row, and never put them in the repo.

**Proposed rules.** They use the existing metric names only; never rename `http_requests_total` or
`http_request_duration_seconds` (CLAUDE.md "Metrics"). The labels are `method`, `route` and
`status_code` (`server/src/metrics/metrics.service.ts:9`).

| Alert | Expression (sketch) | Note |
|---|---|---|
| API instance down | `up{job="api-metrics"} == 0` for 2m | 🔴 **Never `job="api-readiness"`**: it reads 0 permanently because `/health/ready` returns JSON (`deploy/prometheus/prometheus.yml`). Postgres, Redis and the worker are **not scraped**, so `up` cannot see them; the heartbeat's readiness check covers Postgres and Redis. |
| node-exporter down | `up{job="node"} == 0` for 2m | |
| Disk > 85% | `(1 - node_filesystem_avail_bytes{mountpoint="/",fstype!="rootfs"} / node_filesystem_size_bytes{mountpoint="/",fstype!="rootfs"}) * 100 > 85` | same selector as the dashboard's disk panel |
| High 5xx rate | `sum(rate(http_requests_total{status_code=~"5.."}[5m])) / sum(rate(http_requests_total[5m])) > 0.05` | threshold is a placeholder; guard against division by zero on a quiet night |
| High p95 | `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le)) > 0.5` | 0.5 s is the `POST /sales` p95 target in `02_API_SCREENS.md` (k6 table); tune it |

**Contact point: Telegram. NEVER Grafana's "Line" contact point** (§3.6). Alert text carries metric
labels (`route`, `instance`), never customer data. There is no tenant label, by design.

**Limit:** Grafana runs *on* `mob04`, so it cannot report the VM dying. That is the heartbeat's job.
Grafana's alert delivery also needs `api.telegram.org` through the FortiGate (§3.4).

### 3.4 🔴 FortiGate gate (VM-gated; cannot be verified from a laptop)

Both channels depend on outbound HTTPS from `mob04` to `hc-ping.com` and `api.telegram.org`. The
FortiGate already breaks `ghcr.io` (`handoff_demo-335-…`), and whether it breaks these hosts is
**unknown**. Run this on `mob04` before building anything:

```sh
curl -v https://hc-ping.com
openssl s_client -connect hc-ping.com:443 -servername hc-ping.com </dev/null \
  | openssl x509 -noout -issuer -subject -ext subjectAltName
curl -v https://api.telegram.org
openssl s_client -connect api.telegram.org:443 -servername api.telegram.org </dev/null \
  | openssl x509 -noout -issuer -subject -ext subjectAltName
```

**How to read the output:**
- **Pass:** `curl -v` completes the TLS handshake with no certificate error, and the issuer is a public
  CA (not Fortinet) with a `subjectAltName` that names the host.
- **Blocked:** the issuer contains `O=Fortinet, OU=FortiGate`, **and no `subjectAltName` is printed**,
  while `curl` fails with a certificate or hostname error. This is exactly the `ghcr.io` failure
  (`CN=FG3K4ETB19900078`, no SAN). Trusting the Fortinet CA does not help, because hostname verification
  still fails.

**Fallback if blocked:**
1. Add `hc-ping.com` and `api.telegram.org` to the network-team exemption request that already lists
   `ghcr.io`, `registry-1.docker.io` and `gcr.io` for `172.30.58.20`.
2. Or use **university SMTP email as the only channel** for Grafana alerts (Grafana supports email
   [N3]). This does **not** rescue the heartbeat, which is inherently a ping to an outside host.

### 3.5 Demoted: only if a second campus machine appears later

| | **Uptime Kuma 2.5.5** (2026-09-16) | **Gatus v5.37.0** (2026-09-24) | **blackbox_exporter v0.28.0** (2025-12-06) |
|---|---|---|---|
| What | self-hosted monitor with UI, SQLite (MariaDB optional in v2) [U1][U2] | status page + checks from **one YAML file** (`config/config.yaml` by default), so it suits GitOps/PR review; Apache-2.0 [K1] | Prometheus exporter, `probe_success` [B1] |
| Config | UI-driven (state in SQLite) | file in the repo; env vars in config supported [K1] | file |
| Alerting | "90+ notification services" [U1]; LINE Messaging API (`line.js`) [U3] | Telegram, **LINE Messaging API** (`channel-access-token`, `user-ids`) and more [K1] | none; needs Alertmanager (ADR-0013) or Grafana |
| Storage | SQLite | `memory` (default, lost on restart), `sqlite`, `postgres` [K1] | none |
| Images | `docker.io/louislam/uptime-kuma:2` | `ghcr.io/twin/gatus`, `docker.io/twinproduction/gatus` [K1] | `docker.io/prom/blackbox-exporter`, `quay.io/prometheus/blackbox-exporter` |

If a second machine appears, **Gatus** fits this repo's "config in git, reviewed in a PR" habit better
than Uptime Kuma's UI state. It would probe `https://172.30.58.20/health/ready` with self-signed TLS
tolerated, and it would add *outside-in* checks alongside the heartbeat, not replace it.

### 3.6 Alert channels usable in Thailand

- **LINE Notify: dead.** Service ended **2025-03-31**. LINE points users to the Messaging API [N1].
- **Grafana's "Line" contact point still targets LINE Notify.** `grafana/alerting`
  `receivers/line/v1/line.go` has `APIURL = "https://notify-api.line.me/api/notify"` [N2]. Grafana lists
  "Line" as a contact point [N3], but it cannot work. **Never configure it.**
- **LINE Messaging API:** needs a LINE Official Account. Push messages count against the monthly quota
  [N4], and the **Thai free plan was 300 messages/month on 2026-09-29** [N5]; re-verify it.
  Healthchecks.io has no LINE integration (§3.2). Gatus and Uptime Kuma do, but they are demoted.
- **Telegram / email:** supported by Healthchecks.io [H4] and Grafana [N3]. **Telegram is the primary
  channel.** It has no quota and needs no Official Account. Email is the fallback.


## 4. Budget vs `mob04` (4 vCPU · 6 GB · 48 GB)

**Everything in this section is caps-based arithmetic, not a measurement.** Baseline from
`07_CICD_DEPLOY.md §5`: the POS stack's `mem_limit` sum is **3,424 MB**. That figure **excludes the
one-shots `migrate` (128m) and `etcd-init` (32m)**, which only run briefly during deploy and boot. Add
monitoring 832 MB (Prometheus 512 + Grafana 256 + node-exporter 64) for **4,256 MB**. The headroom of
about 1.8 GB (assuming 6 GB = 6,144 MiB; the VM's exact MiB was not checked) is not free. It is shared by:

- the host OS and dockerd;
- **Postgres's page cache**, which Postgres relies on for read performance and which lives outside its
  1024m container cap;
- the **planned self-hosted GitHub runner (#67)**, not installed yet, with no cap in any compose file;
- the one-shots above, while they run.

There is no official figure for any of these, so treat "what's left" below as an upper bound, not a
margin. **Log writes also add I/O and page-cache churn on the same disk as Postgres.** That is small at
this POS's request rate, but it is not zero and it has not been measured.

| Component | Where | mem_limit | Source of the RAM number | Disk retention cap | Source of disk number |
|---|---|---|---|---|---|
| Docker log rotation | mob04 | 0 | none (no process) | ≈0.55 GB (18 × 10m × 3) | estimate (count of services) |
| VictoriaLogs | mob04 | **256m** (the real cap; exceeding it = OOM kill) | **estimate**. `-memory.allowedBytes` only sizes caches [V2] | **3 GiB** `-retention.maxDiskSpaceUsageBytes` + `-retentionPeriod=14d` | cap flag is official [V2]; 3 GiB / 14d is my choice |
| Shipper, option (c) syslog driver | mob04 | **0** (no container) | none | Docker's dual-logging cache, 5 × 20 MB per container [D4] | official default |
| Shipper, option (a) Alloy | mob04 | **128m** | **estimate** derived from official 120 MiB per 1 MiB/s [A3] | positions file only (KB) | estimate |
| Healthchecks.io heartbeat (cron via `provision.yml`) | mob04 host cron | **0** (a `curl` every 5 min, no container) | none | 0 | none |
| Grafana alerting (rules + contact point) | inside existing Grafana | **0 new cap** (stays in Grafana's 256m; rule evaluation cost unmeasured) | none; no official figure | Grafana state volume (small) | estimate |
| Uptime Kuma / Gatus | **not deployed** (demoted, §3.5) | 0 | none | 0 | none |
| *Tempo (deferred)* | *mob04* | *~384m* | ***estimate, no official figure*** [T3] | *time only, 336h default* [T4] | official default |
| *OTel SDK × 3 API + worker (deferred)* | *inside existing caps* | *unknown; would need the 384m API caps raised* | ***no official figure*** [T7] | none | none |

| Scenario | RAM caps total | vs 6 GB | Disk added | Verdict |
|---|---|---|---|---|
| Today | 4,256 MB | 69% | none | baseline |
| **+ Step 0 only** | 4,256 MB | 69% | ≈0.55 GB (a *cap* on today's unbounded growth) | **PASS** |
| **+ VictoriaLogs, shipper = syslog driver (c)** | **≈4,512 MB** | **≈73%**, *at most* ~1.6 GB for OS, dockerd, page cache and the runner | ≈3.5 GB | **PASS on paper, conditional on #380** |
| + VictoriaLogs, shipper = Alloy (a) | ≈4,640 MB | ≈76%, *at most* ~1.5 GB, same list | ≈3.5 GB | **PASS on paper, conditional on #380** |
| + heartbeat + Grafana alerting | +0 MB | unchanged | none | **PASS**. Delivery is **VM-gated** on §3.4. |
| + Uptime Kuma *on* mob04 instead (rejected) | +128–256m (estimate) | +2–4% | <0.1 GB | Fits on RAM but **fails the purpose**: it cannot report its own VM down |
| + traces (Tempo + SDK headroom) | ≈5,000–5,300 MB | 81–86% | ≈1–2 GB (time-only retention) | **FAIL, so defer** |

**Retention, 14 days vs 3 GiB:** log volume in MB/day has **never been estimated or measured**, so it is
unknown which limit bites first. Measure `docker compose logs --since 24h | wc -c` on `mob04` after
step 0 before choosing either number.

**Disk:** 48 GB total. The only free-space figure in the repo is "42 GB free on this VM", which comes
from **a comment in `deploy/ansible/provision.yml`, not a measurement**, and it predates the stack
running for long. Already reserved: Prometheus ≤2 GB, plus 7 days of local `pg_dump` backups
(`BACKUP_KEEP_DAYS=7`), which **stay on the VM** because #363 is parked, plus pgdata and images
(unmeasured). Adding about 3.5 GB of *bounded* data is **PASS**. Step 0 is itself a disk *fix*, since the
current log growth is unbounded. **Measure `df -h /` and `docker system df` on `mob04` first.**

**CPU:** no official per-component CPU figures were used. Not assessed beyond "light, single binaries".

---

## 5. Minimal rollout order (ticket-sized; **no issues were created**)

1. **`ops.logrotate`, deliverable today**: add an `x-logging` anchor (`json-file`, `max-size: 10m`,
   `max-file: 3`) to every service in `server/docker-compose.yml` + `deploy/compose/monitoring.yml`.
   Extend `deploy/scripts/validate.sh`'s `docker compose config` check to assert that each service has
   `logging`. It is config only: 0 MB RAM, no image pull, not blocked by the FortiGate. It closes an
   unbounded-disk risk. **Do this even if nothing else is built.** Then measure log MB/day.
2. **`ops.egress-check`, VM-gated, no code**: run the §3.4 commands on `mob04` for `hc-ping.com` and
   `api.telegram.org`, and record the result in a handoff log.
   - **Pass:** steps 3 and 4 can ship **before** any registry exemption, because neither needs a new
     image.
   - **Blocked:** add both hosts to the network-team exemption request. Meanwhile, Grafana can alert over
     university SMTP email, and the heartbeat waits.
3. **`ops.heartbeat`**: create a Healthchecks.io check (period 5 min; grace e.g. 10 min, to be tuned).
   Add optional `HC_PING_URL` to `DEMO_ENV_FILE` (warn when it is missing, don't fail), and add an
   `ansible.builtin.cron` task (`minute: "*/5"`, user `deploy`) to **`provision.yml`**. It cannot go
   in `deploy.yml`, because `deploy` has no sudo. The job runs
   `curl -fsSk https://127.0.0.1/health/ready && curl -fsS -m 10 --retry 3 "$HC_PING_URL"`, with the URL
   read from `/opt/pos/.env`, never from the crontab. Add a Telegram + email integration on the
   Healthchecks side. Add a runbook row in `07 §7`.
4. **`ops.grafana-alerts`** (needs the owner's OK against ADR-0013, §6): add
   `deploy/grafana/provisioning/alerting/` with the §3.3 rules, a Telegram contact point
   (`$GRAFANA_TELEGRAM_BOT_TOKEN` / `$GRAFANA_TELEGRAM_CHAT_ID`, passed through `monitoring.yml`
   `environment:` like `GRAFANA_ADMIN_PASSWORD`) and a notification policy. **Never the "Line"
   contact point.** Record the new keys in `07 §5`'s `DEMO_ENV_FILE` row.
5. **`ops.logs`, CONDITIONAL**: only if step 1 plus `docker compose logs | grep <correlationId>` proves
   insufficient (logs lost across a deploy, or multi-day search needed in a real incident). It also
   needs an **ADR-0013 addendum**, and it is 🔴 **blocked on the `registry-1.docker.io` FortiGate
   exemption**, plus `quay.io` if that mirror is used (`quay.io` is not in `07`'s exemption request).
   When unblocked:
   - Add `victoria-logs` to `deploy/compose/monitoring.yml` with `mem_limit`, a digest-pinned image (#401
     rule), `-retention.maxDiskSpaceUsageBytes` and `-retentionPeriod`, and a loopback-only UI at
     `127.0.0.1:9428`.
   - **Add `9428` to `07 §5`'s list of loopback-only ports and to the `07 §7` SSH-tunnel runbook row**
     (`ssh -L 9428:127.0.0.1:9428 deploy@<vm>`).
   - Test shipper (c) first (`docker logs`, container naming, startup with VictoriaLogs down). Only if
     it fails, add Alloy.
   - Use a **named volume** for the data dir. `deploy.yml` runs as the `deploy` user (group `docker`,
     **no sudo**), so the playbook cannot create or chown a host bind-mount path. A Docker-managed named
     volume, like `prometheus-data`, avoids that.
   - Wire it into `deploy/ansible/deploy.yml`'s monitoring block the same way Prometheus/Grafana are
     (#121). Note that this block has never run a real pull on `mob04`.
6. *(optional)* **`ops.backup-heartbeat`**: a second Healthchecks.io check (period 1 day). `backup-db.sh`
   pings `/<exit-status>` [H2], which closes the "nothing pages on a failed backup" gap (#346). This uses
   2 of the 20 free checks.
7. *(deferred)* **traces**: only after #380 measures RSS. Re-run this budget table and re-check the
   published `instrumentation-nestjs-core` range first.

---

## 6. Open questions for the owner

1. **Do we need a central log store at all?** Or is step 0 (rotation plus `docker compose logs | grep
   <correlationId>`) enough until a real incident proves otherwise?
2. **Grafana alerting vs ADR-0013.** ADR-0013's Monitoring row says "**ไม่มี Alertmanager**"
   (`adr/0013-cicd-toolchain.md:31`), and `07 §1` and `§10` repeat it. Nothing in ADR-0013, `07`,
   `03` or `04` mentions Grafana (unified) alerting either way (grep, 2026-09-29). Grafana's built-in
   Alertmanager adds no container. **Is that inside the spirit of "no Alertmanager"** (which was about a
   separate service and RAM), or does it need an ADR-0013 addendum?
3. Alert channel: Telegram (primary) plus email. Is that acceptable, given that Healthchecks.io has no
   LINE integration? LINE would need a webhook to the Messaging API (untested), or Gatus/Kuma on a second
   machine.
3a. Is sending an outbound heartbeat to a **US SaaS** (Healthchecks.io) acceptable? It carries no
   customer data, only a ping to a fixed URL. The self-hosted BSD-3 alternative needs a machine off
   `mob04`.
4. If a central store is built: is the **Docker `syslog` driver** acceptable as the shipper (no extra
   container, no host access, but untested for `docker logs`, naming and startup)? And if it fails the
   tests, may Alloy mount the **Docker socket** (root-equivalent), or must it tail files read-only?
5. Log retention: 14 days / 3 GiB OK? (PDPA: Nginx logs carry client IPs.) Log MB/day is still unknown.
6. **VictoriaLogs vs Loki is a judgement call:** a hard disk cap and built-in UI, versus Grafana-native and
   one fewer query language. Is that acceptable as an ADR-0013 addendum?
7. If §3.4 shows `hc-ping.com` / `api.telegram.org` blocked, should they join the exemption request? Or
   is email-only acceptable?
7a. Should the `quay.io` exemption be requested alongside the three registries already listed, as a
   mirror for VictoriaLogs and blackbox?
8. **Confirm traces stay out** until #380 has numbers.

---

## Sources (all accessed 2026-09-29; versions, dates and quotas are point-in-time)

Repo files cited inline: `server/src/common/logger.ts`, `server/docker/nginx/nginx.conf`,
`server/docker-compose.yml`, `server/package.json`, `server/pnpm-lock.yaml`, `server/Dockerfile`,
`server/src/health/health.controller.ts`, `deploy/compose/monitoring.yml`,
`deploy/prometheus/prometheus.yml`, `deploy/ansible/provision.yml`, `deploy/scripts/backup-db.sh`,
`docs/Backend_design/07_CICD_DEPLOY.md`, `docs/Backend_design/adr/0013-cicd-toolchain.md`,
`docs/Backend_design/04_QA_SCRUTINY.md`, `docs/study/18_capstone.md`,
`docs/handoff_log/handoff_demo-335-merge-and-cd-blocked_21_09_2026.md`.

Versions/dates: GitHub `releases/latest` API for grafana/loki, grafana/alloy, grafana/tempo,
VictoriaMetrics/VictoriaLogs, jaegertracing/jaeger, louislam/uptime-kuma, prometheus/blackbox_exporter.
npm registry (`registry.npmjs.org/<pkg>/latest`, plus the tarball for `instrumentation-nestjs-core`
0.68.0) for the OTel, `bullmq-otel` and `nestjs-pino` packages. Registry presence came from the Docker
Hub and quay.io repository APIs.

- [D1] Docker json-file driver: https://docs.docker.com/engine/logging/drivers/json-file/
- [D2] Docker configure logging drivers: https://docs.docker.com/engine/logging/configure/
- [D3] Docker syslog driver: https://docs.docker.com/engine/logging/drivers/syslog/
- [D4] Docker dual logging: https://docs.docker.com/engine/logging/dual-logging/
- [V1] VictoriaLogs overview: https://docs.victoriametrics.com/victorialogs/
- [V2] VictoriaLogs retention / memory flags: https://docs.victoriametrics.com/victorialogs/#retention-by-disk-space-usage
- [V3] VictoriaLogs querying / vmui: https://docs.victoriametrics.com/victorialogs/querying/
- [V4] VictoriaLogs Grafana datasource: https://docs.victoriametrics.com/victorialogs/integrations/grafana/
- [V5] VictoriaLogs data ingestion: https://docs.victoriametrics.com/victorialogs/data-ingestion/
- [V6] VictoriaLogs key concepts (stream fields): https://docs.victoriametrics.com/victorialogs/keyconcepts/
- [V7] vlagent: https://docs.victoriametrics.com/victorialogs/vlagent/
- [V8] VictoriaLogs syslog ingestion: https://docs.victoriametrics.com/victorialogs/data-ingestion/syslog/
- [L1] Loki deployment modes: https://grafana.com/docs/loki/latest/get-started/deployment-modes/
- [L2] Loki retention: https://grafana.com/docs/loki/latest/operations/storage/retention/
- [L3] Loki sizing: https://grafana.com/docs/loki/latest/setup/size/
- [L4] Grafana Loki data source: https://grafana.com/docs/grafana/latest/datasources/loki/
- [L5] Grafana Loki data source configure (derived fields): https://grafana.com/docs/grafana/latest/datasources/loki/configure/
- [L6] Promtail EOL: https://grafana.com/docs/loki/latest/send-data/promtail/
- [L7] Loki label best practices: https://grafana.com/docs/loki/latest/get-started/labels/bp-labels/
- [A1] Alloy `loki.source.docker`: https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.docker/
- [A2] Alloy `loki.process` (`stage.docker`): https://grafana.com/docs/alloy/latest/reference/components/loki/loki.process/
- [A3] Alloy resource usage: https://grafana.com/docs/alloy/latest/introduction/estimate-resource-usage/
- [A4] Alloy on Docker: https://grafana.com/docs/alloy/latest/set-up/install/docker/
- [T1] BullMQ telemetry: https://docs.bullmq.io/guide/telemetry · `bullmq-otel`: https://www.npmjs.com/package/bullmq-otel
- [T2] `@opentelemetry/instrumentation-pino` README: https://www.npmjs.com/package/@opentelemetry/instrumentation-pino
- [T3] Tempo deployment: https://grafana.com/docs/tempo/latest/setup/deployment/
- [T4] Tempo configuration (`block_retention`): https://grafana.com/docs/tempo/latest/configuration/
- [T5] Published READMEs/code (via registry.npmjs.org; npmjs.com returned 403 to the fetcher):
  https://www.npmjs.com/package/@opentelemetry/instrumentation-nestjs-core (0.68.0 tarball `build/src/instrumentation.js`),
  https://www.npmjs.com/package/@opentelemetry/instrumentation-express , https://www.npmjs.com/package/@opentelemetry/instrumentation-pg ,
  https://www.npmjs.com/package/@opentelemetry/instrumentation-ioredis
- [T6] OTel JS ESM support: https://github.com/open-telemetry/opentelemetry-js/blob/main/doc/esm-support.md
- [T7] OTel JS zero-code: https://opentelemetry.io/docs/zero-code/js/
- [T8] Jaeger docs: https://www.jaegertracing.io/docs/latest/
- [T9] `instrumentation-nestjs-core` README on `main` (unreleased): https://github.com/open-telemetry/opentelemetry-js-contrib/blob/main/packages/instrumentation-nestjs-core/README.md
- [H1] Healthchecks.io pricing: https://healthchecks.io/pricing/
- [H2] Healthchecks.io Pinging API (UUID and slug URLs, /start, /fail, /log, /<exit-status>): https://healthchecks.io/docs/http_api/
- [H3] Healthchecks.io configuring checks (period, grace): https://healthchecks.io/docs/configuring_checks/
- [H4] Healthchecks integrations in source: https://github.com/healthchecks/healthchecks/tree/master/hc/integrations · home page: https://healthchecks.io/
- [H5] Healthchecks CHANGELOG (LINE Notify removal): https://github.com/healthchecks/healthchecks/blob/master/CHANGELOG.md
- [H6] Healthchecks self-hosting / licence: https://healthchecks.io/docs/self_hosted/ · https://github.com/healthchecks/healthchecks (BSD-3-Clause; v4.4, 2026-08-31)
- [G1] Grafana Alertmanager: https://grafana.com/docs/grafana/latest/alerting/fundamentals/notifications/alertmanager/
- [G2] Grafana file provisioning of alerting: https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/file-provisioning/
- [G3] Same page for v11.2: https://grafana.com/docs/grafana/v11.2/alerting/set-up/provision-alerting-resources/file-provisioning/
- [G4] Grafana provisioning (env vars): https://grafana.com/docs/grafana/latest/administration/provisioning/
- [K1] Gatus README (v5.37.0, 2026-09-24; Apache-2.0): https://github.com/TwiN/gatus
- [U1] Uptime Kuma README: https://github.com/louislam/uptime-kuma
- [U2] Uptime Kuma install wiki: https://github.com/louislam/uptime-kuma/wiki/%F0%9F%94%A7-How-to-Install
- [U3] Uptime Kuma source at tag 2.5.5: https://github.com/louislam/uptime-kuma/blob/2.5.5/server/notification-providers/line.js ,
  https://github.com/louislam/uptime-kuma/blob/2.5.5/server/routers/api-router.js
- [B1] blackbox_exporter README: https://github.com/prometheus/blackbox_exporter
- [N1] LINE Notify closing announcement: https://notify-bot.line.me/closing-announce
- [N2] Grafana alerting LINE receiver: https://github.com/grafana/alerting/blob/main/receivers/line/v1/line.go
- [N3] Grafana contact points: https://grafana.com/docs/grafana/latest/alerting/configure-notifications/manage-contact-points/
- [N4] LINE Messaging API pricing: https://developers.line.biz/en/docs/messaging-api/pricing/
- [N5] LINE OA Thailand plans: https://lineforbusiness.com/th/service/line-oa-features/broadcast-message

**Could not verify:**
- official RAM figures for Loki (small scale), Tempo, Uptime Kuma or the OTel Node SDK;
- Healthchecks.io's team-member limit (not on the pricing page);
- reachability of `hc-ping.com` / `api.telegram.org` from `mob04` (VM-gated, §3.4);
- whether the FortiGate inspects Docker Hub, quay.io or the alert APIs;
- the syslog-driver path end to end (`docker logs`, naming, startup while VictoriaLogs is down);
- `vlagent`'s handling of Docker json-file;
- Loki behaviour under an indirect disk cap;
- `mob04`'s real free disk, RSS (#380) and log MB/day.
