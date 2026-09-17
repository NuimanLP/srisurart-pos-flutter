# Handoff: phase-1 close-out session (2026-09-15)

**Owner:** NuimanLP (`team/1`) · **Parent:** #196 · continued on another machine.

Read this before picking up #184, #67, #185 or any phase-2 ticket.

---

## 1. Decided today (owner)

| Topic | Decision | Recorded in |
|---|---|---|
| #220 sale outcome unknown (timeout / 5xx) | **Outbox, not a cart lock.** Unanswered sales / returns / drawer entries go into a local queue and are sent on reconnect. Safe because a tenant has exactly **one `pos` device** (ADR-0004), so local stock and credit checks are valid. | `02_API_SCREENS.md §8.1` (PR #227) |
| Queued-bill text | `บันทึกการขายแล้ว รอส่งเข้าระบบ` | `02 §8.1`, #228 |
| Op rejected at push | persistent **red banner on Checkout** (banner text not chosen yet) | `02 §8.1`, #230 |
| #217 import cursor | option (a): stamp `clock_timestamp()` at import | PR #224 |
| #186 branch protection | set on `main`: PR required (0 approvals), `flutter-ci-status` + `server-ci-status` required, no force push / delete, admins not enforced | `07 §4` (PR #227) |
| #67 ownership | moved from PattaraponKitcharoen to NuimanLP | issue assignee |

#226 (cart lock) was filed and then closed as superseded by #228.

## 2. Merged today

PR #223 (#219) · #224 (#217) · #225 (#221) · #227 (#220 docs + protection) · #232 (CI image push fix + provision fixes) · #233 (compose secrets).

## 3. Tickets filed today

- **#228 `q2.push`** — outbox for sales / returns / drawer + `POST /sync/push`
- **#229 `q2.catalogue`** — 18 offline write fallbacks in `frontend/lib/data/repositories/api_*.dart` create local-only rows that are **never uploaded** (products, categories, customers, mechanics, quotes, purchase orders; `receivePO` is the worst). Owner must decide per group: queue or refuse offline.
- **#230 `q3.reconcile`** — red banner + reconciliation screen (owner: banner text, who may discard)
- **#231 `q4.cutover`** — owner: production host, cutover day, rollback trigger

#196's checklist is current; "not ticketed yet" is empty.

## 4. 🔴 Findings

- **No release image was pushed to GHCR from #39 until PR #232.** `build-image` / `build-web` used a bare
  `if: github.ref == 'refs/heads/main'`; the implicit `success()` also requires every *ancestor* to have
  succeeded, and `changes` is skipped on push, so both jobs were skipped on every `main` push (checked 40
  runs back). The status jobs counted `skipped` as a pass, so CI stayed green. The GHCR `main` tag was stale.
  Fixed by checking each need's result explicitly, and the status job now fails if the image job did not
  succeed on a `main` push. The first `main` push after the merge is the proof.
- `provision.yml` wrote `arch=x86_64` into the Docker apt source (apt wants `amd64`) → `No package matching 'docker-ce'`. Fixed in #232.
- `ansible.cfg` `stdout_callback = yaml` was removed from community.general 12 → `default` + `callback_result_format = yaml`. Fixed in #232.
- Ansible from a non-interactive shell needs `</dev/null 2>&1 | cat` (it refuses non-blocking stdio).

## 5. #184 — first real demo deploy (in progress)

**VM:** `mob04` · `172.30.58.20` (campus-internal) · Ubuntu 26.04 · 4 vCPU / 6 GB / 48 GB · egress NAT `202.29.144.75`.
SSH alias `mob04` (user `cloud`, sudo) is in `~/.ssh/config` on the original Mac.

**Done:** `provision.yml` run (ok=14 failed=0): Docker 29.8 + compose v5.5.1, user `deploy`, ufw 22/80/443, `/opt/pos/.env` (0600).

**Secrets — on the original Mac only, never committed:**
- `~/.config/srisurart/demo.env` (0600) — strong random passwords + fresh RS256 JWT keypair
- `~/.config/srisurart/deploy_ed25519` — SSH key of the VM's `deploy` user

Also `~/.ssh/mob04-SriStore` (VM login key, user `cloud`). Copy all three to the other machine securely (e.g. `scp` / a password manager), **not** through git or chat.
The VM already holds the env file at `/opt/pos/.env`, so a deploy only needs the deploy key.

**Deploy command** (from `deploy/ansible/`):
```bash
DEMO_SSH_HOST=172.30.58.20 DEMO_SSH_USER=deploy DEMO_SSH_KEY_PATH=~/.config/srisurart/deploy_ed25519 \
IMAGE_TAG=<full sha with both images on GHCR> ansible-playbook deploy.yml </dev/null 2>&1 | cat
```
Only reachable from the campus network (or a VPN into it).

