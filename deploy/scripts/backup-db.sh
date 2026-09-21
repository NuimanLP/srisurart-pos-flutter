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
# Offsite upload is OPTIONAL, but never optional-and-silent (owner decision, 2026-09-21):
#   * BACKUP_RCLONE_REMOTE unset/empty  -> offsite is DISABLED. The local dump, checksum and prune
#     run exactly as they did before #363, one `::warning::` line says offsite upload is off, and
#     the script EXITS 0. The nightly cron on mob04 is in this state until the owner picks a
#     destination, and a nightly job that fails every night until then trains everyone to ignore
#     backup-cron.log — which is worse than the honest warning.
#   * BACKUP_RCLONE_REMOTE set, but `rclone` missing / BACKUP_RCLONE_CONFIG missing / `copyto`
#     fails -> loud `::error::` and a NON-ZERO exit. A destination that was configured and then
#     silently failed is the exact bug #363 exists for; do not soften this half.
# Either way the local .sql.gz/.sha256 are produced and kept.
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
# credential value -- only $OFFSITE_LABEL below (the configured remote's name; the secret lives in
# rclone.conf) appears in output.
UPLOAD_MARKER="${BACKUP_FILE}.uploaded"

# What every message below is allowed to print instead of $BACKUP_RCLONE_REMOTE. A named remote
# ("supabase-backup:pos-backups/mob04" — the documented shape, §7a) is printed as-is, but rclone
# also accepts an on-the-fly connection string (":s3,access_key_id=…,secret_access_key=…:bucket"),
# which would put a secret in backup-cron.log. Keep only the part before the first comma.
OFFSITE_LABEL="${BACKUP_RCLONE_REMOTE:-}"
if [[ "$OFFSITE_LABEL" == *,* ]]; then
  OFFSITE_LABEL="${OFFSITE_LABEL%%,*},<redacted>"
fi

# Copies one file to $BACKUP_RCLONE_REMOTE using the module-level $RCLONE_ARGS (same pattern as
# $COMPOSE_ARGS above for exec_pg_dump). Shared by both copyto calls in offsite_upload() below.
copy_offsite() {
  local file="$1"
  if ! rclone "${RCLONE_ARGS[@]}" copyto "$file" "${BACKUP_RCLONE_REMOTE%/}/$(basename "$file")"; then
    echo "::error::OFFSITE BACKUP FAILED — rclone could not copy $(basename "$file") to '$OFFSITE_LABEL'." >&2
    return 1
  fi
}

# Called only when BACKUP_RCLONE_REMOTE is non-empty (see the OFFSITE_STATE block below), so every
# return path here is a *configured* destination failing: all of them are loud and fail the run.
offsite_upload() {
  if ! command -v rclone >/dev/null 2>&1; then
    echo "::error::OFFSITE BACKUP FAILED — BACKUP_RCLONE_REMOTE is set to '$OFFSITE_LABEL' but the 'rclone' binary is not installed on this host." >&2
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
  echo "Uploading $(basename "$BACKUP_FILE") to '$OFFSITE_LABEL'..."
  copy_offsite "$BACKUP_FILE" || return 1
  if [[ -f "$CHECKSUM_FILE" ]]; then
    copy_offsite "$CHECKSUM_FILE" || return 1
  fi
  echo "  -> Offsite upload confirmed ($OFFSITE_LABEL)."
}

# disabled = not configured (exit 0) · ok = uploaded (exit 0) · failed = configured and broken (exit 1).
# "disabled" is reachable ONLY from an empty BACKUP_RCLONE_REMOTE; every other path goes through
# offsite_upload(), so a configured destination can never be skipped quietly.
if [[ -z "${BACKUP_RCLONE_REMOTE:-}" ]]; then
  OFFSITE_STATE=disabled
  echo "::warning::Offsite upload is disabled (BACKUP_RCLONE_REMOTE is not set) — this backup stays on this VM only. Set BACKUP_RCLONE_REMOTE/BACKUP_RCLONE_CONFIG to enable it (#363 AC1; docs/Backend_design/07_CICD_DEPLOY.md §7a)." >&2
elif offsite_upload; then
  OFFSITE_STATE=ok
  : > "$UPLOAD_MARKER"
  chmod 0600 "$UPLOAD_MARKER"
else
  OFFSITE_STATE=failed
fi

if [[ "$BACKUP_KEEP_DAYS" -gt 0 ]]; then
  # Branch on the state decided above, not on the raw env var again: one discriminator, so a future
  # way of disabling offsite cannot leave prune in its age-based mode while offsite is live.
  if [[ "$OFFSITE_STATE" != disabled ]]; then
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
    # The `.uploaded` glob is included so markers left behind by an earlier *configured* run are
    # removed with the dump they describe instead of orphaning in this directory forever; markers
    # did not exist before #363, so this is still "prune as before #363".
    echo "Pruning backups older than $BACKUP_KEEP_DAYS days in $BACKUP_DIR..."
    find "$BACKUP_DIR" -type f \( -name "${POSTGRES_DB}_backup_*.sql.gz" -o -name "${POSTGRES_DB}_backup_*.sql.gz.sha256" -o -name "${POSTGRES_DB}_backup_*.sql.gz.uploaded" \) -mtime +"$BACKUP_KEEP_DAYS" -exec rm -f {} +
  fi
fi

case "$OFFSITE_STATE" in
  ok)       echo "=== Backup Complete (local + offsite) ===" ;;
  disabled) echo "=== Backup Complete (local only -- offsite upload not configured, see the warning above) ===" ;;
  failed)
    echo "=== Backup Complete LOCALLY ONLY -- see the OFFSITE BACKUP error above (#363) ==="
    exit 1
    ;;
  *)
    # Unreachable today; here so a future state added above fails loudly instead of exiting 0.
    echo "::error::Unknown OFFSITE_STATE '$OFFSITE_STATE' -- the offsite outcome of this run is undetermined." >&2
    exit 1
    ;;
esac
