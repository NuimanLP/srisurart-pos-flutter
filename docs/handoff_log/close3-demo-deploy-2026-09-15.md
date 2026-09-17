# Handoff: #184 `close.3` — first real demo deploy, rollback drill, k6 on the VM (2026-09-15)

**Owner:** NuimanLP (`team/1`) · **Issue:** #184 (left open; the owner closes it) · **Parent:** #196
**Environment:** `demo` VM `mob04` · `172.30.58.20` · Ubuntu 26.04 · 4 vCPU / 6 GB / 48 GB
**Approval:** the project owner approved, in the session, that an agent runs provision, deploy,
rollback and SSH against this VM.

Read this before #67 (auto-deploy), before touching `deploy/ansible/`, or before re-running k6.

---

## 1. Result

| #184 AC | Result |
|---|---|
| First real `deploy.yml` from a green `main` image; `/health/ready` 200; `.current_sha` matches | ✅ `8e873cd` deployed, `ok=31 failed=0`, `/health/ready` 200 from this machine and on VM loopback, `.current_sha` = `8e873cd56a4e3012c0474ebf20027987203a35aa` |
| Rollback exercised once | ✅ `8e873cd` → `4f3a244` → `8e873cd`, both `ok=31 failed=0` (see §3 for what this does and does not prove) |
| k6 §9 scenarios re-run against the VM, results recorded | ⚠️ Run and recorded (§4). **Correctness passes everywhere. Latency thresholds fail on every path**, and none of the paths is a clean measurement: see §4.1 |
| 200 concurrent `POST /sales` on a 50-stock product → exactly 50 bills, stock 0, `k6:verify` attached | ✅ Three runs, all 50 / 0 5xx / stock 0 (§4.2) |
| Matching DoD boxes in `03 §8` ticked | ✅ Only the 200-on-50 box. The "k6 passes §9" box stays open (§4.1) |

## 2. What was deployed and why

