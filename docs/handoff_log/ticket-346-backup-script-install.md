# Ticket #346 — install the backup script targeted by cron

**Date:** 2026-09-20
**Lane:** C
**Branch:** `fix/346-backup-scripts`
**Base:** `origin/main` at `8de89bb`

## Root cause and scope

`deploy/ansible/provision.yml` created `/opt/pos/backups` and a daily cron entry that runs
`/opt/pos/scripts/backup-db.sh`, but it neither created `/opt/pos/scripts` nor copied the script.
`deploy/ansible/deploy.yml` also does not install this file. The cron command discarded both stdout
and stderr, so the missing executable produced no durable command output.

The surgical fix stays with the playbook that owns the cron: provisioning now creates
`/opt/pos/scripts` and copies only `deploy/scripts/backup-db.sh` there as `deploy:deploy`, mode
`0755`, before installing the cron entry. It does not copy unrelated runner/deploy scripts and does
not change the cron path.

## Evidence from #288

Issue #288 was closed by PR #333, but the recorded verification was offline only:

- `pnpm check`
- six Vitest assertions in `server/test/backup-restore.e2e-spec.ts`
- `bash deploy/scripts/validate.sh`

Those tests check script presence, syntax and embedded role-setting SQL; they do not execute a
backup or restore on `mob04`. No VM archive, restore transcript or off-VM copy was attached to #288
or PR #333. This ticket does not silently absorb #288's broader off-VM retention and restore-drill
requirements.

## VM reachability and remaining acceptance criteria

The current session cannot reach `mob04`: `DEMO_SSH_HOST`, `DEMO_SSH_USER` and
`DEMO_SSH_KEY_PATH` are absent, `ansible` is not installed, and #335 D9 requires the owner to connect
the VPN for VM work. No VM result is claimed.

When access is available, capture these exact checks and redact host/key details:

```bash
# Pre-fix evidence, before applying the playbook
crontab -l
stat /opt/pos/scripts/backup-db.sh
sudo journalctl -u cron --since '2 days ago' --no-pager | grep -F '/opt/pos/scripts/backup-db.sh'
# Ubuntu/Debian fallback when cron is logged to syslog instead of the journal
sudo grep -F '/opt/pos/scripts/backup-db.sh' /var/log/syslog
sudo -u deploy /opt/pos/scripts/backup-db.sh /opt/pos/backups

# Apply from deploy/ansible/ using the provisioning credential; become is required
ansible-playbook provision.yml

# Post-fix proof
stat -c '%U:%G %a %n' /opt/pos/scripts/backup-db.sh
sudo -u deploy /opt/pos/scripts/backup-db.sh /opt/pos/backups
find /opt/pos/backups -maxdepth 1 -type f -name 'pos_backup_*.sql.gz*' -printf '%TY-%Tm-%TdT%TH:%TM:%TS %s %p\n'
gzip -t /opt/pos/backups/pos_backup_<timestamp>.sql.gz
sha256sum -c /opt/pos/backups/pos_backup_<timestamp>.sql.gz.sha256
```

Still blocked until that run:

- a VM log proving the cron target was missing before the fix;
- a successful real backup run as `deploy`;
- a timestamped non-empty `.sql.gz` and matching `.sha256` on the VM.

Therefore the PR must use `References #346`, not `Closes #346`.

## Same-shape playbook audit

The audit was limited to `deploy/ansible/*.yml`:

- The backup cron was the only recurring command found that discarded both output streams and had
  no paired assertion or warning.
- Monitoring failures are allowed to keep the POS release green, but `deploy.yml` emits an explicit
  warning with the failed result; this is degraded-but-visible, not silent.
- The `.current_sha` read uses `ignore_errors: true` so a fresh VM can deploy, and network inspection
  uses `failed_when: false` before a paired assertion. These broad catches could also mask permission,
  I/O or Docker-daemon errors as missing, but they are pre-existing and were reported rather than
  changed outside #346.
- The historical missing `etcd-init.sh` bind source had the same absent-file shape; `deploy.yml`
  already repairs and verifies it explicitly.

## Offline verification log

Run from `C:\Users\nuima\worktrees\srisurart-pos-346`:

- `git diff --check` — passed with no output.
- `bash deploy/scripts/validate.sh` — not a product failure; the Windows `bash` command resolved to
  an unconfigured WSL shim and failed with `execvpe(/bin/bash) failed: No such file or directory`.
- `C:\Program Files\Git\bin\bash.exe deploy/scripts/validate.sh` — passed. This verified both
  Compose merges, `nginx -t`, Prometheus configuration, required deploy files, and containerized
  `ansible-playbook --syntax-check` for both `provision.yml` and `deploy.yml`.
- `pnpm vitest run --config ./vitest.config.e2e.ts test/backup-restore.e2e-spec.ts` — not run:
  `pnpm` is not installed and `server/node_modules` is absent in this isolated worktree. No package
  installation was needed for the changed Ansible/docs surface; the deploy validator above is the
  repository-supported check for that surface.

The VM commands above remain unrun until VPN and provisioning credentials are available.

## Review closeout

- Standards reviewer: pass; no documented-standard violations or baseline smells.
- Spec reviewer: found that the first VM checklist lacked the cron daemon log required by AC1.
  Added both `journalctl -u cron` and Ubuntu/Debian syslog capture commands before the manual
  missing-file reproduction.
