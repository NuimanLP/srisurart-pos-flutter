# Ticket #363 — `ops.backup-offsite` — mechanism built, not wired

**Date:** 2026-09-21
**Branch:** `feat/363-backup-offsite`
**Parent:** #288 (closed, but its "backups leave the VM daily" AC is unticked) · found during #346

## Owner decision this session worked to

2026-09-21: build the offsite-upload path in code as a pluggable destination, but do **not**
wire real credentials yet. The ACs that require a real upload and a real restore from outside the
VM stay open. This session does not decide a destination, does not create any credential, and does
not claim VM-side proof it does not have.

## What was wrong

`deploy/scripts/backup-db.sh` dumped, gzip'd, checksummed and pruned locally, then stopped —
`grep -nE 'scp|rsync|aws |s3|rclone|curl -T|sftp|supabase'` over it returned nothing
(`ticket-346-backup-script-install.md` recorded this first). #288's own AC "ไฟล์ backup ออกนอก VM
อัตโนมัติทุกวัน" was still `[ ]` on a **closed** issue. A backup that never leaves the machine it is
protecting does not survive the failure it exists for.

## What changed — `deploy/scripts/backup-db.sh`

Added an `offsite_upload()` step, called after the local checksum and before pruning:

- **Mechanism:** `rclone copyto`. Chosen because rclone itself is the pluggable part — the same
  code path works against Supabase Storage, any S3-compatible bucket, or SFTP to a lab machine
  (the exact three candidates #363 AC1 asks the owner to choose between), selected entirely by
  which remote is defined in `rclone.conf`. No S3-specific or Supabase-specific code was written.
- **New env vars** (both unset by default = offsite disabled):
  - `BACKUP_RCLONE_REMOTE` — `remote:path`, e.g. `supabase-backup:pos-backups/mob04`.
  - `BACKUP_RCLONE_CONFIG` — path to `rclone.conf`. Must live outside the repo; not committed
    anywhere. Defaults to rclone's own lookup (`$HOME/.config/rclone/rclone.conf`).
- **Cannot silently no-op:** if `BACKUP_RCLONE_REMOTE` is unset, if `rclone` is not installed, if
  `BACKUP_RCLONE_CONFIG` is set but missing, or if the `rclone copyto` call itself fails, the
  script logs a `::error::` line naming exactly what's wrong and the run's **final exit code is
  non-zero**. The local `.sql.gz`/`.sha256` are still produced and kept — only the *offsite*
  promise is reported as failed. This means: on `mob04` today (offsite genuinely unconfigured),
  every nightly cron run will show a loud failure in `backup-cron.log` from now until the owner
  wires a real destination. Nothing pages on this today (#346), so the only effect is visibility —
  which is the point.
- **Prune never deletes an unconfirmed upload:** on successful upload of both the dump and its
  checksum, the script writes `${BACKUP_FILE}.uploaded` (mode 0600). While `BACKUP_RCLONE_REMOTE`
  is unset, local pruning is byte-for-byte the same age-based prune the script had before this
  ticket (no regression, no unbounded disk growth while "not configured yet" persists indefinitely
  — which, per the owner decision above, it will for a while). Once `BACKUP_RCLONE_REMOTE` is set,
  pruning changes to: only remove a backup+checksum+marker triple once the `.uploaded` marker
  exists and is past `BACKUP_KEEP_DAYS`; an old backup with no marker is kept and logged with
  `::warning::` instead of deleted.
- **Credentials never in logs:** only the remote *name* (`BACKUP_RCLONE_REMOTE`, not a secret — the
  secret lives in `rclone.conf`) is ever echoed. `rclone.conf`'s contents are never read or printed
  by this script.
- `restore-db.sh` is unchanged. Restoring from an offsite copy is `rclone copy <remote>/<file> .`
  followed by the existing `restore-db.sh` — no new code path was needed there.

## Dry-run proof (this session, local dev box — not the VM)

No cloud credentials exist yet (by design), so proof used a stub `rclone` binary (prepended to
`PATH`) that performs a real `copyto` to a plain local directory standing in for the offsite
destination, plus a stub `pg_dump`/`docker` so the script's existing dump path runs without a real
Postgres. Four scenarios, each run against `deploy/scripts/backup-db.sh` unmodified:

1. **Offsite unset (today's real `mob04` state).** Exit code 1. Local `.sql.gz`/`.sha256` created
   and kept. Log: `::error::OFFSITE BACKUP DISABLED — BACKUP_RCLONE_REMOTE is not set...`.
2. **`BACKUP_RCLONE_REMOTE` set, `rclone` missing from `PATH`.** Exit code 1. Log:
   `::error::OFFSITE BACKUP FAILED — ... 'rclone' binary is not installed...`.
3. **`BACKUP_RCLONE_REMOTE` set, stub `rclone` simulates a failed upload.** Exit code 1. Stub log
   shows the real `copyto <local-file> <remote>/<file>` invocation, then a simulated failure. No
   `.uploaded` marker written.
4. **`BACKUP_RCLONE_REMOTE` set, stub `rclone` succeeds**, with two pre-seeded old backup pairs in
   the target directory (one with an `.uploaded` marker, one without, both dated 10 days old with
   `BACKUP_KEEP_DAYS=7`). Result: exit code 0; today's new backup + checksum land in both the local
   directory and the fake "offsite" directory; the pre-seeded confirmed pair is pruned; the
   pre-seeded unconfirmed pair is kept with `::warning::Keeping ... its offsite upload was never
   confirmed.`.

Full command transcripts for all four scenarios are pasted in the PR description.

## Shellcheck

`docker run --rm koalaman/shellcheck:stable deploy/scripts/backup-db.sh` — one pre-existing
`SC2012` info-level note (`ls -lh | awk` on line ~122, predates this ticket, not touched) and
**nothing new** from the added code. `bash -n` also passes.

## Docs

- `docs/Backend_design/07_CICD_DEPLOY.md` — new §7a documents the env vars, the loud-failure
  behavior, the prune rule, and the proof, plus lists the ACs still open. The §7 runbook row for
  "VM พัง/ย้ายเครื่อง" now points at §7a instead of "ยังไม่มีเอกสาร".
- `CLAUDE.md` — the #363 entry under "Still open (phase 1)" now states what was built vs. what
  remains owner-only.

## #288 correction

Posted a comment on #288 stating its "ไฟล์ backup ออกนอก VM อัตโนมัติทุกวัน" AC is still unticked
despite the issue being closed, linking this PR as the mechanism (not the proof), and proposing the
owner consider reopening it or accepting the tracked gap lives on in #363. Nothing on #288 was
ticked or edited otherwise.

## What is still open — do not claim otherwise

- **#363 AC1** — owner has not chosen Supabase storage / S3-compatible / rsync-to-lab-machine, and
  no credential exists anywhere.
- **#363 AC2** — no real upload has ever left a VM. `BACKUP_RCLONE_REMOTE` is unset on `mob04`.
- **#363 AC3** — no restore from an offsite copy has been proven.
- `rclone` is not installed on `mob04`; `provision.yml`/`deploy.yml` do not install it (not needed
  until offsite is actually turned on).
- This PR uses `References #363`, not `Closes #363`.
