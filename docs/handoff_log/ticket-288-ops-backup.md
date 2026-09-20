# Handoff Log: Ticket #288 (Slice 23 — `ops.backup`)

**Date**: 2026-09-20  
**Lane**: C (`team/3`, `PattaraponKitcharoen`)  
**Branch**: `feat/288-ops-backup`  
**Spec References**: [`08_PHASE2_SPEC.md §16, §17`](../Backend_design/08_PHASE2_SPEC.md), [`09_PHASE2_LANES.md §3`](../Backend_design/09_PHASE2_LANES.md), [`ADR-0013`](../Backend_design/adr/0013-cicd-toolchain.md)

---

## 1. Overview of Changes

Delivered the automated daily PostgreSQL cluster backup and recovery substrate satisfying Slice 23 (#288):

1. **Backup Tool (`deploy/scripts/backup-db.sh`)**:
   - Dumps PostgreSQL cluster database using `pg_dump -U postgres --create --clean --if-exists pos`.
   - **Preserves Role Ceiling Invariant (#213):** Plain single-database `pg_dump` drops cluster-wide `pg_db_role_setting` catalog entries. Appends the exact SQL payload (`ALTER ROLE pos_app IN DATABASE pos SET statement_timeout = '25s'; ALTER ROLE pos_app IN DATABASE pos SET idle_in_transaction_session_timeout = '5s';`) ensuring any restore directly restores the transaction ceiling without requiring migration re-runs.
   - Gzips output with `-9` compression to `/opt/pos/backups/pos_backup_YYYYMMDD_HHMMSSZ.sql.gz`.
   - Computes `.sha256` checksum file.
   - Enforces `0600` permissions on backup archive and checksum files.
   - Purges backups older than `BACKUP_KEEP_DAYS` (default 7 days).

2. **Restore Tool (`deploy/scripts/restore-db.sh`)**:
   - Validates archive against its `.sha256` checksum before execution.
   - Terminates existing connections to target database to prevent lockouts during database drop/recreate.
   - Streams decompressed SQL into PostgreSQL.
   - Queries `SHOW statement_timeout` and `SHOW idle_in_transaction_session_timeout` as `pos_app` to assert `25s` and `5s` values are active.

3. **Ansible Provisioning (`deploy/ansible/provision.yml`)**:
   - Creates `/opt/pos/backups` directory with `0700` mode, owned by `deploy:deploy`.
   - Configures daily backup cron job `/etc/cron.d/pos-backup` at 03:00 AM.

4. **Validation & Automated Tests**:
   - Added scripts to `REQUIRED_FILES` in `deploy/scripts/validate.sh`.
   - Added E2E test suite in `server/test/backup-restore.e2e-spec.ts` verifying script permissions, `bash -n` syntax, `warnIfRoleTimeoutsDiffer` zero-warning invariant, and SQL payload containment.

---

## 2. Verification Results

- `server/`: `pnpm check` (oxlint + tsc) passed with 0 errors and 0 warnings (35ms).
- `server/`: `pnpm vitest run --config ./vitest.config.e2e.ts test/backup-restore.e2e-spec.ts` passed 6/6 tests (17ms).
- `deploy/`: `bash deploy/scripts/validate.sh` passed all checks including containerized Ansible playbook syntax.