- AC1 and AC3 remain intentionally open pending owner VPN and VM credentials; this is reflected in
  the handoff and PR wording rather than hidden by an auto-close keyword.

---

# Round 2 — 2026-09-21: read-only VM evidence, and what it changes

**Branch:** `fix/346-ops-scripts-install` · **Base:** `origin/main` at `cd8989b`
**Access:** owner on VPN; `mob04` = `172.30.58.20`. Two accounts exist and they are **not**
interchangeable — see [`ticket-343-vm-deploy.md`](ticket-343-vm-deploy.md) §3. Everything below was
**read-only**; this session changed no VM state.

## AC1: the premise was wrong, and the truth is quieter

AC1 asks for a log proving cron called a file that does not exist. That log cannot exist:

```
$ crontab -l                       # as deploy
no crontab for deploy
$ sudo -n crontab -l -u deploy     # as cloud
no crontab for deploy
$ sudo -n journalctl -u cron --no-pager -n 15
... only (root) CMD (cd / && run-parts --report /etc/cron.hourly) and e2scrub_all
$ ls -la /opt/pos/scripts
ls: cannot access '/opt/pos/scripts': No such file or directory
$ ls -la /opt/pos/backups
ls: cannot access '/opt/pos/backups': No such file or directory
```

`ansible-playbook provision.yml --check --diff` agrees from the other side:

```
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
```

`@@ -0,0` — the crontab is empty. **No backup job was ever scheduled on `mob04`**, because
`provision.yml` has not been re-run since #288 added the cron task. The failure mode is not "cron
fails nightly and hides it"; it is "there is nothing to fail", which is worse, because a missing
cron entry emits no signal at all. Round 1's fix and this round's are still the right fixes — the
ticket merely described the symptom it *would* have had.

## What round 2 changes

1. The single-file copy becomes a `loop` over the three scripts whose runtime **is** the VM:
   `backup-db.sh` (cron target), `restore-db.sh` (#288's recovery half — useless on the day it is
   needed if it lives only in the repo, and #288's AC cannot be shown on the VM without it), and
   `measure-container-rss.sh` (#184 runbook step 2.2 invokes it by absolute path).
   Excluded on purpose: `pos-deploy.sh` / `runner-job-started.sh` (the owner installs those into
   `/usr/local/bin`, 07 §6.2) and `setup-mob04-runner.sh` / `validate.sh` / `verify-ghcr-tags.sh`
   (repo- and CI-side).
2. The cron redirect `>/dev/null 2>&1` becomes `>>/opt/pos/backups/backup-cron.log 2>&1`. That
   redirect *was* the mechanism this ticket is named after. The prune in `backup-db.sh:108` matches
   only `*_backup_*.sql.gz[.sha256]`, so the log survives it. This is still not an alarm — nothing
   pages on a failed backup.
3. `docs/handoff_log/slice-22-k6-rss-measurement-guide.md` step 2.2 ran
   `sudo ./deploy/scripts/measure-container-rss.sh` after `cd /opt/pos`. `/opt/pos/deploy/` holds
   only `prometheus/` and `grafana/`, so that command could never have worked — the #184 runbook was
   unrunnable as written. Fixed to the absolute `/opt/pos/scripts/…`: the one place `provision.yml`
   installs to and the path the cron already uses.

`provision.yml` stays the installer rather than `deploy.yml`, and that is now measured, not assumed:
`deploy.yml` is `become: false`, `/opt/pos` is `drwxr-xr-x deploy:deploy`, and `cloud` is not in
group `deploy` (`test -w /opt/pos` → not writable). The cost of the choice, stated so nobody is
surprised: **editing one of these scripts in the repo does not reach the VM on the next release —
`provision.yml` must be re-run.**

## Same-shape silent-failure audit, round 2 (AC4)

Round 1's audit stands. Two additions found by running `--check` against the real host:

- **`when: demo_env_content != ""`** (the `.env` task) — running `provision.yml` without
  `DEMO_ENV_FILE` **silently skips** writing `/opt/pos/.env`. That is protective (it is why a re-run
  cannot wipe the VM's secrets; the task reported `skipping` in the `--check` run above) but it is
  also how a stale `.env` survives a re-run unnoticed — which is exactly the state `mob04` is in
  today. `DEMO_SSH_KEY_PUB` has the same shape. The owner must know which mode they are in;
  `ticket-343-vm-deploy.md` says so at the point of use.
- **`/opt/pos/docker/etcd` is still root-owned** — `--check` reported `changed` for that loop item,
  and `ls -la` shows `drwxr-xr-x root root` with `etcd-init.sh` as a **directory**. That is the
  etcd-init bug's residue (07 §7). `deploy.yml` repairs it on the next real deploy; nothing here
  does.

## Is #346 closeable?

**Not by this PR.** AC2 is met in code and proven in `--check`; AC4 is met. AC1 is answered with the
opposite finding, which the owner should accept explicitly rather than have an agent decide. AC3 —
"a backup runs for real and leaves a file" — needs `provision.yml` to actually run on the VM, which
is owner-only under the demo scope. The commands are in
[`ticket-343-vm-deploy.md`](ticket-343-vm-deploy.md) §7. So: `References #346`, not `Closes #346`.
