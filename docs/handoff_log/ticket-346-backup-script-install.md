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
