# Handoff: orchestrated phase-1 close-out round (2026-09-15, evening)

**Owner:** NuimanLP (`team/1`) · **Parent:** #196 · picks up from `session-2026-09-15-phase1-closeout.md`.

In this round one orchestrator session sent Opus and Sonnet subagents to do the work. Every PR got a `/code-review` + `/scrutinize` pass, often two. The owner approved every merge.

Read this before touching #184, #185, #239, #251, #67, the deploy playbook, the tenant import or etcd.

---

## 1. Owner decisions made in this round

| Topic | Decision | Recorded in |
|---|---|---|
| #67 how Actions reaches the campus VM | **self-hosted runner on the VM** (public IP and Tailscale rejected) | ADR-0013 addendum, 07 §6.2 (PR #237) |
| #185 no real shop snapshot yet | **use a synthetic snapshot first**; the real file comes later | PR #244 |
| #238 orphan references in a Drift export | **(a) tombstones**: soft-deleted rows built from the names history carries | 01 §9, ADR-0005 addendum (PR #252) |
| #238 orphan `sa_suppliers` rows (product deleted before any stock or sale) | **drop them** and count `droppedSuppliers` in `audit_log` | 01 §9, ADR-0005 (PR #252) |
| #251 how to measure §9 latency | **k6 from several machines at once**, each under nginx `perip`, remote-writing to the VM's Prometheus. No perip exemption | 03 §8.1, 02 §9, 07 §10.3 (PR #257) |
| #239 import vs nginx's 30 s timeout | **background job** (202 + poll) | PR #260 |

## 2. Merged in this round (13 PRs + 2 docs PRs)

Docs: #258 (this handoff), #259 (CLAUDE.md). #260 landed after the first version of this file.

| PR | What |
|---|---|
| #235 | remove the unused `JWT_TENANT_SECRET` (public dev default, never read) |
| #236 | Windows path separators in `tenant-job-runner.spec.ts` (the other architecture specs were checked and are not vacuous) |
| #246 | #184 write-up: `docs/handoff_log/close3-demo-deploy-2026-09-15.md` |
| #247 | `k6:verify` fails when the contention run sold nothing (strict full-depletion mode) |
| #237 | #67 `.github/workflows/deploy.yml` + `deploy/scripts/pos-deploy.sh` (the `gha-runner` user may only sudo into this wrapper) + a job-started hook |
| #253 | #248 `/health/ready` uses its own `HEALTH_DATA_SOURCE` (pool 1, `pos_app`, 2 s) |
| #244 | #185 synthetic snapshot generator + two import bugs (10 MiB body only for a **verified** platform token; the service read invented `sa_*` keys) + imported drawers archived |
| #250 | etcd-init was never copied to the VM, so **etcd auth was off on the demo VM**. Now copied, blocking, asserted, and seeds `/pos/config/log_level` |
| #255 | the etcd watch kept a stale token after a 200 `canceled … Unauthenticated`. Fixed with structured `EtcdHttpError` / `EtcdWatchAuthError` |
| #256 | #249 nginx.conf single-file bind mount went stale. Now `nginx -t` in a `run --rm` container, then `--force-recreate nginx` on every deploy |
| #252 | #238 tombstones + dropped orphan suppliers + one `fieldId()` accessor + pre-flight 400 for missing refs |
| #260 | #239 closed. Pre-flight 400 for duplicate document numbers, unparseable dates, non-finite or negative money and bad line qty (no silent clamps left; `round2` throws on NaN). `deletedAt` honoured. **The import is a background job**: `POST …/import` → 202 + `jobId`, `GET …/import/:jobId`, `import_jobs` (no RLS, no `pos_app` grants, payload cleared on terminal states, partial unique index `uq_import_jobs_active`), queue `tenant-import` (its own queue, never `backup`). A job stale for 30 min is reclaimed. `status='succeeded'` is written inside the import transaction |
| #257 | #251 `SHARD=i/N` k6 (24 r/s per IP), `location = /prometheus-remote-write/api/v1/write` (allowlist + basic auth, write only), `htpasswd-gen`, Grafana panels, `server/test/k6/README.md` |

## 3. 🔴 Findings worth remembering

