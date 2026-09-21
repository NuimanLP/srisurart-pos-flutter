# Ticket #184 `close.3` — the executable runbook for the two ACs that are left (RSS under load, k6 p95)

**Date:** 2026-09-21 · **Written by:** lane A (`NuimanLP`) at the owner's request, **for lane C
(`PattaraponKitcharoen`, `team/3`) to execute** · **Nothing here ticks an AC and nothing here was
run.** This is a procedure, not evidence.

> **Why this document exists.** PR **#357** was merged with `Closes #184` but shipped **tooling and
> a runbook only** — 4 files, +409/−0, no deploy, no RSS table, no k6 result. The issue was
> reopened and all four ACs are still `[ ]`. The owner asked for a runbook detailed enough that an
> agent-assisted operator can execute it **without re-deriving anything**, and for the ticket's own
> text to say what is true. This is the first half; the second is a comment on #184.
>
> 🔴 **Read §1 before §4.** Two of the four ACs are not #184's work at all, and the other two
> cannot produce a number that closes `03_ARCHITECTURE.md §8`'s k6 box until the owner answers
> **#251**. Sending someone to measure without knowing that is how a checkbox ends up lying.

---

## 1. What is already done, what is left, and who owns it

| #184 AC (verbatim) | Owner | State today | Where the work actually is |
|---|---|---|---|
| 1. `/health/ready` เขียวบน `mob04` · `.current_sha` ตรงกับ commit ที่ deploy | owner / lane C | ⬜ not started | **#343**, runbook already written: [`ticket-343-vm-deploy.md`](ticket-343-vm-deploy.md) §7 — do **not** re-derive it here |
| 2. rollback แล้วกลับสภาพเดิมได้ | owner / lane C | ⬜ not started | **#343** §8 (the rollback drill) |
| 3. ตาราง RSS ต่อ container **ขณะมีโหลด** + สรุปว่าพอ/ไม่พอใน 6 GB | lane C | ⬜ tool exists, never run | **§4–§6 of this document** |
| 4. ผล k6 p95 ต่อเครื่อง เทียบเกณฑ์ `02 §9` | lane C | ⬜ tool exists, never run | **§4–§6 of this document** · scope limited by **#251**, see §3 |

**What PR #357 really delivered** (`gh pr diff 357 --name-only`, 4 files, +409/−0):

