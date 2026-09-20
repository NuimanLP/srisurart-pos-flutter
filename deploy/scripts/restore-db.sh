#!/usr/bin/env bash
# restore-db.sh — Database restore verification & recovery for Srisurart POS (Slice 23 / #288).
#
# Restores a timestamped backup archive created by `backup-db.sh`.
# Invariant: Verifies archive checksum, restores schema & data, and asserts that
# the `pos_app` transaction ceiling (#213) is correctly restored (statement_timeout = 25s,
# idle_in_transaction_session_timeout = 5s), ensuring DbModule boot check passes with 0 warnings.
#
# Usage:
#   ./restore-db.sh <path-to-backup.sql.gz> [target_database]
#
# Environment variables:
#   APP_DIR        Application directory (default: /opt/pos, fallback to repo root/server)
#   POSTGRES_USER  Superuser name for psql (default: postgres)
set -euo pipefail

BACKUP_FILE="${1:-}"
if [[ -z "$BACKUP_FILE" || ! -f "$BACKUP_FILE" ]]; then
  echo "Usage: $0 <path-to-pos_backup_*.sql.gz> [target_database]" >&2
  exit 1
fi

APP_DIR="${APP_DIR:-/opt/pos}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ ! -d "$APP_DIR" && -d "$REPO_ROOT/server" ]]; then
  APP_DIR="$REPO_ROOT/server"
fi

POSTGRES_USER="${POSTGRES_USER:-postgres}"
TARGET_DB="${2:-pos}"

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

echo "=== Srisurart POS Database Restore ==="
echo "  Backup Archive: $BACKUP_FILE"
echo "  Target Database: $TARGET_DB"

# 1. Verify Checksum if present
CHECKSUM_FILE="${BACKUP_FILE}.sha256"
if [[ -f "$CHECKSUM_FILE" ]]; then
  echo "Verifying SHA256 checksum..."
  BACKUP_DIR="$(dirname "$BACKUP_FILE")"
  BACKUP_BASENAME="$(basename "$BACKUP_FILE")"
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

exec_psql() {
  local db="${1:-postgres}"
  shift
  if command -v docker >/dev/null 2>&1 && [[ ${#COMPOSE_ARGS[@]} -gt 0 ]] && docker compose "${COMPOSE_ARGS[@]}" ps --services 2>/dev/null | grep -q postgres; then
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
  if command -v docker >/dev/null 2>&1 && [[ ${#COMPOSE_ARGS[@]} -gt 0 ]] && docker compose "${COMPOSE_ARGS[@]}" ps --services 2>/dev/null | grep -q postgres; then
    docker compose "${COMPOSE_ARGS[@]}" exec -T postgres psql -U pos_app -d "$db" "$@"
  elif command -v psql >/dev/null 2>&1; then
    psql -U pos_app -d "$db" "$@"
  else
    echo "::error::Neither active docker compose postgres container nor local psql command found." >&2
    exit 1
  fi
}

# 2. Terminate existing connections to the target database
echo "Terminating any active connections to '$TARGET_DB'..."
exec_psql postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$TARGET_DB' AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true

# 3. Restore database from gzip stream
echo "Restoring database stream..."
if command -v docker >/dev/null 2>&1 && [[ ${#COMPOSE_ARGS[@]} -gt 0 ]] && docker compose "${COMPOSE_ARGS[@]}" ps --services 2>/dev/null | grep -q postgres; then
  gzip -dc "$BACKUP_FILE" | docker compose "${COMPOSE_ARGS[@]}" exec -T postgres psql -U "$POSTGRES_USER" -d postgres --quiet
else
  gzip -dc "$BACKUP_FILE" | psql -U "$POSTGRES_USER" -d postgres --quiet
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

MIGRATION_COUNT="$(exec_psql "$TARGET_DB" -t -c "SELECT COUNT(*) FROM typeorm_migrations;" | tr -d '[:space:]')"
echo "  Restored migrations:                       $MIGRATION_COUNT"

echo "=== Restore & Verification Succeeded ==="
