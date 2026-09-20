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
#   APP_DIR           Application directory (default: /opt/pos, fallback to repo root/server)
#   BACKUP_DIR        Target backup directory (default: $APP_DIR/backups)
#   BACKUP_KEEP_DAYS  Number of days to keep local backups (default: 7)
#   POSTGRES_DB       Database name to dump (default: pos)
#   POSTGRES_USER     Superuser name for pg_dump (default: postgres)
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

if [[ "$BACKUP_KEEP_DAYS" -gt 0 ]]; then
  echo "Pruning backups older than $BACKUP_KEEP_DAYS days in $BACKUP_DIR..."
  find "$BACKUP_DIR" -type f \( -name "${POSTGRES_DB}_backup_*.sql.gz" -o -name "${POSTGRES_DB}_backup_*.sql.gz.sha256" \) -mtime +"$BACKUP_KEEP_DAYS" -exec rm -f {} +
fi

echo "=== Backup Complete ==="
