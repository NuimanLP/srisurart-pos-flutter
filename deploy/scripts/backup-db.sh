#!/usr/bin/env bash
# backup-db.sh — Automated PostgreSQL database backup for Srisurart POS (Slice 23 / #288, ADR-0013, 08_PHASE2_SPEC.md §17).
#
# Generates a timestamped, gzip-compressed PostgreSQL cluster backup using `pg_dump --create`.
# Invariant (#213 / migration 1788652802131): Preserves `pos_app` role-in-database ceiling settings
# (statement_timeout = 25s, idle_in_transaction_session_timeout = 5s) so that after restore,
# DbModule.warnIfRoleTimeoutsDiffer logs zero warnings.
#
# Usage:
#   ./backup-db.sh [backup_dir]
#
# Environment variables:
#   APP_DIR              Application directory (default: /opt/pos, fallback to repo root/server)
#   BACKUP_DIR           Target backup directory (default: $APP_DIR/backups)
#   BACKUP_KEEP_DAYS     Number of days to keep local backups (default: 7)
#   POSTGRES_DB          Database name to dump (default: pos)
#   POSTGRES_USER        Superuser name for pg_dump (default: postgres)
#
# Offsite upload (#363 — the dump above never left the VM before this):
#   BACKUP_RCLONE_REMOTE  rclone remote:path to copy each backup to, e.g. "supabase-backup:pos-backups/mob04".
#                         Unset by default = offsite upload DISABLED. rclone (not this script) is the
#                         pluggable part: the same `rclone copyto` call works against Supabase Storage,
#                         any S3-compatible bucket, or SFTP to a lab machine — whichever the owner
#                         configures as this remote in rclone.conf (#363 AC1, still an owner decision).
#   BACKUP_RCLONE_CONFIG  Path to rclone's config file holding the remote's credentials. Must live
#                         outside this repo (default: rclone's own lookup, $HOME/.config/rclone/rclone.conf).
#                         Never commit this file. See docs/Backend_design/07_CICD_DEPLOY.md §7a.
#
# Offsite upload is NOT optional-and-silent: when BACKUP_RCLONE_REMOTE is unset, or `rclone` is
# missing, or the upload itself fails, this script logs a loud `::error::` and exits non-zero —
# the local .sql.gz/.sha256 are still produced and kept, but the run is NOT reported as a success,
# because a backup that never leaves this VM does not survive the disk failure it exists for (#363).
# While offsite is unconfigured, local pruning below is unchanged (age-based, as before this ticket)
# so an indefinitely-long "not configured yet" period does not fill the disk. Once BACKUP_RCLONE_REMOTE
# is set, pruning switches to only removing backups with a confirmed `.uploaded` marker, so a local
# copy is never deleted before its offsite copy is confirmed to exist.
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/pos}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ ! -d "$APP_DIR" && -d "$REPO_ROOT/server" ]]; then
  APP_DIR="$REPO_ROOT/server"
fi

BACKUP_DIR="${1:-${BACKUP_DIR:-$APP_DIR/backups}}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-7}"
POSTGRES_DB="${POSTGRES_DB:-pos}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"

mkdir -p "$BACKUP_DIR"
chmod 0700 "$BACKUP_DIR"

TIMESTAMP="$(date -u +%Y%m%d_%H%M%SZ)"
BACKUP_FILE="$BACKUP_DIR/${POSTGRES_DB}_backup_${TIMESTAMP}.sql.gz"
CHECKSUM_FILE="${BACKUP_FILE}.sha256"

# Determine compose files if running under docker compose
COMPOSE_ARGS=()
if [[ -f "$APP_DIR/docker-compose.yml" ]]; then
  COMPOSE_ARGS+=(-f "$APP_DIR/docker-compose.yml")
elif [[ -f "$REPO_ROOT/server/docker-compose.yml" ]]; then
  COMPOSE_ARGS+=(-f "$REPO_ROOT/server/docker-compose.yml")
fi

if [[ -f "$APP_DIR/vm.override.yml" ]]; then
  COMPOSE_ARGS+=(-f "$APP_DIR/vm.override.yml")