| File | What it is | Runnable as shipped? |
|---|---|---|
| `deploy/scripts/measure-container-rss.sh` | the sampler: `docker stats` every 2 s, keeps per-container peaks, writes a Markdown report | Yes — but only **after** `provision.yml` puts it on the VM (fixed at #346/#361; it was invoked from a non-existent path when #357 merged) |
| `server/test/k6/run-shard-test.sh` | wrapper that runs all 4 k6 scenarios back-to-back for one shard | Yes, with caveats — see §5.3, it is **not** the right tool for the submission run |
| `docs/handoff_log/slice-22-k6-rss-measurement-guide.md` | the first runbook | Partly — its `pnpm k6:setup` step **cannot work from a laptop**, see §4.4 |
| `docs/handoff_log/INDEX.md` | index line | n/a |

Everything else #184 needs already existed before #357: `server/test/k6/lib/shard.js`,
`server/test/k6/README.md`, the five k6 Grafana panels and the nginx remote-write location all
landed with **#251** (2026-09-15). This document does not restate `server/test/k6/README.md` — read
it once for the per-shard maths, then follow the steps here, which is the same procedure pinned to
`mob04` with the prerequisites and the failure branches filled in.

---

## 2. Hard prerequisites — with the command that proves each one

Do not start until every row says PASS. Each command is read-only. Run them from the repo root in
Git Bash on the controller machine unless the row says otherwise.

| # | Must be true | Proof command | PASS looks like |
|---|---|---|---|
| P1 | VPN up, `mob04` reachable | `ssh -i ~/.ssh/deploy_ed25519 -o IdentitiesOnly=yes deploy@172.30.58.20 'echo ok'` | `ok` |
| P2 | The stack on the VM is the SHA you intend to measure | `ssh … deploy@172.30.58.20 'cat /opt/pos/.current_sha; docker ps --format "{{.Names}}\|{{.Image}}\|{{.Status}}"'` | `.current_sha` = the 40-hex tag you deployed, every `api-*` image carries it, no container younger than the deploy |
| P3 | `/health/ready` is green | `ssh … deploy@172.30.58.20 'curl -sk -o /dev/null -w "%{http_code}\n" https://127.0.0.1/health/ready'` | `200` |
| P4 | The monitoring overlay is up (k6 has nowhere to push otherwise) | `ssh … deploy@172.30.58.20 'curl -s -o /dev/null -w "prom=%{http_code}\n" http://127.0.0.1:9090/-/healthy; curl -s -o /dev/null -w "graf=%{http_code}\n" http://127.0.0.1:3000/api/health'` | `prom=200` and `graf=200` |
| P5 | Grafana actually draws | `ssh -i ~/.ssh/deploy_ed25519 -o IdentitiesOnly=yes -L 3000:127.0.0.1:3000 deploy@172.30.58.20` then open `http://localhost:3000` → *Srisurart POS — overview* | the five `k6:` panels exist (they will read *No data* until the run — that is correct) |
| P6 | The sampler is **on the VM** | `ssh … deploy@172.30.58.20 'ls -l /opt/pos/scripts/measure-container-rss.sh'` | a `-rwxr-xr-x … deploy deploy` file |
| P7 | `/opt/pos/.env` carries the two remote-write keys | `ssh … deploy@172.30.58.20 'sudo grep -c "^K6_REMOTE_WRITE_BASIC_AUTH_" /opt/pos/.env'` (as `cloud`; `deploy` has no sudo) | `2` — 🔴 anchor the `^`, an unanchored `grep -c` has already produced a false pass in this repo. **Expect this to fail until `provision.yml` is re-run**: `ticket-343-vm-deploy.md` §5 records `/opt/pos/.env` as written 2026-09-15, before #251 added those two keys |
| P8 | Each laptop's source IP is inside nginx's remote-write allowlist | from **each** laptop: `curl -sk -o /dev/null -w "%{http_code}\n" -X POST https://172.30.58.20/prometheus-remote-write/api/v1/write` | **`401`** = IP allowed, credentials missing (expected, good). **`403`** = that laptop is outside the allowlist → **STOP**, see §7 F1 |
| P9 | k6 installed on all three laptops | `k6 version` on each | any version prints |
| P10 | Clocks synced on all three laptops | `date -u` on each, compare against a phone | within a couple of seconds — the controller machine was found ~70 s behind real time during the #184 session (close3 finding 7), so this is not hypothetical |

**The SHA you measure has to be a SHA whose images exist.** Two rows of
[`demo-rehearsal-dev-2026-09-21.md`](demo-rehearsal-dev-2026-09-21.md) §10 apply before P2 can be
true at all: the VM never builds, so *"ต้องรอ CI ของ commit นั้น build+push image เสร็จก่อน (D8) · เช็คด้วย
`deploy/scripts/verify-ghcr-tags.sh <sha>`"*, and the deploy *"ต้องส่ง `image_tag=<40-hex>` เสมอ"* —
with `-e force_redeploy=true` when the target equals `.current_sha`, or the play exits early and
silently. Prove it before asking anyone to deploy:

```bash
bash deploy/scripts/verify-ghcr-tags.sh <40-hex SHA>
```

**P2/P3 are #343's output, not something to do here.** If `.current_sha` is still `8e873cd`
(2026-09-15, 188 commits behind `main` as of 2026-09-21), the deploy has never happened: run
[`ticket-343-vm-deploy.md`](ticket-343-vm-deploy.md) §7 first, and know that it is currently blocked
— **the faculty FortiGate does SSL deep inspection and breaks the `ghcr.io` pull**
([`handoff_demo-335-merge-and-cd-blocked_21_09_2026.md`](handoff_demo-335-merge-and-cd-blocked_21_09_2026.md)).
Until the network team exempts `ghcr.io`, ACs 1 and 2 cannot be done and ACs 3 and 4 have nothing
current to measure.

---

## 3. #251 — read this before you believe any number you are about to produce

**Decided (owner, 2026-09-15):** *how* to measure — three laptops, `SHARD=i/3`, each individually
under nginx's own `limit_req zone=perip rate=30r/s burst=60`, **no `perip` exemption**, metrics
remote-written into the VM's Prometheus, read back per machine in Grafana.

**Still owed by the owner (#251 is `OPEN`, all four of its ACs unticked):** whether the resulting
numbers are accepted as satisfying `03_ARCHITECTURE.md §8`'s box *"k6 ผ่านเกณฑ์ใน `02_API_SCREENS.md §9`"*,
or whether that box gets formally re-scoped.

Why that question survives the method decision — the arithmetic, already recorded in `03 §8.1`:

* `02 §9`'s table has a **load** column: 1,000 VUs read-heavy, 200 VUs contention, 100 VUs replay,
  500 VUs mixed.
* The clean path caps each machine at `SAFE_RATE_PER_SHARD` = **24 r/s** (80 % of nginx's 30 r/s per
  IP, `server/test/k6/lib/shard.js`). Three machines = **~72 r/s aggregate**. `01-read-products.js`
  and `04-mixed-workload.js` therefore switch from `ramping-vus` to `ramping-arrival-rate` when
  `SHARD` is set and **do not run a VU count at all**.
* So this run is honest evidence about **tail latency, error rate and cache hit at 24 r/s per real
  source IP through the real edge proxy**. It is **not** evidence that the stack serves 1,000
  concurrent users. `03 §8.1` already says so in writing.

**What this runbook does in the meantime:** produce and record the per-machine numbers, state their
scope in exactly those words, and **leave `03 §8`'s k6 box unticked**. #184 AC 4's own wording is *"ผล k6 p95 ต่อเครื่อง
เทียบเกณฑ์ `02 §9`"* — a per-machine p95 compared against the thresholds — and this run delivers
that, **except** for §9's `replication lag < 1s`, which nothing in this stack can measure (§6.2).
So: fill §6.2 completely, including that row's N/A and its reason, and let the owner decide whether
AC 4 counts as satisfied with an N/A in it. **Do not** tick the `03 §8` DoD box either way — that is
a broader claim and is #251's to release. Say all of this in the evidence comment.

---

## 4. Setup, in order

### 4.1 Roles

| Role | Who | Does |
|---|---|---|
| **VM operator** | whoever holds the `deploy`/`cloud` keys and the VPN | §2, §4.2, §5.1 (starts the sampler), §6.1 |
| **Shard 1 / coordinator** | one laptop | §4.3, §4.4 (seeding), announces the barrier, runs `k6:verify` |
| **Shard 2, Shard 3** | two laptops | §4.3, then fire on the barrier |

### 4.2 Decide the window and freeze the SHA

Write down, before anything starts: the 40-hex SHA under test (= `.current_sha` from P2), the
`TESTID`, and the wall-clock start. Everything recorded later is worthless without the SHA.

```bash
TESTID="$(date -u +%Y%m%dT%H%M%SZ)"   # ONE value, agreed by all three laptops
```

### 4.3 Every laptop

```bash
# 1. clock (P10)
date -u                    # Windows: w32tm /resync ;  macOS/Linux: sudo sntp -sS time.nist.gov
# 2. k6 present (P9)
k6 version
# 3. the remote-write target — the password comes from the owner, out of band, never git
export K6_PROMETHEUS_RW_SERVER_URL="https://k6:<PASSWORD>@172.30.58.20/prometheus-remote-write/api/v1/write"
export K6_PROMETHEUS_RW_TREND_STATS="p(95),p(99)"
```

🔴 The URL path must be **exactly** `/prometheus-remote-write/api/v1/write`. nginx's location is an
`location =` exact match on purpose (`server/docker/nginx/nginx.conf:113`) — any other path under
that prefix is refused, by design, so that the shared credential cannot reach Prometheus's query
API.

### 4.4 Seed the `loadtest` tenant — 🔴 the one step the #357 runbook gets wrong

`slice-22 …-guide.md` §3.1 and `server/test/k6/README.md` step 2 both say
`BASE_URL=https://<vm> pnpm k6:setup`. **That cannot work from a laptop against `mob04`.** Traced in
`server/test/k6/setup.ts`:

* line 21-22 — it opens a **direct Postgres connection** (`DATABASE_ADMIN_URL` → `DATABASE_URL`,
  default `127.0.0.1`), because it wipes and re-seeds the tenant with SQL (`plan='loadtest'`,
  ADR-0006), not through the API;
* line 26 — it wants a **`redis-cache` URL**;
* line 33 / 190-222 — it signs the POS and back-office access tokens itself with
  **`JWT_PRIVATE_KEY`** (RS256, `expiresIn: '24h'`).
* `server/test/k6/verify-integrity.ts:10-11` needs the same Postgres URL.

The VM publishes **no** datastore port (`server/docker-compose.yml` has no `ports:` on Postgres or
Redis, and `docker-compose.dev.yml` is forbidden on the VM — `03 §8`). The only path that has ever
worked is the one recorded in
[`close3-demo-deploy-2026-09-15.md`](close3-demo-deploy-2026-09-15.md) §2 "How it was run: a Linux
container on the coordinator laptop holding **SSH tunnels to the compose addresses**, with a native
`pnpm install` of `server/` (argon2 is a native module, so a Windows install will not do).

🔴 **Do not copy the IPs from that document.** `172.30.0.128/25` is the network's *dynamic*
`ip_range` (`server/docker-compose.yml:355`); only `api-1..3` have static addresses (`.11/.12/.13`).
Postgres and `redis-cache` get a fresh address on every recreate. Read them at tunnel time:

```bash
ssh -i ~/.ssh/deploy_ed25519 -o IdentitiesOnly=yes deploy@172.30.58.20 \
  'docker inspect -f "{{.Name}} {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" \
     $(docker ps -q --filter name=postgres --filter name=redis-cache)'
```

Then, on the coordinator laptop, with `$PG_IP` / `$REDIS_IP` from that output:

```bash
ssh -i ~/.ssh/deploy_ed25519 -o IdentitiesOnly=yes -N \
    -L 5432:$PG_IP:5432 -L 6379:$REDIS_IP:6379 deploy@172.30.58.20 &
```

and run the seeding with the VM's own credentials (read from the owner's `demo.env`; **never echo
them**), while `BASE_URL` still points at nginx, because that value is what gets baked into
`k6-env.json` as the URL every scenario will hit:

```bash
cd server
DATABASE_ADMIN_URL='postgres://<user>:<pw>@127.0.0.1:5432/pos' \
REDIS_CACHE_URL='redis://:<pw>@127.0.0.1:6379' \
JWT_PRIVATE_KEY="$(cat /path/to/jwt_private.pem)" \
BASE_URL=https://172.30.58.20 \
pnpm k6:setup
```

PASS = it prints `✅ k6 environment written to: …/server/test/k6/k6-env.json` and
`Seeded 51 products (including contention target p12 with 50 units).`

**Unverified in this document:** the exact `.env` key names for the Postgres and Redis passwords on
the VM were not read (this session had no VPN and does not hold `demo.env`). Take them from
`server/.env.example` plus the owner's `DEMO_ENV_FILE`. If `pnpm k6:setup` from a laptop proves
impossible for a reason not listed above, running it inside a container **on the VM** is the
fallback — the seeding is not the measurement, so it does not contaminate anything; only `k6 run`
must never execute on the VM (`03 §8`).

### 4.5 Share `k6-env.json`

Copy `server/test/k6/k6-env.json` to the same path on laptops 2 and 3 (Slack/AirDrop/USB — **not
git**; it is gitignored and carries live 24-hour tokens). Delete every copy when the run is over.

All three laptops share one POS device token, so this is three IPs, one device — fine for §9, and
not a multi-device test. Do not describe it as one.

---

## 5. The run

### 5.1 Start the sampler on the VM **first** — it only sees peaks after it starts

```bash
ssh -i ~/.ssh/deploy_ed25519 -o IdentitiesOnly=yes cloud@172.30.58.20
sudo /opt/pos/scripts/measure-container-rss.sh 1800 /opt/pos/rss-under-load-<TESTID>.md
```

* `1800` is deliberate. The default in the script is **600 s**, which is shorter than the run: the
  four sharded scenarios are ~35 s + a one-shot + a one-shot + `5s + DURATION + 5s`, and the
  rubric-length mixed run is `DURATION=10m`. A 600 s sampler stops mid-mixed and its "peak" misses
  the heaviest phase. Size it to your plan and leave margin; `Ctrl+C` ends it early and still writes
  the report.
* `sudo` is required and not incidental: `cloud` is not in the `docker` group and the sampler shells
  out to `docker stats` / `docker inspect`. (`deploy` *is* in `docker` but has no sudo at all — pick
  one user and stay with it.)
* 🔴 **Record the restart counters before the run too.** The script reads `RestartCount` only at the
  end, and that counter is cumulative since the container was created — a restart from last week
  would otherwise read as a restart caused by your load:

```bash
docker ps --format '{{.Names}}' | while read n; do \
  echo "$n $(docker inspect -f '{{.RestartCount}} {{.State.OOMKilled}} {{.State.StartedAt}}' "$n")"; done
```

Keep that output. §6.1 diffs against it.

🔴 **Any `docker compose` you type in `/opt/pos` must carry the whole `-f` set** —
`-f docker-compose.yml -f vm.override.yml -f monitoring.yml`, with `IMAGE_TAG=$(cat .current_sha)`.
A partial set is a different project definition: on the dev rehearsal a bare `docker compose run`
**recreated Postgres** and took its published port with it
(`demo-rehearsal-dev-2026-09-21.md` §9.2). Nothing in this runbook needs `compose` at all —
`docker stats`, `docker inspect`, `docker logs` and `docker ps` are enough — so if you find yourself
reaching for `compose` mid-measurement, stop and ask why.

### 5.2 Fire the scenarios — one scenario at a time, on a barrier

Run **the same scenario on all three laptops at once**, then stop and regroup. This is not
bureaucracy: nginx's `perip` bucket is shared across every path under `/api/`, so a laptop running
scenario 2 while another runs scenario 1 spends one budget on two workloads, and each machine's p95
then describes a different mix of traffic from its neighbours'. Announce "go" on a call/chat and
start within a couple of seconds of each other.

Once per laptop (`i` = its shard number, `MACHINE` distinct per laptop):

```bash
cd server
i=1                        # THIS laptop's shard number: 1, 2 or 3
export MACHINE=laptop-$i
shot() { SHARD=$i/3 k6 run -o experimental-prometheus-rw --insecure-skip-tls-verify \
  --tag testid="$TESTID" --tag machine="$MACHINE" "$@"; }
```

Then, on a fresh barrier each time, in this order:

```bash
shot test/k6/01-read-products.js
shot test/k6/02-write-sales-contention.js          # then §5.5, before anything re-seeds
shot test/k6/03-idempotent-replay.js
shot -e DURATION=10m test/k6/04-mixed-workload.js
```

🔴 Those are four separate barriers, not a script — wait for all three laptops to finish a line
before anyone starts the next.

`--insecure-skip-tls-verify` is needed because the VM serves a self-signed placeholder cert
(`certgen`). `-e DURATION=10m` on scenario 4 is what makes it the rubric's 10-minute mixed run; its
default is 30 s, which is a dry run, not evidence — and it must be the same on all three laptops.

Do a **dry run first** with scenario 1 only, and with 04 left at its 30 s default, to shake out
credentials, the allowlist and the barrier. Then re-seed (§5.4) and do the real one.

### 5.3 Why not `run-shard-test.sh`

`server/test/k6/run-shard-test.sh` (from #357) runs all four scenarios **back-to-back on one
laptop**. Because each scenario takes a slightly different wall time on each machine, the three
laptops drift apart after the first one and end up running different scenarios simultaneously —
exactly what §5.2 exists to prevent. It is a fine convenience for a single-machine smoke test, and
it does honour `MIXED_EXTRA_FLAGS` (`MIXED_EXTRA_FLAGS="-e DURATION=10m"`) if you want the long
mixed run through it. **Do not use it for the submission run.**

### 5.4 Re-seeding, and the one ordering trap

`pnpm k6:setup` **wipes and re-seeds** the `loadtest` tenant, which resets `p12` to 50 units.

* Scenario 2 consumes that stock. A second run of scenario 2 without re-seeding sells nothing, gets
  all `409 INSUFFICIENT_STOCK`, and its p95 describes rejections. **Re-seed before every attempt at
  scenario 2.**
* 🔴 **Never re-seed between scenario 2 and its `pnpm k6:verify`** — re-seeding destroys the
  evidence that `k6:verify` is there to read.

### 5.5 Data integrity — once, from the coordinator, after scenario 2 finishes on all three shards

```bash
cd server
DATABASE_ADMIN_URL='postgres://<user>:<pw>@127.0.0.1:5432/pos' pnpm k6:verify
```

PASS = all three checks `✅ PASS` and `🎉 ALL INTEGRITY CHECKS PASSED PERFECTLY!`. This needs the
same tunnel as §4.4 (it reads Postgres directly), not just `BASE_URL`.

---

## 6. Recording the result

### 6.1 AC 3 — the RSS table

The sampler writes the table itself. Attach the generated file verbatim to #184 and fill this
summary beside it (the shape below is the shape to fill; every cell is *measured*, no cell is
pre-filled here, and a number nobody measured must stay empty):

| Container | `mem_limit` | Peak, under load | % of limit | Peak CPU | Restarts (before → after) | OOMKilled |
|---|---|---|---|---|---|---|
| `nginx` | 64m | | | | | |
| `api-1` / `api-2` / `api-3` | 384m each | | | | | |
| `worker` | 256m | | | | | |
| `bull-board` | 128m | | | | | |
| `postgres` | 1024m | | | | | |
| `redis-cache` / `redis-queue` | 256m each | | | | | |
| `etcd` | 256m | | | | | |
| `prometheus` | 512m | | | | | |
| `grafana` | 256m | | | | | |
| `node-exporter` | 64m | | | | | |
| **Peak total stack** | — | | vs **6144 MiB** | | | |
| **Peak host memory used** (`free -m`) | — | | vs **6144 MiB** | | | |

(The `mem_limit` column is transcribed from `server/docker-compose.yml` and
`deploy/compose/monitoring.yml` so you can spot a mismatch; the sampler prints the limit Docker
actually applied, and **that** is the one to trust.)

**AC 3 PASS** = every container's peak below its own `mem_limit`, peak total stack **and** peak host
used below 6144 MiB, `OOMKilled` false everywhere, and the restart counters unchanged from §5.1's
"before" snapshot. Baseline for context: idle was **~1.1 GB of 5.9 GB** with each api container at
~55 MiB of 384 MiB (#246 / close3 §3.2).

🔴 **What the number actually is.** The script is named `measure-container-rss.sh` and its report
says "RSS", but it reads `docker stats`'s `MemUsage`, which is the cgroup's memory usage **including
page cache**, not process RSS. That is the right number for *"does it fit in 6 GB"* — it is what the
kernel accounts against the limit and what OOM-kills a container — but do not relabel it as process
RSS in the evidence. Same for the host line: `free -m`'s `used` column excludes cache. Write down
what was measured, in those words.

**If a container restarts mid-run:** the run is not automatically void, but the numbers after the
restart are a different process's numbers. Record (a) which container, (b) the wall-clock time from
`docker inspect -f '{{.State.StartedAt}}'`, (c) `docker logs --tail 100 <name>` and
`docker inspect -f '{{.State.OOMKilled}} {{.State.ExitCode}}'`, and (d) whether the k6 shards logged
errors in that window. An `OOMKilled: true` is **AC 3 FAIL** and is a finding, not a retry — report
it and stop; deciding what to shrink is the owner's call, per the ticket's own *"ไม่พอ → บอกเจ้าของ
ก่อนตัดอะไร"*.

### 6.2 AC 4 — the latency table

Read it **per machine** in Grafana, filtered to your `testid`, on the five `k6:` panels of
*Srisurart POS — overview*. Every shard must clear its own threshold; an average, min or max across
the three is not a valid combined percentile (k6's remote-write computes each percentile locally —
`server/test/k6/README.md`, "Reading the numbers").

The first block below is `02 §9`'s own four rows, transcribed from
`docs/Backend_design/02_API_SCREENS.md:900-904`. The two rows marked *(script threshold, not §9)*
come from the k6 scripts' own `thresholds` and from `server/test/k6/README.md` — useful, but do not
present them as §9 criteria.

| `02 §9` row | PromQL / source | Threshold | laptop-1 | laptop-2 | laptop-3 |
|---|---|---|---|---|---|---|
| §9 read-heavy: p95 | `k6_http_req_duration_p95{scenario="read_heavy"}` | < 0.2 (seconds) | | | |
| §9 read-heavy: cache hit | `k6_cache_hits_rate{scenario="read_heavy"}` | > 0.90 | | | |
| §9 read-heavy: error rate | `k6_http_req_failed_rate{scenario="read_heavy"}` | < 0.001 | | | |
| §9 write: stock never negative, no duplicate bills | `pnpm k6:verify` (§5.5) | all PASS | (one result, not per machine) | | |
| §9 write: p95 | `k6_http_req_duration_p95{scenario="write_contention"}` | < 0.5 | | | |
| §9 replay: one bill, one stock decrement | `pnpm k6:verify` + `k6_replay_server_errors_rate{scenario="idempotent_replay"}` | == 0 | | | |
| §9 mixed: no connection-pool exhaustion | `k6_pool_exhaustion_errors_rate{scenario="mixed_workload"}` | == 0 | | | |
| **§9 mixed: `replication lag < 1s`** | **no metric exists — see below** | **N/A, and say why** | | | |
| mixed p95 *(script threshold, not §9)* | `k6_http_req_duration_p95{scenario="mixed_workload"}` | < 0.5 | | | |
| mixed error rate *(script threshold, not §9)* | `k6_http_req_failed_rate{scenario="mixed_workload"}` | < 0.001 | | | |
| **clean-measurement canary (#251)** | `sum(increase(k6_http_reqs_total{status="429"}[$__range])) by (machine)` | **== 0 for every machine** | | | |

🔴 **`02 §9`'s mixed row asks for `replication lag < 1s` and nothing in this stack can produce that
number.** There is no read replica: `server/docker-compose.yml` and `deploy/compose/vm.override.yml`
define a single `postgres` service (zero hits for "replica" in either), and `03_ARCHITECTURE.md §2`
marks streaming replication as *"เฟส 2"*. Write **N/A — single-node Postgres, no replica deployed**
in that cell with that evidence. Do not drop the row silently and do not substitute another number
for it: an AC that says *"เทียบเกณฑ์ `02 §9`"* has to account for every §9 criterion including the
one that cannot be met yet, and whether an N/A there is acceptable is the owner's call — part of
what #251 still owes (§3).

`k6_http_req_duration_p95` is in **seconds** despite the bare metric name (k6 converts
`Time`-valued trends; the four `*_duration_ms` custom trends the scripts define stay in
milliseconds). Do not mix the two in one column.

**AC 4 PASS** = the canary is 0 on all three machines **and** each machine clears every threshold on
its own. State the scope in the evidence comment in these words: *per-machine p95/p99, error rate
and cache hit at ~24 r/s per source IP through the real nginx edge, three source IPs, ~72 r/s
aggregate — not a 1,000-VU concurrency proof (`03 §8.1`, #251).*

### 6.3 What must **not** be recorded as a pass

This repo has been bitten by checkboxes that lie — #184 itself was closed by a PR that shipped no
measurement, and #288's backup AC was ticked on a closed issue while nothing had ever run. So:

* ❌ A non-zero **429** on any machine. That shard measured nginx's limiter, which is the exact
  contamination #251 exists to avoid. Discard that shard, find out why (a shared NAT/VPN putting two
  laptops behind one IP halves the budget silently), and re-run.
* ❌ Numbers from a **30 s** scenario 4 offered as the 10-minute mixed run.
* ❌ Numbers from **`k6` executed on the VM**, or through an **SSH tunnel to `api-1`** — both are
  explicitly not §9 evidence (`03 §8`, close3 §4.1). Diagnostics only.
* ❌ Numbers taken while the three laptops were running **different scenarios** (see §5.3).
* ❌ The two *(script threshold, not §9)* rows of §6.2 presented as §9 criteria, or `replication
  lag < 1s` recorded as anything but **N/A with its reason**.
* ❌ An **idle** RSS table presented as "under load". AC 3 says *ขณะมีโหลด*; the ~1.1 GB figure is
  #246's idle measurement and is already recorded as such.
* ❌ Ticking `03_ARCHITECTURE.md §8`'s *"k6 ผ่านเกณฑ์ใน §9"* box. That is #251's to release (§3).
* ❌ Ticking AC 1 or AC 2 from this document. They are #343's, and they need a real deploy.
* ❌ A `Closes #184` on a PR that carries tooling or prose instead of measurements.

Tick an AC only with pasted output in the comment. If a scenario was skipped, say which one and why.

---

## 7. When a step fails

| | Symptom | Do |
|---|---|---|
| **F1** | P8 returns **403** from a laptop | that laptop's IP is outside the allowlist at `server/docker/nginx/nginx.conf:113-121` (RFC1918 + loopback only; the campus public range is still a `TODO(owner)`). **Ask the owner for the range and get it added — do not widen the allowlist yourself, and do not add a `perip` exemption**, which would void the whole measurement. Interim option: put that laptop on the VPN so it presents an RFC1918 address, and record that it was on VPN |
| **F2** | P8 returns **502** | the monitoring overlay is not composed — P4 was not really green. Fix P4 first (a monitoring-only retry of `deploy.yml` on the same tag stops at the duplicate-release check; it needs `-e force_redeploy=true`) |
| **F3** | `k6 run` reports 401 on the remote-write output | the Basic Auth password is wrong, or `nginx-auth` was baked at first bootstrap with an older password — changing `.env` afterwards does **not** rewrite a volume that already has content (#336). Ask the owner; it is not fixable from a laptop |
| **F4** | The sampler says `docker: permission denied` | you are `cloud` without `sudo`, or `deploy` with `sudo`. See §5.1 |
| **F5** | `/opt/pos/scripts/measure-container-rss.sh` does not exist (P6 fails) | `provision.yml` has not been re-run since #346. Only `provision.yml` installs it — `deploy.yml` never copies `deploy/scripts/`. `ticket-343-vm-deploy.md` §7 step 3 |
| **F6** | `pnpm k6:setup` cannot reach Postgres | the tunnel, or a stale container IP. Re-read the IPs (§4.4); they are dynamic |
| **F7** | `pnpm k6:setup` fails on `argon2` | a Windows/native mismatch. Run it in a Linux container with its own `pnpm install` (close3 §2, "How it was run (Windows controller)") |
| **F8** | Scenario 3 throws before sending a request | `shard.assertBurstSafe` refused the plan: `ceil(TOTAL_REPLAY_VUS / N) > 45`. With the default 100 that needs `N ≥ 3`. **Raise N or lower the total — never the safety margin** |
| **F9** | Scenario 2 sells 0 bills, everything 409 | `p12` stock was already consumed. Re-seed (§5.4) |
| **F10** | Grafana panels stay *No data* after a run | check the `testid` filter first, then that the shards really used `-o experimental-prometheus-rw` (the flag is silently skipped if `K6_PROMETHEUS_RW_SERVER_URL` is unset), then Prometheus's own retention (7 d / 2 GB, `deploy/compose/monitoring.yml`) |
| **F11** | GHCR pull fails on the deploy (before any of this) | FortiGate SSL deep inspection; not solvable from here. `handoff_demo-335-merge-and-cd-blocked_21_09_2026.md` |

🔴 **Never** `docker compose down -v` on the VM, and never compose `docker-compose.dev.yml` there.

---

## 8. Closing #184

1. Post one comment on #184 with: the SHA, the `TESTID`, the sampler's report file inline, §6.1's
   summary table, §6.2's per-machine table, the `pnpm k6:verify` output, and the scope sentence from
   §6.2.
2. Tick AC 3 and AC 4 **only** if §6.1/§6.2 PASS. Tick AC 1 and AC 2 only from #343's run.
3. Leave `03_ARCHITECTURE.md §8`'s k6 box alone and say in the comment that it waits on #251.
4. If anything here turned out to be wrong on the day, fix **this** file in the same PR — a runbook
   that was wrong once and stayed wrong is how #357's `/opt/pos/deploy/scripts/` path survived a
   merge.

## 9. Marked unverified in this document

Everything else was checked against the files named beside it. These were not:

* The **`.env` key names** for the VM's Postgres and Redis passwords (§4.4) — no VPN and no
  `demo.env` in this session.
* **P8's 401-vs-403 semantics** — derived from reading `nginx.conf` (`deny all` plus `auth_basic`
  under nginx's default `satisfy all`), not from a live request to `mob04`.
* **Whether a campus-Wi-Fi laptop presents an RFC1918 address** — if it does, the existing allowlist
  already covers it and F1 never fires. Nobody has measured it; that is why P8 is a step.
* **Sampler overhead.** `docker stats --no-stream` across ~15 containers takes a noticeable fraction
  of a second, so the real sampling interval is ≥ 2 s, and the sampler itself uses a little of the
  4 vCPU it is measuring. Not quantified.
* **1800 s** in §5.1 is sized from the scenarios' declared stage durations, not from a timed run.
* **GitHub state as of 2026-09-21** — that #184 is reopened with four unticked ACs, that #251 is
  `OPEN`, and PR #357's "4 files, +409/−0". Read from `gh` on that date; re-check before relying on
  any of them.
