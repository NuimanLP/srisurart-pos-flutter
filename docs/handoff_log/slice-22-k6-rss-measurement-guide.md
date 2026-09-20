# Guide & Runbook: Slice 22 (#184) — Container RSS Measurement & Distributed k6 Load Test

This document provides the complete execution procedure and verification criteria for **Slice 22 (Issue #184)** in Lane C (`team/3` PattaraponKitcharoen), fulfilling the remaining latency and memory ceiling requirements in `docs/Backend_design/03_ARCHITECTURE.md §8`, `02_API_SCREENS.md §9`, and `08_PHASE2_SPEC.md §17`.

---

## 1. Objectives & Definition of Done (DoD)

1. **Distributed k6 Load Test**: Execute all 4 load scenarios against `mob04` from 3 physical machines simultaneously (`SHARD=1/3`, `SHARD=2/3`, `SHARD=3/3`) so that each machine stays comfortably under Nginx's `perip` token bucket (24 r/s sustained vs 30 r/s limit).
2. **Clean-Measurement Canary**: Verify that HTTP 429 count is **exactly 0** on all machines (`sum(increase(k6_http_reqs_total{status="429"}[$__range])) by (machine) == 0`).
3. **Container RSS Ceiling**: Measure and record peak memory RSS per container and aggregate stack memory under maximum load, proving that total RAM usage remains strictly below the **6.0 GB host ceiling**.
4. **Data Integrity Guarantee**: Execute `pnpm k6:verify` against Postgres after the contention scenario to confirm 0 negative stock, no lost updates, and 0 duplicate receipts.

---

## 2. Preparation & Environment Setup

### 2.1 Time Synchronization (Mandatory)
Before starting, ensure all 3 test laptops have synchronized clocks to prevent skewed Grafana time axes:
- **macOS/Linux**: `sudo sntp -sS time.nist.gov` (or verify system automatic time sync is active).
- **Windows**: `w32tm /resync`

### 2.2 Host Monitor on `mob04`
SSH into `mob04`:
```bash
ssh cloud@172.30.58.20
cd /opt/pos
```

Launch the automated RSS sampler:
```bash
sudo ./deploy/scripts/measure-container-rss.sh 600 /opt/pos/container-rss-report.md
```
*(The script continuously records per-container RSS and CPU. Pressing Ctrl+C or letting the 600s duration finish will produce the Markdown summary).*

---

## 3. Distributed Execution Across 3 Laptops

### 3.1 Step A: Seed the `loadtest` Tenant (Once, on Laptop 1)
```bash
cd server
BASE_URL=https://172.30.58.20 pnpm k6:setup
```
This generates `server/test/k6/k6-env.json`.
Share `k6-env.json` with Laptop 2 and Laptop 3 (via AirDrop, USB, or secure channel).

### 3.2 Step B: Export Prometheus Remote Write Target (All 3 Laptops)
```bash
export K6_PROMETHEUS_RW_SERVER_URL="https://k6:<PASSWORD>@172.30.58.20/prometheus-remote-write/api/v1/write"
export K6_PROMETHEUS_RW_TREND_STATS="p(95),p(99)"
```

### 3.3 Step C: Run Shard Tests Concurrently
Agree on a single UTC timestamp as `TESTID`:
```bash
TESTID="$(date -u +%Y%m%dT%H%M%SZ)"
```

Execute on each laptop simultaneously:

- **Laptop 1**:
  ```bash
  ./server/test/k6/run-shard-test.sh 1 3 "$TESTID" laptop-1
  ```
- **Laptop 2**:
  ```bash
  ./server/test/k6/run-shard-test.sh 2 3 "$TESTID" laptop-2
  ```
- **Laptop 3**:
  ```bash
  ./server/test/k6/run-shard-test.sh 3 3 "$TESTID" laptop-3
  ```

---

## 4. Verification & Closing Criteria

### 4.1 Data Integrity Check (On Laptop 1)
After Scenario 2 completes, run:
```bash
BASE_URL=https://172.30.58.20 pnpm k6:verify
```
Must print:
```text
1. Stock Invariant (stock == initial - sold): ✅ PASS
2. Stock Non-Negative (stock >= 0):           ✅ PASS
3. Receipt Uniqueness (no duplicates):        ✅ PASS
🎉 ALL INTEGRITY CHECKS PASSED PERFECTLY!
```

### 4.2 Latency Threshold Verification (Grafana)
Open Grafana (`ssh -L 3000:127.0.0.1:3000 cloud@172.30.58.20` → `http://localhost:3000`):
- Filter by `testid="$TESTID"`.
- Verify per-machine p95 thresholds:
  1. `read_heavy`: `k6_http_req_duration_p95 < 0.2s` (200ms) & cache hit > 90%
  2. `write_contention`: `k6_http_req_duration_p95 < 0.5s` (500ms)
  3. `idempotent_replay`: server error rate == 0
  4. `mixed_workload`: `k6_http_req_duration_p95 < 0.5s` (500ms) & pool exhaustion errors == 0
  5. Canary: HTTP 429 count == 0 on every machine

### 4.3 Container Memory RSS Report (On `mob04`)
Check the output report generated at `/opt/pos/container-rss-report.md`:
- Each container's Peak RSS must remain within its `mem_limit`.
- Peak Total Stack RSS + OS host memory must remain within **6.0 GB ceiling** (expected ~2.2–3.5 GB under peak load).
- All containers show `OOM Killed: ✅ No` and `Restarts: 0`.

Attach the generated `container-rss-report.md` to Issue #184 and tick the `03_ARCHITECTURE.md §8` DoD checkbox.