- **Target `8e873cd`** (`main` tip, merge of #234). Both GHCR tags answered 200 anonymously
  (`deploy/scripts/verify-ghcr-tags.sh`), and Server CI + Flutter CI on it both completed `success`.
- **Rollback target `4f3a244`** (merge of #233), also with both images and green CI.
- `b47ab9b` was **not** used. The three images are built from identical server code:
  `b47ab9b..4f3a244` changes only `server/.env.example` and `server/docker-compose.yml`, and
  `4f3a244..8e873cd` changes only a handoff doc. A deploy copies the compose files from the
  *controller's checkout*, not from the tag, so `b47ab9b` would probably have booted too. That was not
  tested. No earlier SHA has images (no image was pushed between #39 and #232).

### How it was run (Windows controller)

`ansible-playbook` and `k6` are not on this machine, and WSL has no distro. Everything ran in
containers under Docker Desktop:

- **Ansible:** a throwaway `python:3.12-slim` + `openssh-client` + `pip install "ansible>=11,<13"`
  image. The repo was mounted read-only at `/repo` and `~/.ssh` read-only at `/secrets`. Keys were
  copied inside the container and `chmod 600`'d. `ANSIBLE_CONFIG` was set explicitly, because Ansible
  ignores `ansible.cfg` in a world-writable directory and Windows bind mounts look world-writable.
  `DEMO_ENV_FILE="$(cat /secrets/demo.env)"`, `DEMO_SSH_KEY_PUB` set to `deploy_ed25519.pub`, and
  `ansible-playbook … </dev/null 2>&1 | cat`.
- **k6:** `grafana/k6:latest`. Seeding (`pnpm k6:setup`) and `pnpm k6:verify` ran in a
  `node:24-bookworm` container. It held an SSH tunnel as `deploy` to the compose Postgres
  (`172.30.0.128:5432`), `redis-cache` (`172.30.0.132:6379`) and `api-1` (`172.30.0.11:3000`), used a
  Linux `pnpm install` of a copy of `server/` (argon2 is native), and read the env from `demo.env`
  without printing it. The generated `k6-env.json` stayed in that container and the session
  scratchpad, and was deleted afterwards. The repo's `server/test/k6/k6-env.json` was never touched.

## 3. Deploy evidence

### 3.1 Provision (as `cloud`)

- Before: the VM `.env` had 13 keys, without `JWT_PLATFORM_SECRET`. A sha256 of the local `demo.env`
  minus that key matched the VM file (`659ad70f…`), so the re-provision could only add that key.
- `provision.yml`: `ok=14 changed=1 failed=0` in 36 s. The only change was the `.env` write.
- After: 14 keys including `JWT_PLATFORM_SECRET`, mode `600`, owner `deploy`. Checked by key name only.

### 3.2 Deploys (as `deploy`)

| Run | SHA | Result | Wall time |
|---|---|---|---|
| first deploy | `8e873cd` | `ok=31 changed=15 failed=0 ignored=1` (the known `.current_sha` not found) | 136 s (includes the first image pulls and monitoring images) |
| rollback | `4f3a244` | `ok=31 changed=12 failed=0` | 102 s |
| forward | `8e873cd` | `ok=31 changed=12 failed=0` | 95 s |
| same SHA again | `8e873cd` | `ok=4 changed=0`, "already active" | 5 s |

After each run: `api-1..3`, `worker` and `bull-board` were on the expected tag, api health was
`healthy` with `restarts=0`, `.current_sha` matched, and `GET https://172.30.58.20/health/ready`
answered 200 from this machine (`{"postgres":"up","redisCache":"up","redisQueue":"up"}`). `/` served
the web client (200), and `:80` redirected to https (301). All nine migrations were applied, through
`1788652802131`, and `pos_app` in `pos` carries `statement_timeout=25s` and
`idle_in_transaction_session_timeout=5s`. The monitoring overlay came up healthy on the first deploy
(Prometheus and Grafana on loopback). The `api-1` crash loop left by the `b47ab9b` attempt is gone:
the container was recreated on `8e873cd`.

Memory after the deploy: POS stack + monitoring used about 1.1 GB of the 5.9 GB. Each api container
used about 55 MiB of its 384 MiB limit.

### 3.3 Availability during the rolling restarts

A poller on this machine hit `GET /health/ready` about once a second through nginx:

- **Rollback:** 134 × 200 and 1 × `000`. The `000` was at 19:10:41, seven seconds **before** the
  playbook started (19:10:48), so it was a network blip, not the deploy.
- **Forward:** 118 × 200.

This shows nginx kept an upstream through each rolling restart. It does **not** show that a
`POST /sales` in flight on a restarting instance survives. `07 §6` still documents that as a 502
(no drain, and nginx does not retry POST).

### 3.4 What the rollback drill proves, and what it does not

- ✅ The playbook's rollback path works: a different `image_tag` passes the duplicate check, pulls,
  runs `web-sync` + `migrate`, restarts api 1→2→3, and records the older SHA. Re-running the recorded
  SHA is a 5 s no-op.
- ⚠️ It swapped images built from the same code, so it proves the mechanism, not a code revert.
- ⚠️ **A rollback reverts images only.** `docker-compose.yml`, `vm.override.yml`, `nginx.conf` and the
  Postgres init scripts are copied from the checkout that runs the playbook, not from the tag. Schema
  is forward-only (`07 §6`). To revert configuration too, run the playbook from a checkout of the
  target SHA. #67's workflow should check out `image_tag`, not `main`.

## 4. k6 against the VM

The loadtest tenant (`plan='loadtest'`, ADR-0006) was re-seeded by `pnpm k6:setup` before each path.
The scripts were used unchanged.

### 4.1 Why none of the latency numbers is a clean §9 measurement

1. **Through nginx from one machine, k6 measures nginx.** `nginx.conf` puts
   `limit_req zone=perip rate=30r/s burst=60 nodelay` on `/api/`. Every k6 VU shares this machine's IP,
   so it is the same trap `02 §9` warns about for the tenant limiter, one layer further out.
2. **Direct to `api-1` over an SSH tunnel** bypasses nginx but funnels everything through one SSH
   connection to one Node instance. That measures the tunnel.
3. **k6 on the VM itself**, in a throwaway container on the compose network against `api-1`, removes
   both of those. But `03 §8` says "ห้ามรัน k6 บน VM นี้" for a good reason: k6's 1,000 VUs share the 4
   vCPU with the stack, and only one of the three api instances is hit. It was run as a **diagnostic
   only**: to show that no request fails once the limiter and the tunnel are out of the way. Its latency
   numbers are contaminated and are not submission evidence. The `grafana/k6` image and the temp dir
   were removed from the VM afterwards.

So the `03 §8` box "k6 ผ่านเกณฑ์ใน §9" stays open. The owner has to pick a clean path (§6).

### 4.2 The 200-on-50 contention test (AC)

| Path | 201 | 409 `INSUFFICIENT_STOCK` | 429 | 5xx | p95 | `k6:verify` |
|---|---|---|---|---|---|---|
| nginx `https://172.30.58.20` | 50 | 43 | 107 | 0 | 1.44 s | stock 0 · 50 sold / 50 bills · movements −50 · 50/50 receipts · ALL PASS |
| SSH tunnel → `api-1` | 50 | 150 | 0 | 0 | 3.39 s | stock 0 · 50/50 · −50 · ALL PASS |
| on-VM → `api-1` (diagnostic) | 50 | 150 | 0 | 0 | 1.36 s | stock 0 · 50/50 · −50 · ALL PASS |

The nginx status split comes from nginx's own access log. On that path only 93 of the 200 requests
reached the application. **The tunnel run is the AC evidence**: all 200 reached the application from
another machine, which `03 §8` allows.

`pnpm k6:verify` output, tunnel run:

```
Current Stock in DB:              0
Total Units Sold (sale_items):   50 (across 50 bills)
Expected Stock (initial - sold):  0
Stock Movements Balance (delta):  -50
Total Sales / Unique Receipts:    50 / 50
1. Stock Invariant (stock == initial - sold): ✅ PASS
2. Stock Non-Negative (stock >= 0):           ✅ PASS
3. Receipt Uniqueness (no duplicates):        ✅ PASS
🎉 ALL INTEGRITY CHECKS PASSED PERFECTLY!
```

### 4.3 The other scenarios

| Scenario | Path | Requests | Failed | Correctness | p95 (threshold) |
|---|---|---|---|---|---|
| 1 read, 1,000 VUs | nginx | 44,486 | 97.51% (429) | — | 621 ms (200 ms) |
| 1 read, 1,000 VUs | tunnel | 6,011 (163/s) | 0% | cache hit 99.98% | 11.6 s |
| 1 read, 1,000 VUs | on-VM | 14,023 (398/s) | 0% | cache hit 99.99% | 839 ms, max 26.4 s |
| 3 idempotent replay, 100 VUs × 5 | on-VM | 500 | 0% | 100 created, 400 replays matched, 0 5xx | 1.32 s (500 ms) |
| 4 mixed 80/20, 500 VUs, 30 s | on-VM | 5,976 (4,763 read / 1,213 write) | 0% | 0 pool exhaustion **over 30 s only** — `02 §9` row 4 specifies **10 minutes**, so this is not a spec-length run (the script's default; `-e DURATION=10m` was not used) | 3.23 s (500 ms) |

After scenario 4, a whole-catalogue check ran as `postgres` over the tunnel. All 51 products had
`stock == seeded − sold (non-voided)` and `Σ movements == −sold`, with none negative. There were
1,363 sales, 1,363 distinct receipts and 1,363 idempotency keys (50 + 100 + 1,213). No api container
restarted or was OOM-killed.

For comparison, #37 on a dev machine hit api directly without nginx: p95 of 123 / 349 / 303 / 15 ms.

## 5. Findings

1. 🔴 **etcd auth is not enabled on the VM** (the PR #237 review's pre-existing bug, confirmed read-only).
   `/opt/pos/docker/etcd/etcd-init.sh` is a **root-owned directory** created at 10:24 by Docker's
   bind mount, because `deploy.yml` never copies the script. The `etcd-init` container "exits 0" with
   **no output**, since `sh` handed a directory does nothing and succeeds. `etcdctl auth status` answers
   `Authentication Status: false`. `up -d` stays green. The fix (copy task + stray-directory removal)
   is handled by a separate PR on branch `fix/etcd-init-deploy`. The VM was not touched here.
2. **Nginx's per-IP limit makes a single-machine k6 run through nginx meaningless** (§4.1). The same
   limit also means any shop behind one NAT IP shares 30 r/s. That is fine for one counter, but worth
   knowing before a multi-till tenant.
3. 🔴 **`/health/ready` reported `postgres: down` (503) under load.** During the 500-VU on-VM mixed run,
   a Prometheus scrape of `api-1` got `NOT_READY {"postgres":"down"}`. The readiness `SELECT 1` shares
   the request pool (`DB_POOL_SIZE` 15) and has a 2 s probe timeout, so a saturated pool reads as a
   dead database. Nginx does not use readiness, so no counter traffic was affected. But
   Prometheus/Grafana will show false "down" exactly when the system is busiest. It was seen once,
   under a contaminated load.
4. **`verify-integrity.ts` passes when nothing was sold.** A verify run straight after seeding printed
   `0 (across 0 bills)` and "ALL INTEGRITY CHECKS PASSED". It never asserts `sold == initialStock` or a
   bill count, so it cannot tell "the contention run never reached the server" from a good run. Pair it
   with the k6 counters, or add an expected-bills assertion.
5. 🔴 **A rollback reverts images, not configuration** (§3.4). PR #237 (#67) addresses this: its
   wrapper deploys from its own clone checked out at `image_tag`, so config follows the tag.
6. **Probable, not tested: nginx keeps an old `nginx.conf` after a deploy that changes it.**
   `nginx.conf` is a single-file bind mount, Ansible `copy` replaces the file by rename (new inode), and
   `up -d --no-deps nginx` does not recreate the container when the compose config is unchanged. Nginx
   stayed up across the rollback here, as expected, since the config was unchanged. This is the same
   mechanism `deploy.yml` already documents and works around for Prometheus (#148).
7. The controller machine's clock was about 70 s behind real time (the VM is NTP-synced). It only
   skews log correlation, but check `date` before comparing k6 timestamps with VM logs.

## 6. Owner to-dos

- [x] Decide how §9 latency gets measured cleanly — **owner decision 2026-09-15, issue #251:**
      option (b), refined to "several machines at once" rather than one separate host: three team
      laptops on the campus network, each under its own `perip` budget (no exemption), streaming
      into the demo VM's Prometheus via a new allowlisted + Basic-Auth Nginx location and
      aggregated in Grafana. Implemented in the #251 PR (`server/test/k6/lib/shard.js`,
      `server/test/k6/README.md`, `03_ARCHITECTURE.md` §8.1, `02_API_SCREENS.md` §9). The real
      run is still the owner's to do — this closes the *how*, not the *done*.
- [ ] Close #184 if §1 is enough. Latency is the only AC not met cleanly.
- [ ] After the `fix/etcd-init-deploy` PR merges and deploys: confirm `etcdctl auth status` shows `true`, and remove the
      root-owned `docker/etcd/etcd-init.sh` directory if the PR does not.
- [ ] Decide whether readiness should get its own connection or a longer timeout (finding 3).
- [ ] Still carried from `session-2026-09-15-phase1-closeout.md` §6: the `demo` GitHub Environment and
      its secrets (including `JWT_PLATFORM_SECRET` in `DEMO_ENV_FILE`).
- The demo VM now holds the loadtest tenant `00000000-0000-4000-8000-000000000001` with 1,363 test
  bills. `pnpm k6:setup` wipes and re-seeds it, and no other tenant was touched.
