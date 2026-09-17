# Distributed k6 run (#251)

`docs/Backend_design/02_API_SCREENS.md §9`'s latency Definition of Done cannot be measured
cleanly from one machine: through Nginx, every k6 VU shares that machine's one source IP, and
`limit_req zone=perip rate=30r/s burst=60` starts answering `429` long before NestJS/PostgreSQL/
Redis get anywhere near their real limits — the numbers measure the rate limiter, not the system
(`docs/handoff_log/close3-demo-deploy-2026-09-15.md` §4.1). A tunnel or an on-VM run are each
contaminated a different way (same doc). Owner decision, 2026-09-15 (issue #251): run k6 from
**several machines at once** (three team laptops on the campus network), each individually under
the per-IP limit, streaming results into the demo VM's Prometheus, aggregated in Grafana. **No
`perip` exemption** — the limiter stays exactly as strict for k6 as it is for a real shop.

This README is the runbook. Read `docs/Backend_design/03_ARCHITECTURE.md §8` and
`02_API_SCREENS.md §9` first for what each scenario is proving.

## Per-shard math

nginx (`server/docker/nginx/nginx.conf`) admits, **per source IP**, on every `/api/` location:

```
limit_req_zone $binary_remote_addr zone=perip:10m rate=30r/s;
limit_req zone=perip burst=60 nodelay;
```

That is a token bucket: 30 requests/second sustained, plus a burst allowance of 60 requests
that can be spent instantly and refills at the sustained rate. `server/test/k6/lib/shard.js` is
the one place these two numbers exist in code; every scenario imports it rather than
re-deriving the arithmetic. It applies an 80%/75% safety margin (real timing jitters — network,
VM load, a laptop's own clock — so planning for the whole bucket leaves no room for that jitter
to still read as a clean, zero-`429` run):

| | nginx's real limit | safety margin | per-shard budget |
|---|---|---|---|
| sustained rate | 30 r/s | 80% | **24 r/s** (`SAFE_RATE_PER_SHARD`) |
| burst | 60 requests | 75% | **45 requests** (`SAFE_BURST_PER_SHARD`) |

**Rate-controlled scenarios (01, 04).** nginx's limiter caps *request rate*, not VU count, and a
VU's think-time-adjusted request rate is many times what a naive `total VUs / N shards` division
would suggest (a VU with a 0.2s sleep and ~0ms latency alone can approach 5 req/s — 1000 such
VUs split three ways is still thousands of req/s per machine). So `01-read-products.js` and
`04-mixed-workload.js` don't divide a VU count at all when `SHARD` is set: each shard switches
from `ramping-vus` to `ramping-arrival-rate` and runs its own fixed, safe rate
(`RATE_PER_SHARD`, default `SAFE_RATE_PER_SHARD` = 24 r/s). Three machines running that at once
is what reproduces "many concurrent users" — aggregate throughput is `N × RATE_PER_SHARD`, e.g.
72 r/s for three machines at the default. `shard.assertRateSafe()` throws before a single
request is sent if an override would exceed 24 r/s.

**Burst-controlled scenarios (02, 03).** These are one-shot contention tests — a fixed total
count of near-simultaneous actors, not a sustained rate — so here `total / N` **does** matter:
`shard.divideCount(total, i, N)` divides the total fairly (the low-index shards absorb the
remainder) so the parts still sum to the original total.
- `02-write-sales-contention.js` (default 200 total, `TOTAL_CONTENDERS`) already spreads its VUs
  across a random `sleep(Math.random() * window)` before firing. At 3 shards, `ceil(200/3) = 67`
  VUs per shard exceeds the 45-request burst budget on its own, so
  `shard.minSafeSpreadSeconds(67, 0.25, …)` widens the window: `(67 − 45) / 24 × 1.1 ≈ 1.01s`.
  The script computes this automatically — it doesn't need N to be exactly 3 — and **fails fast**
  if even a 5s window wouldn't be enough (at that point it isn't a burst test any more; add
  shards or lower `TOTAL_CONTENDERS`).
- `03-idempotent-replay.js` (default 100 total, `TOTAL_REPLAY_VUS`) has no adjustable spread —
  the 5 replay rounds are 0.05s apart *by design*, because that fixed gap is what proves the
  replay lands inside one idempotency window. So this one **fails fast instead of
  auto-widening**: `shard.assertBurstSafe()` throws if `ceil(total/N) > 45`. At the default 100
  total, that requires **N ≥ 3** (`ceil(100/3) = 34 ≤ 45`; `ceil(100/2) = 50 > 45` fails).

