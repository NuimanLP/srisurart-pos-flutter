#!/usr/bin/env bash
# restore-db.sh — Database restore verification & recovery for Srisurart POS (Slice 23 / #288).
#
# Restores a timestamped backup archive created by `backup-db.sh`.
# Invariant: Verifies archive checksum, restores schema & data, and asserts that
# the `pos_app` transaction ceiling (#213) is correctly restored (statement_timeout = 25s,
# idle_in_transaction_session_timeout = 5s), ensuring DbModule boot check passes with 0 warnings.
#
# Usage:
#   ./restore-db.sh <path-to-backup.sql.gz>
#
# The dump is made with `pg_dump --create --clean --if-exists`, so it always DROPs and re-CREATEs
# the database it was taken from (named inside the dump). There is therefore no "target database"
# argument: restoring under another name is not possible with this dump.
#
# Safety rules:
#   * psql runs with ON_ERROR_STOP=1: the first SQL error aborts and the script exits non-zero.
#     --single-transaction is NOT used: the dump contains DROP/CREATE DATABASE, which Postgres
#     refuses inside a transaction block. A failed restore can therefore leave the database
#     dropped or half-built -- restore again from a good dump.
#   * On a docker compose stack the app services (api-1/2/3, worker, bull-board) are stopped before
#     the DROP, so their reconnecting pools cannot race it, and started again only after the
#     verification passes. On failure they stay stopped and the exact start command is printed.
#
# Environment variables:
#   APP_DIR        Application directory (default: /opt/pos, fallback to repo root/server)
#   POSTGRES_USER  Superuser name for psql (default: postgres)
#   POSTGRES_DB    Database the dump recreates (default: pos); used to cut connections and verify
set -euo pipefail

