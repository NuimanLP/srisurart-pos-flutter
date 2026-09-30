#!/usr/bin/env bash
# Tests for deploy/scripts/backup-db.sh's dump step (a failed dump must not leave a
# pos_backup_*.sql.gz behind). Runs against stub `docker`/`pg_dump` binaries: no Docker or
# Postgres needed. Usage: deploy/scripts/test/backup-db.test.sh
# BACKUP_SCRIPT overrides the script under test (used to prove the test fails on the old script).
set -uo pipefail

SCRIPT="${BACKUP_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/backup-db.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# `docker compose ps --services` succeeds with no services, so the script falls through to pg_dump.
printf '#!/bin/sh\nexit 0\n' > "$STUBS/docker"
# pg_dump: STUB_PG_DUMP_FAIL=1 writes a little output, then fails (like a dropped connection).
cat > "$STUBS/pg_dump" <<'STUB'
#!/bin/sh
echo "-- partial dump"
[ "${STUB_PG_DUMP_FAIL:-0}" = 1 ] && { echo "pg_dump: error: connection failed" >&2; exit 1; }
echo "CREATE TABLE t ();"
STUB
chmod +x "$STUBS/docker" "$STUBS/pg_dump"

fails=0
check() { # description, command...
  local d="$1"
  shift
  if "$@"; then echo "ok   - $d"; else echo "FAIL - $d"; fails=$((fails + 1)); fi
}

rc=0
run_backup() { # dir, fail-flag ; sets rc
  env -u POSTGRES_DB -u POSTGRES_USER -u BACKUP_KEEP_DAYS -u BACKUP_RCLONE_CONFIG \
    PATH="$STUBS:$PATH" IMAGE_TAG=test BACKUP_RCLONE_REMOTE='' STUB_PG_DUMP_FAIL="$2" \
    bash "$SCRIPT" "$1" >"$1.log" 2>&1
  rc=$?
}
count() { find "$1" -maxdepth 1 -name "$2" | wc -l | tr -d ' '; }

# 1. failing dump: non-zero exit, nothing that looks like a backup remains (no .partial either).
D="$WORK/fail"
mkdir -p "$D"
run_backup "$D" 1
check "failed dump exits non-zero" test "$rc" -ne 0
check "failed dump leaves no pos_backup_*.sql.gz" test "$(count "$D" 'pos_backup_*.sql.gz')" = 0
check "failed dump leaves no .partial" test "$(count "$D" '*.partial')" = 0
check "failed dump writes no .sha256" test "$(count "$D" '*.sha256')" = 0

# 2. good dump: exit 0, a valid gz + sha256 sidecar for the final file, no .partial.
D="$WORK/ok"
mkdir -p "$D"
run_backup "$D" 0
check "good dump exits 0" test "$rc" -eq 0
check "good dump produces one pos_backup_*.sql.gz" test "$(count "$D" 'pos_backup_*.sql.gz')" = 1
f="$(find "$D" -maxdepth 1 -name 'pos_backup_*.sql.gz' | head -1)"
check "good dump passes gzip -t" gzip -t "$f"
has_dump_and_ceiling() { gzip -dc "$1" | grep -q 'CREATE TABLE t' && gzip -dc "$1" | grep -q 'ALTER ROLE pos_app'; }
check "good dump contains the dump and the role ceiling block" has_dump_and_ceiling "$f"
check "good dump has a sha256 sidecar for the final file" test "$(count "$D" 'pos_backup_*.sql.gz.sha256')" = 1
check "good dump leaves no .partial" test "$(count "$D" '*.partial')" = 0

# 3. prune: a stale .partial (SIGKILL leftover) is removed by age, a fresh one is kept.
D="$WORK/prune"
mkdir -p "$D"
touch -t 202001010000 "$D/pos_backup_old.sql.gz.partial"
touch "$D/pos_backup_new.sql.gz.partial"
run_backup "$D" 0
check "prune run exits 0" test "$rc" -eq 0
check "stale .partial is pruned" test ! -e "$D/pos_backup_old.sql.gz.partial"
check "fresh .partial is kept" test -e "$D/pos_backup_new.sql.gz.partial"

# 4. the real mob04 path: compose lists a postgres service, `exec` fails -> same guarantees.
cat > "$STUBS/docker" <<'STUB'
#!/bin/sh
case "$*" in
  *"ps --services"*) echo postgres; exit 0 ;;
  *exec*) echo "Error: service postgres is not running" >&2; exit 1 ;;
esac
exit 0
STUB
D="$WORK/compose"
mkdir -p "$D"
run_backup "$D" 0
check "failed compose exec exits non-zero" test "$rc" -ne 0
check "failed compose exec leaves no .sql.gz/.partial" test "$(count "$D" 'pos_backup_*')" = 0

if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