- **etcd auth had never been enabled on the demo VM.** Compose bind-mounted `./docker/etcd/etcd-init.sh`, but nothing copied it. Docker created a root-owned *directory* at that path, `sh` ran on it and exited 0, and `up -d` stayed green. Every API instance had been failing its etcd login and failing open. #250 fixes it on the next deploy of a new SHA; verify with `etcdctl auth status` → `true`.
- **An etcd watch's auth failure is an HTTP 200.** An expired token on `/v3/watch` answers 200 with `"canceled":true,"cancel_reason":"…Unauthenticated…"`, never a 401. Do not match auth failures on message text: the digits `401` also appear in compaction revisions (#255).
- **An idle etcd watch reconnects about every 5 min** (undici `bodyTimeout` 300 s). This is pre-existing and harmless: the watch resumes at revision + 1. `progress_notify` does not help, because etcd's default interval is 10 min.
- **An imported drawer was stranded forever.** It was inserted `is_active=true, device_id=NULL`, so no device could close it, and it vanished from both views once a device opened a shift. Imported shifts are now all `is_active=false` (#244).
- **Rollback runs the target release's playbook** (`pos-deploy.sh` checks out `release`/`running`), not main's. Rolling back to a pre-#256 SHA therefore loses the nginx force-recreate. One review claimed the opposite, and it was wrong.
- **The unconditional nginx recreate blips 1–3 s on every deploy.** A directory mount plus `nginx -s reload` would avoid it (follow-up, touches compose).
- **k6 percentiles cannot be combined across machines.** Read p95/p99 per machine. `K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM=true` + `histogram_quantile()` is the untested way to get a true combined percentile.
- **Remote-write receiver is on permanently** (`--web.enable-remote-write-receiver`). The gate is nginx's allowlist + basic auth; rotate the credential between test windows (07 §10.3).
- **Docker Desktop on Windows hides single-file bind-mount inode bugs.** Reproduce those on a Linux daemon (`docker:dind`), not the Windows host.
- ⚠️ **Incident:** a subagent ran `docker compose down -v` on the default `srisurart-pos` project on the Windows dev machine. It deleted the local dev `pgdata` / `redis-queue-data` volumes (and the synthetic demo tenant `55f05672…`). Throwaway stacks must use a unique `-p`; never `down -v` on a shared daemon; `docker ps` first.

## 4. Still open, in order

1. ~~#239~~: **done**, PR #260 (see §2). Two review rounds: the first found a stall leaving `running` forever, success reported as failure after a crash between COMMIT and the status write, and `round2` NaN→0 on ~28 money fields. All three are fixed and tested. Imported bills still carry no `shift_id` (documented).
2. **#67:** closed on GitHub (2026-09-15 13:20Z, no comment), but its ACs need **real runner runs**, which have not happened. Owner steps, in 07 §6.2:
   1. Require approval for fork PR workflows.
   2. Create the `demo` Environment (branch `main`, no secrets).
   3. On the VM, `apt-get install ansible-core git`.
   4. Create `gha-runner`, then install `pos-deploy` + hook + sudoers (mktemp → `visudo -cf` → `install -m 0440`).
   5. Register the runner (label `srisurart-demo-deploy`) with `ACTIONS_RUNNER_HOOK_JOB_STARTED`.
   6. On the first run, confirm the hook sees `GITHUB_WORKFLOW_REF` / `GITHUB_EVENT_NAME` / `GITHUB_REPOSITORY`, and that a skipped deploy job holds no concurrency slot.
   7. Post the run links (skip→deploy, rerun no-op, manual rollback).

   Automatic rollback only works once a post-#237 release is live.
3. **Next deploy to the demo VM** (deploys #250/#255/#256/#257):
   1. Add `K6_REMOTE_WRITE_BASIC_AUTH_USER` / `_PASSWORD` to `DEMO_ENV_FILE`, then re-run `provision.yml`.
   2. After the deploy, check `ls -la /opt/pos/docker/etcd`, `docker compose logs etcd-init`, `etcdctl auth status` = `true`, `/pos/config/log_level` present, nginx serving the new config.
4. **#251 / #184:** add the campus public IP range(s) to the `TODO(owner)` allowlist in `server/docker/nginx/nginx.conf`, then do the three-laptop run per `server/test/k6/README.md` (NTP first). When every machine passes §9, tick the §9 box in 03 §8 and close #184 / #251.
5. **#185:** re-run the §9 checklist with the real shop file once it arrives (the commands are in `close4-synthetic-snapshot-2026-09-15.md`). Re-import the local demo tenant; the old one was wiped.
6. **Phase 2:** #228 → #229 → #212 / #211 / #189 → #230 → #190 → #231. PR #254 (`docs/phase2-spec`, from another session) is open and not part of this round.

## 5. Small follow-ups not ticketed

- nginx: directory mount + `nginx -s reload` instead of force-recreate (removes the per-deploy blip).
- 07 §7: a note that rolling back to a pre-#256 release does not recreate nginx.
- Import: imported bills carry no `shift_id`, so an imported shift's closing report shows 0 cash sales (documented, by design for now).
- Products referenced only by `return_items` / `quote_items` / `po_items` (no FK) are absent from the catalogue after import; their line names still render.
- Local leftovers on the Windows machine: many `.claude/worktrees/agent-*` worktrees, the `pos-ansible:local` image, `etcdreauth-*` test containers.