With no `SHARD` env var, all four scripts run byte-for-byte as they did before #251
(single machine, or any other already-working path) — nothing above changes that default.

## Setup — once, on one machine

1. **Sync clocks first.** One laptop was found ~70s behind real time during the #184 demo-deploy
   session (`docs/handoff_log/close3-demo-deploy-2026-09-15.md` finding 7) — it only skews log
   correlation there, but here it also skews `testid` ordering and Grafana's time axis across
   machines. On each laptop: Windows — `w32tm /resync`; macOS/Linux —
   `sudo sntp -sS time.nist.gov` or confirm the OS's automatic NTP sync is on. Check `date`
   against a phone before starting.
2. Pick one laptop to run setup. Point it at the VM through Nginx (not a tunnel, not the VM
   itself — that's the whole point of #251):
   ```bash
   cd server
   BASE_URL=https://<demo-vm-host> pnpm k6:setup
   ```
   This seeds the `loadtest` tenant (bypasses the per-tenant rate limiter, ADR-0006) and writes
   `server/test/k6/k6-env.json` — gitignored, **never commit it**, it carries live tokens.
3. **Share `k6-env.json` out of band** (Slack/AirDrop/USB — not git, not the repo) to the other
   two laptops, same relative path (`server/test/k6/k6-env.json`).
4. Agree on `N` (shard count, normally 3) and who is shard `1`, `2`, `3`. Each laptop needs its
   own `MACHINE` label (hostname or owner's name — anything stable and distinct).
5. Every laptop exports the Prometheus remote-write target (credentials from whoever holds
   `server/.env`'s `K6_REMOTE_WRITE_BASIC_AUTH_USER`/`_PASSWORD` — **never commit these**, share
   them the same out-of-band way as the tokens):
   ```bash
   export K6_PROMETHEUS_RW_SERVER_URL="https://k6:<password>@<demo-vm-host>/prometheus-remote-write/api/v1/write"
   export K6_PROMETHEUS_RW_TREND_STATS="p(95),p(99)"
   ```

## Per-shard commands

Run one scenario at a time, **the same scenario on all N laptops concurrently** — nginx's
`perip` bucket is shared across every path under `/api/`, so two different scenarios racing
from the same machine at once would spend one shared budget, not two independent ones.

On laptop `i` (repeat for `i` = 1..N, each with its own `SHARD` and `MACHINE`):

```bash
cd server
TESTID="$(date -u +%Y%m%dT%H%M%SZ)"   # agree on ONE value across all laptops before starting
MACHINE=laptop-a                        # distinct per laptop

SHARD=$i/3 k6 run -o experimental-prometheus-rw \
  --insecure-skip-tls-verify \
  --tag testid="$TESTID" --tag machine="$MACHINE" \
  test/k6/01-read-products.js
```

Repeat for `test/k6/02-write-sales-contention.js`, `03-idempotent-replay.js`, then
`04-mixed-workload.js` (add `-e DURATION=10m` on all three laptops together for the full
rubric-length mixed run — keep it short, e.g. the 30s default, for a dry run first).

`RATE_PER_SHARD` and `TOTAL_CONTENDERS`/`TOTAL_REPLAY_VUS` are overridable per scenario if the
team ever runs with a different N — the safety checks above run either way.

## `k6:verify` — once, at the end

Data-integrity checks (stock never negative, no duplicate bills) read Postgres directly and
don't care which machine wrote which row — run it **once**, from any one laptop, after
`02-write-sales-contention.js` has finished on every shard:

```bash
BASE_URL=https://<demo-vm-host> pnpm k6:verify
```

## Reading the numbers

Grafana's **Srisurart POS — overview** dashboard (`deploy/grafana/dashboards/pos-overview.json`)
gained five k6 panels for this. Reach it the same way as always — `ssh -L 3000:127.0.0.1:3000 …`
then `http://127.0.0.1:3000` (`server/README.md`, `07_CICD_DEPLOY.md` §7) — filtered to the
agreed `testid`.

🔴 **k6's Prometheus remote-write output computes each percentile locally, per k6 process.**
There is no valid way to recombine three machines' independent p95s into one true
cross-machine p95 after the fact (it is not a linear statistic). So §9 latency evidence is
**per machine**: every shard's own `k6_http_req_duration_p95` line must clear the threshold —
not an average, min, or max of the three. This is why the dashboard groups by `machine`. This
is the standard the PromQL table below assumes.

**Advanced, if a true combined percentile is ever wanted:** k6's remote-write output has a
second mode, `TrendAsNativeHistogram`, gated by env var **`K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM=true`**
(name confirmed from the k6 source, `internal/output/prometheusrw/remotewrite/config.go` —
"the native-histograms feature flag... is intentionally not bound here [as a JSON option]").
It maps each Trend to a Prometheus **native histogram** instead of per-stat gauges, and native
histograms *can* be `sum()`-ed across series before `histogram_quantile()` is applied, because
Prometheus's own aggregation preserves enough bucket structure to do that correctly — unlike
the default gauge-per-stat mode this README otherwise assumes throughout. A query would look
like `histogram_quantile(0.95, sum(rate(k6_http_req_duration[5m])))` (no `_p95` suffix — native
histograms are a single metric, not one series per requested stat). **This project has not
run that mode** — the env var name and mechanism are verified from the k6 source, but the
actual query hasn't been exercised end to end against our stack, and it changes what
`K6_PROMETHEUS_RW_TREND_STATS` even means (native histogram mode ignores it). Per-machine
remains the default standard for §9 evidence; treat this as a documented option, not a
validated one, if the team ever wants a single combined number instead.

| `02_API_SCREENS.md §9` row | scenario tag | PromQL |
|---|---|---|
| `GET /products` p95 < 200ms | `read_heavy` | `k6_http_req_duration_p95{scenario="read_heavy"}` < `0.2` (seconds — the metric name carries no unit suffix, but the value is seconds; see note below) |
| `GET /products` cache hit > 90% | `read_heavy` | `k6_cache_hits_rate{scenario="read_heavy"}` > `0.90` |
| `GET /products` error < 0.1% | `read_heavy` | `k6_http_req_failed_rate{scenario="read_heavy"}` < `0.001` |
| `POST /sales` p95 < 500ms | `write_contention` | `k6_http_req_duration_p95{scenario="write_contention"}` < `0.5` |
| `POST /sales` stock never negative / no duplicate bills | `write_contention` | not a Prometheus metric — `pnpm k6:verify` against Postgres (once, see above) |
| Idempotent replay: 1 bill, 1 stock decrement | `idempotent_replay` | `pnpm k6:verify`; `k6_replay_server_errors_rate{scenario="idempotent_replay"}` == `0` as a live sanity check |
| Mixed error < 0.1% | `mixed_workload` | `k6_http_req_failed_rate{scenario="mixed_workload"}` < `0.001` |
| Mixed p95 < 500ms | `mixed_workload` | `k6_http_req_duration_p95{scenario="mixed_workload"}` < `0.5` |
| Mixed: no pool exhaustion | `mixed_workload` | `k6_pool_exhaustion_errors_rate{scenario="mixed_workload"}` == `0` |
| **Clean-measurement canary (#251's whole point)** | any | `sum(increase(k6_http_reqs_total{status="429"}[$__range])) by (machine)` — **must be 0 for every machine**. Any non-zero means that shard's own run is contaminated exactly like the single-machine path was; discard that shard's numbers and re-run it (probably at a lower `RATE_PER_SHARD`, or check the laptop's actual source IP — a corporate VPN/proxy can put two laptops behind one NAT IP, which silently halves the effective per-shard budget) |

Note on units: k6's Prometheus remote-write output prefixes every metric `k6_` and, for a Trend
configured with `K6_PROMETHEUS_RW_TREND_STATS`, suffixes the requested stat (`p(95)` → `_p95`).
Unlike the native-histogram mode, this "trend-as-gauges" mode (the default, and what we use)
does **not** add a unit suffix to the name — but it still converts the *value* to seconds for a
`Time`-valued metric (`adaptUnit`, `internal/output/prometheusrw/remotewrite/trend.go` in the k6
source). `http_req_duration` is `Time`-valued, so `k6_http_req_duration_p95` is in seconds
despite the bare name. The four custom ms-named Trends the scripts define
(`read_duration_ms`, `write_duration_ms`, `replay_duration_ms`, `mixed_req_duration_ms`) are
**not** declared `Time`-valued, so those stay in milliseconds as pushed.

## Cleanup

- Nothing to tear down on the laptops — `k6 run` exits when the scenario ends.
- `server/test/k6/k6-env.json` is gitignored; delete your local copy once the run is done if it
  was shared over a channel you'd rather not leave it in.
- The `loadtest` tenant seeded by `pnpm k6:setup` is reusable across runs (setup wipes and
  reseeds it each time) — no VM-side cleanup needed between dry runs.