elif [[ -f "$REPO_ROOT/deploy/compose/vm.override.yml" ]]; then
  COMPOSE_ARGS+=(-f "$REPO_ROOT/deploy/compose/vm.override.yml")
fi

echo "=== Srisurart POS Database Backup ==="
echo "  Timestamp:    $TIMESTAMP"
echo "  Target File:  $BACKUP_FILE"
echo "  Database:     $POSTGRES_DB"

exec_pg_dump() {
  if command -v docker >/dev/null 2>&1 && [[ ${#COMPOSE_ARGS[@]} -gt 0 ]] && docker compose "${COMPOSE_ARGS[@]}" ps --services 2>/dev/null | grep -q postgres; then
    docker compose "${COMPOSE_ARGS[@]}" exec -T postgres pg_dump -U "$POSTGRES_USER" --create --clean --if-exists "$POSTGRES_DB"
  elif command -v pg_dump >/dev/null 2>&1; then
    pg_dump -U "$POSTGRES_USER" --create --clean --if-exists "$POSTGRES_DB"
  else
    echo "::error::Neither active docker compose postgres container nor local pg_dump command found." >&2
    exit 1
  fi
}

echo "Dumping database and appending role ceiling configuration (#213)..."
(
  # 1. Full schema, tables, sequences, data, and constraints
  exec_pg_dump

  # 2. Append role-in-database ceiling settings (#213 / migration 1788652802131)
  # Plain pg_dump does not carry entries from cluster-wide pg_db_role_setting.
  # Appending this ensures any restore directly satisfies DbModule's boot check.
  cat << 'EOF'

-- Role-in-database ceiling settings (#213 / migration 1788652802131)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_app') THEN
    EXECUTE format('ALTER ROLE pos_app IN DATABASE %I SET statement_timeout = %L', current_database(), '25s');
    EXECUTE format('ALTER ROLE pos_app IN DATABASE %I SET idle_in_transaction_session_timeout = %L', current_database(), '5s');
  END IF;
END $$;
EOF
) | gzip -9 > "$BACKUP_FILE"

# Set strict permissions
chmod 0600 "$BACKUP_FILE"

echo "Calculating SHA256 checksum..."
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$BACKUP_DIR" && sha256sum "$(basename "$BACKUP_FILE")" > "$(basename "$CHECKSUM_FILE")")
elif command -v shasum >/dev/null 2>&1; then
  (cd "$BACKUP_DIR" && shasum -a 256 "$(basename "$BACKUP_FILE")" > "$(basename "$CHECKSUM_FILE")")
fi
if [[ -f "$CHECKSUM_FILE" ]]; then
  chmod 0600 "$CHECKSUM_FILE"
fi

BACKUP_SIZE="$(ls -lh "$BACKUP_FILE" | awk '{print $5}')"
echo "  -> Backup created successfully ($BACKUP_SIZE)."

# --- Offsite upload (#363) ---------------------------------------------------------------------
# Copies this run's backup + checksum off the VM via rclone. Never echoes rclone.conf or any
# credential value -- only the configured remote *name* (not a secret; the secret lives in
# rclone.conf) appears in output.
UPLOAD_MARKER="${BACKUP_FILE}.uploaded"

# Copies one file to $BACKUP_RCLONE_REMOTE using the module-level $RCLONE_ARGS (same pattern as
# $COMPOSE_ARGS above for exec_pg_dump). Shared by both copyto calls in offsite_upload() below.
copy_offsite() {
  local file="$1"
  if ! rclone "${RCLONE_ARGS[@]}" copyto "$file" "${BACKUP_RCLONE_REMOTE%/}/$(basename "$file")"; then
    echo "::error::OFFSITE BACKUP FAILED — rclone could not copy $(basename "$file") to '$BACKUP_RCLONE_REMOTE'." >&2
    return 1
  fi
}

offsite_upload() {
  if [[ -z "${BACKUP_RCLONE_REMOTE:-}" ]]; then
    echo "::error::OFFSITE BACKUP DISABLED — BACKUP_RCLONE_REMOTE is not set, so this backup was NOT copied off the VM. This is expected until the owner wires a real destination (#363 AC1; docs/Backend_design/07_CICD_DEPLOY.md §7a). The local backup above was still created and kept. Exiting non-zero only so this stays visible in backup-cron.log." >&2
    return 1
  fi
  if ! command -v rclone >/dev/null 2>&1; then
    echo "::error::OFFSITE BACKUP FAILED — BACKUP_RCLONE_REMOTE is set to '$BACKUP_RCLONE_REMOTE' but the 'rclone' binary is not installed on this host." >&2
    return 1
  fi
  if [[ -n "${BACKUP_RCLONE_CONFIG:-}" && ! -f "$BACKUP_RCLONE_CONFIG" ]]; then
    echo "::error::OFFSITE BACKUP FAILED — BACKUP_RCLONE_CONFIG='$BACKUP_RCLONE_CONFIG' does not exist." >&2
    return 1
  fi
  RCLONE_ARGS=()
  if [[ -n "${BACKUP_RCLONE_CONFIG:-}" ]]; then
    RCLONE_ARGS+=(--config "$BACKUP_RCLONE_CONFIG")
  fi
  echo "Uploading $(basename "$BACKUP_FILE") to '$BACKUP_RCLONE_REMOTE'..."
  copy_offsite "$BACKUP_FILE" || return 1
  if [[ -f "$CHECKSUM_FILE" ]]; then
    copy_offsite "$CHECKSUM_FILE" || return 1
  fi
  echo "  -> Offsite upload confirmed ($BACKUP_RCLONE_REMOTE)."
}

OFFSITE_OK=1
if offsite_upload; then
  OFFSITE_OK=0
  : > "$UPLOAD_MARKER"
  chmod 0600 "$UPLOAD_MARKER"
fi

if [[ "$BACKUP_KEEP_DAYS" -gt 0 ]]; then
  if [[ -n "${BACKUP_RCLONE_REMOTE:-}" ]]; then
    # Offsite is configured: only prune a backup once its own offsite copy is confirmed, so a
    # local copy is never the last copy of data whose upload never succeeded (#363).
    echo "Pruning backups older than $BACKUP_KEEP_DAYS days in $BACKUP_DIR with a confirmed offsite copy..."
    while IFS= read -r -d '' marker; do
      base="${marker%.uploaded}"
      rm -f "$base" "${base}.sha256" "$marker"
    done < <(find "$BACKUP_DIR" -type f -name "${POSTGRES_DB}_backup_*.sql.gz.uploaded" -mtime +"$BACKUP_KEEP_DAYS" -print0)
    while IFS= read -r -d '' stale; do
      if [[ ! -f "${stale}.uploaded" ]]; then
        echo "::warning::Keeping $(basename "$stale") past the ${BACKUP_KEEP_DAYS}-day retention window -- its offsite upload was never confirmed." >&2
      fi
    done < <(find "$BACKUP_DIR" -type f -name "${POSTGRES_DB}_backup_*.sql.gz" -mtime +"$BACKUP_KEEP_DAYS" -print0)
  else
    # Offsite is not configured at all -- prune exactly as before this ticket (age-based, no
    # confirmation concept applies), so an indefinitely-long "not configured yet" period does not
    # fill the disk.
    echo "Pruning backups older than $BACKUP_KEEP_DAYS days in $BACKUP_DIR..."
    find "$BACKUP_DIR" -type f \( -name "${POSTGRES_DB}_backup_*.sql.gz" -o -name "${POSTGRES_DB}_backup_*.sql.gz.sha256" \) -mtime +"$BACKUP_KEEP_DAYS" -exec rm -f {} +
  fi
fi

if [[ "$OFFSITE_OK" -eq 0 ]]; then
  echo "=== Backup Complete (local + offsite) ==="
else
  echo "=== Backup Complete LOCALLY ONLY -- see the OFFSITE BACKUP error above (#363) ==="
  exit 1
fi