BACKUP_FILE="${1:-}"
if [[ $# -gt 1 ]]; then
  echo "::error::A target database argument is no longer accepted: the dump is made with --create, so it always restores into the database it was taken from, never under another name." >&2
  exit 1
fi
if [[ -z "$BACKUP_FILE" || ! -f "$BACKUP_FILE" ]]; then
  echo "Usage: $0 <path-to-pos_backup_*.sql.gz>" >&2
  exit 1
fi

APP_DIR="${APP_DIR:-/opt/pos}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ ! -d "$APP_DIR" && -d "$REPO_ROOT/server" ]]; then
  APP_DIR="$REPO_ROOT/server"
fi

POSTGRES_USER="${POSTGRES_USER:-postgres}"
TARGET_DB="${POSTGRES_DB:-pos}"

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

# vm.override.yml pins every image to ${IMAGE_TAG:?IMAGE_TAG is required}, but /opt/pos/.env never
# carries IMAGE_TAG by design (ticket-336) -- only /opt/pos/.current_sha does. Without this, any
# `docker compose ...` call below fails interpolation before it can even list services (same bug
# as backup-db.sh).
USES_VM_OVERRIDE=false
for arg in "${COMPOSE_ARGS[@]}"; do
  case "$arg" in
    */vm.override.yml) USES_VM_OVERRIDE=true ;;
  esac
done

if [[ -z "${IMAGE_TAG:-}" && -f "$APP_DIR/.current_sha" ]]; then
  IMAGE_TAG="$(tr -d '[:space:]' < "$APP_DIR/.current_sha")"
  if [[ -n "$IMAGE_TAG" ]]; then
    export IMAGE_TAG
    echo "IMAGE_TAG was unset; resolved from $APP_DIR/.current_sha: $IMAGE_TAG"
  fi
fi

if $USES_VM_OVERRIDE && [[ -z "${IMAGE_TAG:-}" ]]; then
  echo "::error::IMAGE_TAG is required by deploy/compose/vm.override.yml but is unset, and $APP_DIR/.current_sha is missing or empty. Set IMAGE_TAG (e.g. IMAGE_TAG=\$(cat $APP_DIR/.current_sha)) before running this script -- refusing to silently fall back to a local psql on a VM." >&2
  exit 1
fi

# Returns 0 if a `postgres` compose service is present, 1 if compose resolved cleanly but has no
# such service. Exits loudly (instead of letting callers fall through to a misleading "neither
# container nor local psql found" message) if compose itself failed to resolve the configuration.
compose_has_postgres() {
  local services
  if ! services="$(docker compose "${COMPOSE_ARGS[@]}" ps --services 2>&1)"; then
    echo "::error::docker compose could not resolve the compose configuration (docker compose ${COMPOSE_ARGS[*]} ps --services):" >&2
    echo "$services" >&2
    exit 1
  fi
  grep -q postgres <<<"$services"
}

echo "=== Srisurart POS Database Restore ==="
echo "  Backup Archive: $BACKUP_FILE"
echo "  Database (recreated by the dump): $TARGET_DB"

# 1. Verify Checksum if present
CHECKSUM_FILE="${BACKUP_FILE}.sha256"
if [[ -f "$CHECKSUM_FILE" ]]; then
  echo "Verifying SHA256 checksum..."
  BACKUP_DIR="$(dirname "$BACKUP_FILE")"
  CHECKSUM_BASENAME="$(basename "$CHECKSUM_FILE")"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$BACKUP_DIR" && sha256sum -c "$CHECKSUM_BASENAME")
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$BACKUP_DIR" && shasum -a 256 -c "$CHECKSUM_BASENAME")
  fi
  echo "  -> Checksum verified successfully."
else
  echo "::warning::Checksum file $CHECKSUM_FILE not found, skipping checksum verification."
fi

# Prove the archive decompresses before anything is stopped or dropped (a missing .sha256 must not
# let a truncated dump reach DROP DATABASE).
if ! gzip -t "$BACKUP_FILE"; then
  echo "::error::$BACKUP_FILE is not a valid gzip archive -- nothing was stopped or dropped." >&2
  exit 1
fi

exec_psql() {
  local db="${1:-postgres}"
  shift
  if command -v docker >/dev/null 2>&1 && [[ ${#COMPOSE_ARGS[@]} -gt 0 ]] && compose_has_postgres; then
    docker compose "${COMPOSE_ARGS[@]}" exec -T postgres psql -U "$POSTGRES_USER" -d "$db" "$@"
  elif command -v psql >/dev/null 2>&1; then
    psql -U "$POSTGRES_USER" -d "$db" "$@"
  else
    echo "::error::Neither active docker compose postgres container nor local psql command found." >&2
    exit 1
  fi
}

exec_psql_app() {
  local db="${1:-pos}"
  shift
  if command -v docker >/dev/null 2>&1 && [[ ${#COMPOSE_ARGS[@]} -gt 0 ]] && compose_has_postgres; then
    docker compose "${COMPOSE_ARGS[@]}" exec -T postgres psql -U pos_app -d "$db" "$@"
  elif command -v psql >/dev/null 2>&1; then
    psql -U pos_app -d "$db" "$@"
  else
    echo "::error::Neither active docker compose postgres container nor local psql command found." >&2
    exit 1
  fi
}

# Compose services that hold database connections. Stopped before the DROP, restarted only after
# verification. Empty (and untouched) when not running against a docker compose stack.
APP_SERVICES=(api-1 api-2 api-3 worker bull-board)
STOPPED_SERVICES=()
RESTARTED=false
compose_mode() {
  command -v docker >/dev/null 2>&1 && [[ ${#COMPOSE_ARGS[@]} -gt 0 ]] && compose_has_postgres
}
on_exit() {
  local rc=$?
  if [[ $rc -ne 0 && ${#STOPPED_SERVICES[@]} -gt 0 && "$RESTARTED" != true ]]; then
    echo "::error::Restore did not complete (exit $rc). The app services are LEFT STOPPED: ${STOPPED_SERVICES[*]}" >&2
    echo "Once the database is good again, start them with:" >&2
    echo "  docker compose ${COMPOSE_ARGS[*]} start ${STOPPED_SERVICES[*]}" >&2
  fi
}
trap on_exit EXIT

if compose_mode; then
  running="$(docker compose "${COMPOSE_ARGS[@]}" ps --status running --services)"
  for svc in "${APP_SERVICES[@]}"; do
    if grep -qx "$svc" <<<"$running"; then STOPPED_SERVICES+=("$svc"); fi
  done
  if [[ ${#STOPPED_SERVICES[@]} -gt 0 ]]; then
    echo "Stopping app services before the restore: ${STOPPED_SERVICES[*]}"
    docker compose "${COMPOSE_ARGS[@]}" stop "${STOPPED_SERVICES[@]}"
  fi
else
  echo "::warning::Not running against a docker compose stack: stop the API and worker yourself first, or reconnecting pools can race the DROP DATABASE." >&2
fi

# 2. Terminate existing connections to the target database
echo "Terminating any active connections to '$TARGET_DB'..."
exec_psql postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$TARGET_DB' AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true

# 3. Restore database from gzip stream
echo "Restoring database stream..."
# ON_ERROR_STOP=1: any SQL error aborts psql with a non-zero status (pipefail carries it out).
if compose_mode; then
  gzip -dc "$BACKUP_FILE" | docker compose "${COMPOSE_ARGS[@]}" exec -T postgres psql -U "$POSTGRES_USER" -d postgres --quiet -v ON_ERROR_STOP=1
else
  gzip -dc "$BACKUP_FILE" | psql -U "$POSTGRES_USER" -d postgres --quiet -v ON_ERROR_STOP=1
fi
echo "  -> SQL stream applied successfully."

# 4. Verify post-restore invariants (#213)
echo "Verifying pos_app role transaction ceiling (#213)..."
STMT_TIMEOUT="$(exec_psql_app "$TARGET_DB" -t -c "SHOW statement_timeout;" | tr -d '[:space:]')"
IDLE_TIMEOUT="$(exec_psql_app "$TARGET_DB" -t -c "SHOW idle_in_transaction_session_timeout;" | tr -d '[:space:]')"

echo "  pos_app statement_timeout:                 $STMT_TIMEOUT (expected: 25s)"
echo "  pos_app idle_in_transaction_session_timeout: $IDLE_TIMEOUT (expected: 5s)"

if [[ "$STMT_TIMEOUT" != "25s" || "$IDLE_TIMEOUT" != "5s" ]]; then
  echo "::error::Role-in-database ceiling mismatch! statement_timeout='$STMT_TIMEOUT', idle_in_transaction_session_timeout='$IDLE_TIMEOUT'" >&2
  exit 1
fi

MIGRATION_COUNT="$(exec_psql "$TARGET_DB" -t -c "SELECT COUNT(*) FROM migrations;" | tr -d '[:space:]')"
echo "  Restored migrations:                       $MIGRATION_COUNT"
# Row counts for a human sanity check (compare with what the backup was expected to hold).
for tbl in tenants sales products; do
  n="$(exec_psql "$TARGET_DB" -t -c "SELECT COUNT(*) FROM $tbl;" | tr -d '[:space:]')"
  printf '  Restored rows in %-10s %s\n' "$tbl:" "$n"
done

if [[ ${#STOPPED_SERVICES[@]} -gt 0 ]]; then
  echo "Starting app services again: ${STOPPED_SERVICES[*]}"
  docker compose "${COMPOSE_ARGS[@]}" start "${STOPPED_SERVICES[@]}"
  RESTARTED=true
fi

echo "=== Restore & Verification Succeeded ==="