**State at hand-off:**
- PR #232 (`b47ab9b`) and **PR #233 (`4f3a244`) are merged.** #233: the API containers never received
  `POSTGRES_PASSWORD` (the server fell back to the dev password → api-1 crash loop on any real host), and
  `JWT_PLATFORM_SECRET` fell back to a public dev string (anyone could forge platform-admin tokens on a real host);
  compose now requires it, `.env.example` carries a dev value for CI.
- After #232, `main` built and pushed both images again; anonymous pulls of both `<sha>` tags return 200.
- **VM:** no `.current_sha`; postgres, both redis and etcd healthy; api-1 still crash-looping from the
  `b47ab9b` attempt (pre-#233). The VM `.env` does **not** have `JWT_PLATFORM_SECRET` yet — it was added only to
  `~/.config/srisurart/demo.env` on the original Mac.
- **No #184 AC is done.** The prerequisites are met: strong `ETCD_ROOT_PASSWORD` / `GRAFANA_ADMIN_PASSWORD`
  are in `demo.env`, and the compose network was created fresh with `ip_range`.

**Next steps, in order:**
1. Confirm Server CI + Flutter CI on `4f3a244` pushed both images.
2. Re-run `provision.yml` as `cloud` with `DEMO_ENV_FILE="$(cat ~/.config/srisurart/demo.env)"` so the VM `.env` gains `JWT_PLATFORM_SECRET`.
3. `deploy.yml` as `deploy` with `IMAGE_TAG=4f3a24447094547bdcc00486bd29b53833f81c3f`; check `/health/ready` and `.current_sha`.
4. Rollback: deploy `b47ab9b`, then `4f3a244` again.
5. k6: `server/test/k6/setup.ts` seeds through SQL, so it needs SSH tunnels to the compose postgres + redis and
   `JWT_PRIVATE_KEY` from `demo.env`; `BASE_URL=https://172.30.58.20`, k6 `--insecure-skip-tls-verify`
   (self-signed). Then `pnpm k6:verify`. Include 200 concurrent `POST /sales` on a 50-stock product.
6. Write the #184 result, tick `03 §8`, close #184.

**Findings still to act on:**
- `DEMO_ENV_FILE` (and later the `demo` GitHub Environment secret) must contain `JWT_PLATFORM_SECRET`.
- `setup.ts` rewrites the committed `server/test/k6/k6-env.json`; after a VM run it holds 24 h tokens signed with
  the demo key — `git checkout` it, never commit it. The committed copy already holds dev-key tokens.
- `deploy.yml` prints an ignored "File not found: .current_sha" on a first deploy — harmless.
- `JWT_TENANT_SECRET` still defaults to a dev string in `server/src/config/config.ts`; nothing seems to use it at
  runtime — worth removing.
- Diagnose with `ssh -i ~/.config/srisurart/deploy_ed25519 deploy@172.30.58.20 'cd /opt/pos && docker compose logs --tail 50 api-1'`.

## 6. #67 auto-deploy — blocked on network reachability

`.github/workflows/deploy.yml` still does not exist on `main` (`deploy/scripts/verify-ghcr-tags.sh` does).
**Blocker:** GitHub-hosted runners cannot reach `172.30.58.20`; it is a campus-internal address. `07 §5` says
the faculty confirmed inbound from outside, but no public address/port is recorded. The owner has to pick one:

1. a public IP/port forwarded to the VM's SSH (keeps ADR-0013's design: Actions → SSH → Ansible)
2. a **self-hosted runner on the VM** (outbound only, no open port) restricted to the `deploy` job and the
   `demo` environment — public repo, so it must never run PR workflows
3. Tailscale on the VM + runner (needs an account + auth key secret)

Option 2 or 3 changes ADR-0013's toolchain, so it needs an ADR-0013 addendum.

**Also still owner-side:** create the `demo` GitHub Environment (deployment branch = `main`) and its secrets.
The agent's secret-store write was blocked by the permission classifier, so run these yourself:
```bash
gh api -X PUT repos/NuimanLP/srisurart-pos-flutter/environments/demo
gh secret set DEMO_SSH_HOST --env demo --body <reachable address>
gh secret set DEMO_SSH_USER --env demo --body deploy
gh secret set DEMO_SSH_KEY  --env demo < ~/.config/srisurart/deploy_ed25519
gh secret set DEMO_ENV_FILE --env demo < ~/.config/srisurart/demo.env
```

## 7. Next steps, in order

1. Finish #184 (section 5).
2. Decide how Actions reaches the VM, then build #67 (section 6).
3. #185 once the shop provides a snapshot.
4. Phase 2: #228 → #229 → #212 / #211 / #189 → #230 → #190 → #231.
