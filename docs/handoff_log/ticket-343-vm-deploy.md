# Ticket #343 `vm.deploy` — D9 pre-flight for the first real deploy to `mob04`

**Date:** 2026-09-21 · **Lane:** C · **Branch:** `docs/343-vm-deploy-preflight` ·
**Base:** `origin/main` at `cd8989b` · **Spec:** #335 **D9** · `07_CICD_DEPLOY.md §6, §7` ·
**ADR-0013**

> ## 🔴 Nothing has been deployed. No acceptance criterion of #343 is ticked.
>
> This session was allowed to **read** `mob04` (ssh `cat` / `ls` / `docker ps` /
> `docker network inspect`), to run `ansible -m ping`, and to run `ansible-playbook --check --diff`.
> Every command that would change VM state is **owner-only**. §7 below is the script the owner runs;
> §8 is the rollback drill; §9 is what stays open afterwards.
>
> **There is one hard blocker that must be cleared before §7 can work at all** — pre-flight item 1.
> Read §3 and §4 before running anything.

---

## 1. What `mob04` is running right now (read-only, 2026-09-21)

| | |
|---|---|
| Host | `172.30.58.20` (`mob04-mob04`), Ubuntu, kernel `7.0.0-28-generic`, `x86_64` |
| Memory / disk | 5920 MiB total (1236 used, 4683 available) · `/dev/sda1` 48 G, 14 % used |
| Docker | Engine present, **Compose v5.5.1** · `python3` → 3.14.4 |
| `/opt/pos/.current_sha` | `8e873cd56a4e3012c0474ebf20027987203a35aa` (= `8e873cd`, merge of #234, **188 commits behind `main`**) |
| Containers | 13 up **5 days**: `api-1/2/3` (healthy), `worker`, `bull-board`, `nginx`, `postgres`, `redis-cache`, `redis-queue`, `etcd` (healthy), plus `prometheus`, `grafana`, `node-exporter` (all healthy) — all three API images are `ghcr.io/nuimanlp/srisurart-pos-server:8e873cd…` |
| Compose network | `srisurart-pos_default` → `[{"Subnet":"172.30.0.0/24","IPRange":"172.30.0.128/25","Gateway":"172.30.0.1"}]` |

So the VM is alive on a mid-September release and has **never** been deployed from `main` since.
That single fact is what makes the six D9 items matter: almost everything added after 2026-09-15
(#251's `htpasswd-gen`, #249's nginx recreate, #342's server-mode web image, #346's ops scripts) has
never touched this machine.

---

## 2. How to run Ansible at all from this Windows machine

`ansible-core` is **not installed** and there is no usable WSL distro (only `docker-desktop`).
Docker and OpenSSH are present. So Ansible runs in a throwaway container. The image is pinned by
digest:

```
alpine/ansible:2.18.1
  → alpine/ansible@sha256:22227b578da3371267201879f44de86569e9b531db536e1d9d2b83aed35b6cfc
```

Two non-obvious things make the difference between "works" and "fails confusingly":

1. 🔴 **A Windows bind mount is world-writable, so Ansible silently ignores `ansible.cfg`.**
   D9 item 2 says "you must run from `deploy/ansible/` or `ansible.cfg` is not read". On this host
   that is **necessary but not sufficient** — `-w /work/deploy/ansible` still produced:

   ```
   [WARNING]: Ansible is being run in a world writable directory (/work/deploy/ansible),
   ignoring it as an ansible.cfg source.
   ansible [core 2.18.1]
     config file = None
   ```

   and the very next line was `UNREACHABLE! … Host key verification failed.`, because
   `host_key_checking = False` lives in that ignored file. Fix: pass
   **`-e ANSIBLE_CONFIG=/work/deploy/ansible/ansible.cfg`**. With it, `config file =
   /work/deploy/ansible/ansible.cfg` and the host-key error disappears. Do not "fix" this by
   disabling host-key checking on the command line — that hides the real cause and it will come back
   for `timeout`, `pipelining` and the inventory default too.

2. **The private key cannot be used straight off a read-only mount.** `ssh` refuses a key that is
   group/other-readable, and a `:ro` mount cannot be `chmod`ed. So each command copies the key to
   `/tmp` inside the container and `chmod 600`s it there. The key never leaves the machine and the
   container is `--rm`.

The repo path must stay ASCII (`CLAUDE.md`); `D:\Beestation\Sri_POS\Flutter` is fine.

---

## 3. Which user — `cloud` or `deploy`? (they are not interchangeable) 🔴

The two playbooks need **different** accounts, and this is measured, not assumed:

| | `cloud` (uid 1000) | `deploy` (uid 1001) |
|---|---|---|
| groups | `cloud adm cdrom sudo dip lxd` | `deploy docker` |
| `sudo -n true` | **NOPASSWD ALL** | no sudo at all (07 §6.2) |
| `test -w /opt/pos` | **NOT WRITABLE** (`/opt/pos` is `drwxr-xr-x deploy:deploy`) | writable (owner) |
| `docker ps` without sudo | `permission denied … /var/run/docker.sock` | works |
| key | `~/.ssh/mob04-SriStore` | `~/.ssh/deploy_ed25519` |

Therefore:

* **`provision.yml` → `DEMO_SSH_USER=cloud`.** It is `become: true`; `deploy` cannot become root.
* **`deploy.yml` → `DEMO_SSH_USER=deploy`.** It is `become: false`, it `copy`s into `/opt/pos`, and
  every step shells out to `docker compose`. As `cloud` it would die on the first copy and on every
  docker call. `--check` does **not** reveal this: `copy` in check mode compares checksums without
  attempting a write, and `command` tasks are skipped entirely, so a check run as `cloud` looks
  fine. Only a real run would have found it — on demo day.

**On the inventory default.** `deploy/ansible/inventory/hosts.ini` defaults
`ansible_user` to `deploy`. That default is **correct and should not be changed**: it is right for
`deploy.yml`, the playbook that runs on every release and the one the self-hosted runner invokes
(`pos-deploy.sh` runs as `deploy` with `ansible_connection=local`). `provision.yml` is a rare,
owner-run, one-off, and it is the caller that must pass `DEMO_SSH_USER=cloud`. Changing the default
to `cloud` would make the common path wrong to make the rare path convenient. What was missing was
not a different default but this table — it is now in §7 at the point of use.

---

## 4. D9 pre-flight — the six items, with evidence

| # | D9 requirement | Status | Evidence |
|---|---|---|---|
| **1** | `/opt/pos/.env` is written by `provision.yml`, **not** `deploy.yml`; a VM not re-provisioned after #64/#251 fails every task that interpolates it | 🛑 **BLOCKER — NOT CLEAR** | `/opt/pos/.env` exists (`-rw------- deploy:deploy`, written **Sep 15 12:06**). Its key **names** (values never read) are: `POSTGRES_PASSWORD`, `POS_APP_PASSWORD`, `REDIS_PASSWORD`, `REDIS_COMMAND_TIMEOUT_MS`, `JWT_PLATFORM_SECRET`, `JWT_PRIVATE_KEY`, `JWT_PUBLIC_KEYS`, `BULL_BOARD_USER`, `BULL_BOARD_PASSWORD`, `ETCD_ROOT_PASSWORD`, `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD`, `DB_POOL_SIZE`, `LOG_LEVEL`. **Missing: `K6_REMOTE_WRITE_BASIC_AUTH_USER` and `K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD`** — both are `:?`-required by `server/docker-compose.yml:103-104` (`htpasswd-gen`, added by #251 *after* this `.env` was written). See §5. |
| **2** | inventory via `DEMO_SSH_HOST`/`DEMO_SSH_USER`/`DEMO_SSH_KEY_PATH`; needs `ansible-core`; must run from `deploy/ansible/` | ✅ **CLEAR — method proven** | `ansible-core` absent on host → pinned container (§2). `ansible -m ping` → `SUCCESS / ping: pong` as **both** `cloud` and `deploy` (verbatim in §6). 🔴 Running *from* `deploy/ansible/` is not enough on Windows — `ANSIBLE_CONFIG` must be passed explicitly (§2 item 1). Correct user per playbook: §3. |
| **3** | must pass `-e image_tag=<40-hex>`; `-e force_redeploy=true` if the SHA is already in `.current_sha`, or the play ends mid-way in silence | ✅ **CLEAR** | Deploy **`cd8989b44912076aaa93b347d62c7eaf1530fa82`** — current head of `main`; `verify-ghcr-tags.sh` → both images **HTTP 200**; Server CI and Flutter CI both `success` on it. `.current_sha` is `8e873cd…` ≠ that, so **`force_redeploy` is NOT needed** for the forward deploy (it *is* needed for the rollback drill and for re-running the same tag). ⚠️ `cd8989b` is only head *today* — re-check §7 step 0 before running, and if `main` has moved, use the new head and verify its tags. |
| **4** | the network pre-flight in `deploy.yml` hard-fails if the VM's network predates `ip_range`; costs one planned outage per 07 §7 | ✅ **CLEAR — NO DOWNTIME NEEDED** | `docker network inspect srisurart-pos_default` → `IPRange: "172.30.0.128/25"`, `Gateway: "172.30.0.1"`, `Subnet: "172.30.0.0/24"`. The assert at `deploy.yml:96-104` requires `'172.30.0.128/25' in stdout` → **satisfied**. The 07 §7 one-time `down --remove-orphans` recreate is **not required**. Do **not** run it "just in case": it is a full POS outage for nothing. (The `--check` run reports this assert as *failed* — a false alarm, see §6.) |
| **5** | real rollback is **not** `pos-deploy.sh` — it is `ansible-playbook … -e image_tag=<old> -e force_redeploy=true` | ✅ **CLEAR** | Drill target **`325bf802641372b307c791363e890a1cb01a5e5f`** (`325bf80`, merge of #356): both images **HTTP 200** on GHCR; an ancestor of `main`; newer than `ROLLBACK_FLOOR` `4f3a244`; and — the reason to prefer it over `8e873cd` — it is **after** `c8eb552` (#342), so its web image is already the server-mode build. `8e873cd` also has both images but its web image is the pre-#342 offline build, so rolling back that far changes what the browser gets. `pos-deploy.sh` is unusable here: it requires being user `deploy` through the runner's sudoers, which D9 removed from scope. Commands: §8. |
| **6** | the monitoring step's `rescue` only **warns**; the playbook can be green while Grafana is down | ✅ **CLEAR — separate check written** | `deploy.yml:367-395`: the whole monitoring block sits in `block:`/`rescue:` *after* `.current_sha` is written, and the `rescue` is a single `debug` task. A green PLAY RECAP therefore proves nothing about Prometheus/Grafana. The independent check is **§7 step 6** and it is a separate tick, not a corollary of the playbook's exit code. |

**Score: 5 of 6 clear, 1 blocker.** Item 1 must be cleared by the owner before §7 step 4.

---

## 5. The blocker, precisely

`server/docker-compose.yml:93-104` defines `htpasswd-gen` (#251) with:

```yaml
    environment:
      K6_REMOTE_WRITE_BASIC_AUTH_USER: ${K6_REMOTE_WRITE_BASIC_AUTH_USER:?K6_REMOTE_WRITE_BASIC_AUTH_USER is required}
      K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD: ${K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD:?K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD is required}
```

`:?` makes Compose refuse **at interpolation time**, for *any* subcommand, not just for that
service. `deploy.yml`'s first Compose task is `docker compose … pull` — so the play would die there,
before pulling anything, with `K6_REMOTE_WRITE_BASIC_AUTH_USER is required`. Nothing would be
broken, but nothing would deploy either, and the message points at k6 rather than at the stale
`.env`, which is how an hour disappears on demo day. This is item 1 of D9 doing exactly what it was
written to warn about.

The fix is **not** to hand-edit `.env` on the VM. Lane A generated a complete `DEMO_ENV_FILE` for
#336 (`ticket-336-env-secrets.md`; the value is held by the owner and is not in this repo) — that
file has all 10 `:?` keys plus `GRAFANA_ADMIN_PASSWORD`. Re-running `provision.yml` with it
installs it at `0600`. That is §7 step 3.

Two facts that make step 3 safe, both verified in the `--check` run:

* The `.env` task is `when: demo_env_content != ""`. Running `provision.yml` **without**
  `DEMO_ENV_FILE` reports `skipping` and leaves the VM's `.env` untouched — a re-run cannot wipe
  secrets. The flip side is that it also cannot *tell* you it did nothing, so check the recap.
* `provision.yml` is idempotent over Docker/UFW/user/dirs; the only `changed` items against today's
  VM are the ops scripts, `/opt/pos/backups`, the cron entry, and a chown of the root-owned
  `/opt/pos/docker/etcd` (see §9).

> 🔴 **Known, separate, not fixed by this ticket:** `CORS_ORIGINS` and `PLATFORM_ADMIN_IPS` are also
> absent from `/opt/pos/.env`, **and no Compose file passes them into any container** (lane A's
> announcement of 2026-09-20 15:20 on the status board, reported at #335). Putting them in
> `DEMO_ENV_FILE` will therefore not close CORS. Nobody may write an AC saying CORS is closed on the
> VM. It does not block the deploy.

---

## 6. What was actually run, verbatim

### 6.1 `ansible -m ping` — as `cloud` (for `provision.yml`)

```
$ ... -e ANSIBLE_CONFIG=/work/deploy/ansible/ansible.cfg -e DEMO_SSH_USER=cloud ...
    ansible -i inventory/hosts.ini demo -m ping
ansible [core 2.18.1]
  config file = /work/deploy/ansible/ansible.cfg
vm-demo | SUCCESS =>
    changed: false
    ping: pong
```

### 6.2 `ansible -m ping` — as `deploy` (for `deploy.yml`)

```
$ ... -e DEMO_SSH_USER=deploy -e DEMO_SSH_KEY_PATH=/tmp/k ...
    ansible -i inventory/hosts.ini demo -m ping
vm-demo | SUCCESS =>
    changed: false
    ping: pong
```

### 6.3 `ansible-playbook --syntax-check` — both playbooks

```
playbook: provision.yml

playbook: deploy.yml
```

### 6.4 `ansible-playbook deploy.yml --check` as `deploy` — and its limit

```
TASK [Validate image_tag parameter] ***
ok: [vm-demo] => msg: All assertions passed
TASK [Check currently deployed SHA on VM] ***
ok: [vm-demo]
TASK [Extract currently deployed SHA] ***
ok: [vm-demo]
TASK [Notify if release is already deployed] ***      skipping: [vm-demo]
TASK [Early exit on duplicate release deployment] *** skipping: [vm-demo]
TASK [Inspect the existing compose network] ***       skipping: [vm-demo]
TASK [Refuse to deploy onto a network created before ip_range was added] ***
fatal: [vm-demo]: FAILED! =>
    assertion: pos_network.rc != 0 or '172.30.0.128/25' in pos_network.stdout
    evaluated_to: false
    msg: The srisurart-pos_default network on vm-demo predates the ip_range in docker-compose.yml
        (). Nothing was changed. ...
PLAY RECAP ***
vm-demo : ok=3 changed=0 unreachable=0 failed=1 skipped=2 rescued=0 ignored=0
```

🔴 **That failure is a false positive and must not be read as pre-flight item 4 failing.**
`ansible.builtin.command` does not support check mode, so *Inspect the existing compose network* is
skipped, `pos_network.stdout` is the empty string, and the assert cannot pass — note the empty
`()` in the message where the IPAM JSON should be. The real network was read directly and **does**
carry `ip_range` (§1, §4 item 4).

Starting past the assert (`--start-at-task="Copy docker-compose base configuration"`) reaches the
next `command`-dependent task and stops the same way:

```
TASK [Copy docker-compose base configuration] ***  changed: [vm-demo]
TASK [Copy VM Compose override configuration] ***  ok: [vm-demo]
TASK [Copy Nginx configuration] ***                changed: [vm-demo]
TASK [Copy Postgres initialization scripts] ***    ok: [vm-demo]
TASK [Check for the etcd-init.sh directory Docker created on earlier deploys] *** ok: [vm-demo]
TASK [Read the etcd-init image from the compose configuration] *** skipping: [vm-demo]
TASK [Remove the Docker-created etcd-init.sh directory and its root-owned parent] *** fatal
```

**Conclusion to carry forward: `--check` can validate connectivity, the inventory, `ANSIBLE_CONFIG`,
the `assert`/`slurp`/`stat`/`copy` tasks and the diffs — and nothing past the first `command` task.
It cannot pre-prove a deploy.** Two useful facts fell out of it anyway: `vm.override.yml` on the VM
is already current (`ok`) while `docker-compose.yml` and `nginx.conf` differ (`changed`), and the
`when: etcd_init_path.stat.isdir` branch was taken, independently confirming §9's etcd finding.

### 6.5 `ansible-playbook provision.yml --check --diff` as `cloud`

Run with `--start-at-task="Create application directories under /opt/pos"` (skips the apt/Docker
install block, which is irrelevant on an already-provisioned host) and **without** `DEMO_ENV_FILE`:

```
TASK [Create application directories under /opt/pos] ***
ok: [vm-demo] => (item=/opt/pos)
ok: [vm-demo] => (item=/opt/pos/docker)
changed: [vm-demo] => (item=/opt/pos/docker/etcd)
ok: [vm-demo] => (item=/opt/pos/docker/nginx)
ok: [vm-demo] => (item=/opt/pos/docker/postgres)
ok: [vm-demo] => (item=/opt/pos/docker/postgres/init)
changed: [vm-demo] => (item=/opt/pos/scripts)
TASK [Install the ops scripts the VM runs (Slice 23 /] ***
changed: [vm-demo] => (item=backup-db.sh)
changed: [vm-demo] => (item=restore-db.sh)
changed: [vm-demo] => (item=measure-container-rss.sh)
TASK [Write server .env configuration (0600 mode)] ***   skipping: [vm-demo]
TASK [Create backup directory (0700 mode, Slice 23 /] ***
--- before
+++ after
     path: /opt/pos/backups
-    state: absent
+    state: directory
TASK [Configure daily database backup cron job (Slice 23 /] ***
--- before: crontab for user "deploy"
+++ after: crontab for user "deploy"
@@ -0,0 +1,2 @@
+#Ansible: Srisurart POS Daily Database Backup
+0 3 * * * /opt/pos/scripts/backup-db.sh /opt/pos/backups >>/opt/pos/backups/backup-cron.log 2>&1
PLAY RECAP ***
vm-demo : ok=5 changed=4 unreachable=0 failed=0 skipped=1 rescued=0 ignored=0
```

(The three-script loop and the cron log path are #346's change on `fix/346-ops-scripts-install`; a
run from `main` shows only `backup-db.sh` and `>/dev/null 2>&1`.) `failed=0`, and the `.env` task
skipping confirms §5's safety claim.

---

## 7. The deploy — every line, in order, for the owner to run

Run from **`D:\Beestation\Sri_POS\Flutter`** in Git Bash, with the VPN up. Every command is a single
line; nothing here prints a secret. Two shell variables are set once:

```bash
export ANS='alpine/ansible@sha256:22227b578da3371267201879f44de86569e9b531db536e1d9d2b83aed35b6cfc'
export REPO='D:\Beestation\Sri_POS\Flutter'
```

### Step 0 — pick and verify the SHA (never guess)

```bash
git fetch origin
git rev-parse origin/main
gh run list --branch main --limit 6 --json name,headSha,conclusion -q '.[] | [.name,.headSha,.conclusion] | @tsv'
bash deploy/scripts/verify-ghcr-tags.sh "$(git rev-parse origin/main)"
```

Proceed only when **Server CI and Flutter CI are both `success`** for that SHA and
`verify-ghcr-tags.sh` prints *both server and web images … are verified*. Then:

```bash
export TAG="$(git rev-parse origin/main)"     # expected today: cd8989b44912076aaa93b347d62c7eaf1530fa82
export OLDTAG=325bf802641372b307c791363e890a1cb01a5e5f
```

### Step 1 — confirm reachability (read-only)

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v "$REPO:/work" -v 'C:\Users\nuima\.ssh:/hostssh:ro' -w /work/deploy/ansible -e ANSIBLE_CONFIG=/work/deploy/ansible/ansible.cfg -e DEMO_SSH_HOST=172.30.58.20 -e DEMO_SSH_USER=deploy -e DEMO_SSH_KEY_PATH=/tmp/k "$ANS" sh -c 'cp /hostssh/deploy_ed25519 /tmp/k; chmod 600 /tmp/k; ansible -i inventory/hosts.ini demo -m ping'
```

Expect `SUCCESS` / `ping: pong`. If it says `config file = None`, `ANSIBLE_CONFIG` was dropped —
fix that before going on (§2).

### Step 2 — record the "before" state (read-only, keep the output for the ticket)

```bash
ssh -i ~/.ssh/deploy_ed25519 -o IdentitiesOnly=yes deploy@172.30.58.20 'cat /opt/pos/.current_sha; docker ps --format "{{.Names}}|{{.Image}}|{{.Status}}"; docker network inspect srisurart-pos_default --format "{{json .IPAM.Config}}"'
```

### Step 3 — 🛑 clear the blocker: re-provision with the current `DEMO_ENV_FILE`

`$DEMO_ENV_FILE` is the multi-line content the owner holds from #336. **Do not paste it into a
command line, a PR, a log or this file.** Put it in a local file outside the repo and read it in.
`.gitignore` does not protect a path you invent, so keep it out of the repo tree entirely:

```bash
export DEMO_ENV_FILE="$(cat "$HOME/.ssh/demo.env")"
```

Dry-run first (writes nothing; the `.env` task must now report **changed**, not `skipping`):

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v "$REPO:/work" -v 'C:\Users\nuima\.ssh:/hostssh:ro' -w /work/deploy/ansible -e ANSIBLE_CONFIG=/work/deploy/ansible/ansible.cfg -e DEMO_SSH_HOST=172.30.58.20 -e DEMO_SSH_USER=cloud -e DEMO_SSH_KEY_PATH=/tmp/k -e DEMO_ENV_FILE "$ANS" sh -c 'cp /hostssh/mob04-SriStore /tmp/k; chmod 600 /tmp/k; ansible-playbook -i inventory/hosts.ini provision.yml --check'
```

> ⚠️ Do **not** add `--diff` to this one. `--diff` prints the file it would write, and that file is
> every secret on the VM. The check run above is enough: the recap tells you the task is `changed`.

Then the real run (this is the first owner-only state change):

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v "$REPO:/work" -v 'C:\Users\nuima\.ssh:/hostssh:ro' -w /work/deploy/ansible -e ANSIBLE_CONFIG=/work/deploy/ansible/ansible.cfg -e DEMO_SSH_HOST=172.30.58.20 -e DEMO_SSH_USER=cloud -e DEMO_SSH_KEY_PATH=/tmp/k -e DEMO_ENV_FILE "$ANS" sh -c 'cp /hostssh/mob04-SriStore /tmp/k; chmod 600 /tmp/k; ansible-playbook -i inventory/hosts.ini provision.yml'
```

Verify the blocker is gone — **key names only, never values**:

```bash
ssh -i ~/.ssh/mob04-SriStore -o IdentitiesOnly=yes cloud@172.30.58.20 'sudo -n grep -cE "^K6_REMOTE_WRITE_BASIC_AUTH_(USER|PASSWORD)=" /opt/pos/.env; sudo -n stat -c "%A %U:%G %n" /opt/pos/.env'
```

Expect `2` and `-rw------- deploy:deploy /opt/pos/.env`. **If it prints `0`, stop** — step 4 will
fail at the first Compose call (§5).

> 🔴 **Volumes bake some secrets in at first bootstrap** (`pgdata`, `etcd-data`, `nginx-auth` —
> `ticket-336-env-secrets.md` §4). A changed `POSTGRES_PASSWORD` / `ETCD_ROOT_PASSWORD` in `.env`
> does **not** re-key an existing volume: Postgres will refuse the app login and `etcd-init` will
> fail with `root cannot authenticate` (07 §8). If step 4 fails that way, it is this, not a bug —
> report it and stop; re-keying a volume is a separate decision, not a step to improvise at 2 a.m.

### Step 4 — deploy

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v "$REPO:/work" -v 'C:\Users\nuima\.ssh:/hostssh:ro' -w /work/deploy/ansible -e ANSIBLE_CONFIG=/work/deploy/ansible/ansible.cfg -e DEMO_SSH_HOST=172.30.58.20 -e DEMO_SSH_USER=deploy -e DEMO_SSH_KEY_PATH=/tmp/k "$ANS" sh -c "cp /hostssh/deploy_ed25519 /tmp/k; chmod 600 /tmp/k; ansible-playbook -i inventory/hosts.ini deploy.yml -e image_tag=$TAG"
```

No `force_redeploy`: `.current_sha` is `8e873cd…`, so the duplicate-release check passes through.
Expect a rolling `api-1 → api-2 → api-3`, the `nginx -t` validation, the Nginx force-recreate, then
`Verify cluster readiness via Nginx (GET /health/ready)` and `Record deployed SHA`.
Allow ~10–20 minutes; the first `pull` on this VM is large.

### Step 5 — prove `/health/ready` and `.current_sha` (AC 2)

```bash
ssh -i ~/.ssh/deploy_ed25519 -o IdentitiesOnly=yes deploy@172.30.58.20 'curl -sk -o /dev/null -w "health_ready=%{http_code}\n" https://127.0.0.1/health/ready; curl -sk https://127.0.0.1/health/ready; echo; echo -n "current_sha="; cat /opt/pos/.current_sha; docker ps --format "{{.Names}}|{{.Image}}|{{.Status}}"'
```

Pass = `health_ready=200`, `.current_sha` equals `$TAG`, and all three `api-*` images carry `$TAG`.
🔴 `/health/ready` does **not** touch etcd (`health.controller.ts:48-68`) — a 200 is not proof the
whole stack is up. Add:

```bash
ssh -i ~/.ssh/deploy_ed25519 -o IdentitiesOnly=yes deploy@172.30.58.20 'ls -la /opt/pos/docker/etcd; cd /opt/pos && IMAGE_TAG=$(cat .current_sha) docker compose -f docker-compose.yml -f vm.override.yml logs --tail 30 etcd-init'
```

`etcd-init.sh` must now be a **file** (`-rwxr-xr-x deploy`), not a directory, and the log must be
non-empty (07 §7).

### Step 6 — Grafana, checked **separately** from the playbook's exit code (AC 4)

Pre-flight item 6: the monitoring block's `rescue` only warns, so a green recap says nothing here.
This is its own tick.

```bash
ssh -i ~/.ssh/deploy_ed25519 -o IdentitiesOnly=yes deploy@172.30.58.20 'curl -s -o /dev/null -w "prometheus=%{http_code}\n" http://127.0.0.1:9090/-/healthy; curl -s -o /dev/null -w "grafana=%{http_code}\n" http://127.0.0.1:3000/api/health; curl -s http://127.0.0.1:3000/api/health; echo; docker ps --filter name=grafana --filter name=prometheus --filter name=node-exporter --format "{{.Names}}|{{.Status}}"'
```

Pass = `prometheus=200`, `grafana=200`, Grafana's JSON `"database": "ok"`, all three containers
healthy. Then look at it by eye — a 200 from `/api/health` does not mean the dashboard has data:

```bash
ssh -i ~/.ssh/deploy_ed25519 -o IdentitiesOnly=yes -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 deploy@172.30.58.20
```

…then open `http://localhost:3000` (login `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` from
`.env`) and confirm the *POS Overview* dashboard draws. If the playbook printed the monitoring
WARNING, read it — and remember re-running the same tag stops at the duplicate-release check, so a
monitoring-only retry needs `-e force_redeploy=true` (a full POS rollout) or the next release.

---

## 8. The rollback drill, and getting back (AC 3)

Real rollback is the playbook, **not** `pos-deploy.sh` (D9 item 5 — that one needs to be user
`deploy` via the runner's sudoers, which D9 cut). `force_redeploy=true` is **mandatory** here:
without it the play would exit early whenever the target equals `.current_sha`, and it costs nothing
when it does not.

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v "$REPO:/work" -v 'C:\Users\nuima\.ssh:/hostssh:ro' -w /work/deploy/ansible -e ANSIBLE_CONFIG=/work/deploy/ansible/ansible.cfg -e DEMO_SSH_HOST=172.30.58.20 -e DEMO_SSH_USER=deploy -e DEMO_SSH_KEY_PATH=/tmp/k "$ANS" sh -c "cp /hostssh/deploy_ed25519 /tmp/k; chmod 600 /tmp/k; ansible-playbook -i inventory/hosts.ini deploy.yml -e image_tag=$OLDTAG -e force_redeploy=true"
```

Confirm it landed:

```bash
ssh -i ~/.ssh/deploy_ed25519 -o IdentitiesOnly=yes deploy@172.30.58.20 'curl -sk -o /dev/null -w "health_ready=%{http_code}\n" https://127.0.0.1/health/ready; cat /opt/pos/.current_sha; docker ps --format "{{.Names}}|{{.Image}}" | grep api-'
```

Then go forward again, which is the same command with `$TAG`:

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v "$REPO:/work" -v 'C:\Users\nuima\.ssh:/hostssh:ro' -w /work/deploy/ansible -e ANSIBLE_CONFIG=/work/deploy/ansible/ansible.cfg -e DEMO_SSH_HOST=172.30.58.20 -e DEMO_SSH_USER=deploy -e DEMO_SSH_KEY_PATH=/tmp/k "$ANS" sh -c "cp /hostssh/deploy_ed25519 /tmp/k; chmod 600 /tmp/k; ansible-playbook -i inventory/hosts.ini deploy.yml -e image_tag=$TAG -e force_redeploy=true"
```

and re-run §7 step 5 and step 6.

Three things to know before the drill:

* **Schema does not roll back** (07 §6, expand/contract). `$OLDTAG` here is 2 commits behind `$TAG`
  with no contracting migration between them, which is why it is a safe drill target. Rolling back
  across a column drop/rename is a different operation.
* **The playbook and the copied config come from *your* checkout, not from `$OLDTAG`.** A manual
  rollback re-copies today's `docker-compose.yml` / `nginx.conf` / Postgres init while running the
  old *image*. The automatic rollback in `pos-deploy.sh` checks out the release first and so does not
  have this skew. For a 2-commit drill it is harmless; for a real rollback across a compose change,
  `git checkout $OLDTAG -- server/docker-compose.yml deploy/ deploy/ansible/` first, or check the
  whole tree out.
* **`8e873cd` is not the drill target** even though it is what the VM runs today: its web image
  predates #342, so it serves the offline build instead of the server-mode one (§4 item 5).

---

## 9. What remains open after §7–§8, and other findings

**#343's own ACs — all five still open.** Nothing may be ticked from this document; it is a
pre-flight, not a run. When the owner completes §7 and §8, ACs 1–4 can be ticked with the pasted
output, and AC 5 ("every command used is recorded in `docs/handoff_log/`") is satisfied by this file
plus that output.

**Found read-only, worth knowing:**

1. **`/opt/pos/docker/etcd` is root-owned and `etcd-init.sh` is a *directory*** —
   `drwxr-xr-x root root` containing `drwxr-xr-x root root etcd-init.sh`. That is exactly the bug in
   07 §7 ("etcd has no auth on a VM deployed before the `etcd-init` fix"): `etcd-init` ran
   `sh <directory>`, exited 0 silently, and **auth was never enabled on this etcd**. `deploy.yml`
   repairs it (`rmdir` through a root container, then copies the script, enables auth and asserts an
   anonymous read is refused) — so §7 step 4 fixes it, and §7 step 5's second command is how you
   confirm it. Until then, treat the VM's etcd as unauthenticated.
2. **`/opt/pos/scripts` and `/opt/pos/backups` do not exist and `crontab -l -u deploy` is empty** —
   no database backup has ever been scheduled on `mob04`. That is #346; see
   [`ticket-346-backup-script-install.md`](ticket-346-backup-script-install.md) round 2. `provision.yml`
   in §7 step 3 creates all three.
3. **`CORS_ORIGINS` / `PLATFORM_ADMIN_IPS` are not wired through Compose at all** — §5's callout.
   Lane A reported it at #335; it needs an owner decision, not a workaround here.
4. **`--check` is near-useless past the first `command` task** in these playbooks (§6.4). If future
   work wants a real dry-run gate, that needs `check_mode: false` + `changed_when` on the read-only
   `command` tasks, which is a design change, not a flag.
5. **#67 (self-hosted runner) is still not installed**, which is why this is a manual Ansible run at
   all. The `Deploy (demo)` workflow runs on recent `main` commits show `cancelled` — jobs queued
   for a runner that is not there.

**Territory note.** Lane C owns `.github/workflows/flutter.yml`, `deploy/ansible/`,
`deploy/scripts/` and the runbooks. Nothing in `server/src/`, `nginx.conf`, `deploy/prometheus/` or
`deploy/grafana/` was touched by this ticket.
