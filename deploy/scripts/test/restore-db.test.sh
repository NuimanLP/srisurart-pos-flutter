#!/usr/bin/env bash
# Tests for deploy/scripts/restore-db.sh: psql runs with ON_ERROR_STOP=1, the app services are
# stopped before the restore and started only after verification, a failed restore leaves them
# stopped with the start command printed, and a target-database argument is refused.
# Runs against a stub `docker` binary: no Docker or Postgres needed.
# Usage: deploy/scripts/test/restore-db.test.sh
# RESTORE_SCRIPT overrides the script under test (used to prove the test fails on the old script).
set -uo pipefail

SCRIPT="${RESTORE_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/restore-db.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# Stub docker: logs every call to $STUB_LOG. `compose` answers service listings, accepts
# stop/start, and fakes `exec postgres psql` (stdin = the dump; STUB_PSQL_FAIL=1 -> SQL error).
cat > "$STUBS/docker" <<'STUB'
#!/bin/bash
echo "docker $*" >> "$STUB_LOG"
all="$*"
case "$all" in
  *"ps --status running --services"*) printf 'postgres\napi-1\napi-2\nworker\nnginx\n'; exit 0 ;;
  *"ps --services"*) printf 'postgres\napi-1\napi-2\nworker\nnginx\n'; exit 0 ;;
  *" stop "*|*" start "*) exit 0 ;;
  *"SHOW statement_timeout"*) echo " 25s"; exit 0 ;;
  *"SHOW idle_in_transaction_session_timeout"*) echo " 5s"; exit 0 ;;
  *" -c "*) echo " 3"; exit 0 ;;
  *" exec "*)
    cat > /dev/null
    if [ "${STUB_PSQL_FAIL:-0}" = 1 ]; then
      case "$all" in *ON_ERROR_STOP=1*) echo 'ERROR: syntax error' >&2; exit 3 ;; esac
      echo 'ERROR: syntax error (ignored: no ON_ERROR_STOP)' >&2
    fi
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$STUBS/docker"

fails=0
check() { # description, command...
  local d="$1"
  shift
  if "$@"; then echo "ok   - $d"; else echo "FAIL - $d"; fails=$((fails + 1)); fi
}

DUMP="$WORK/pos_backup_test.sql.gz"
echo "SELECT 1;" | gzip > "$DUMP"

rc=0
LOG="$WORK/out.log"
run_restore() { # fail-flag, [extra args...] ; sets rc, writes $LOG and $STUB_LOG
  local fail="$1"
  shift
  : > "$WORK/calls.log"
  env -u POSTGRES_DB -u POSTGRES_USER PATH="$STUBS:$PATH" IMAGE_TAG=test STUB_LOG="$WORK/calls.log" \
    STUB_PSQL_FAIL="$fail" bash "$SCRIPT" "$DUMP" "$@" >"$LOG" 2>&1
  rc=$?
}
calls() { grep -c -- "$1" "$WORK/calls.log" | tr -d ' '; }
has() { grep -q -- "$1" "$LOG"; }
lacks() { ! grep -q -- "$1" "$LOG"; }

# 1. good restore: exit 0, services stopped before the restore and started after, ON_ERROR_STOP used.
run_restore 0
check "good restore exits 0" test "$rc" -eq 0
check "good restore stops api-1 api-2 worker (only running app services)" test "$(calls ' stop api-1 api-2 worker')" = 1
check "good restore starts the same services again" test "$(calls ' start api-1 api-2 worker')" = 1
stop_line="$(grep -n ' stop api-1' "$WORK/calls.log" | head -1 | cut -d: -f1)"
dump_line="$(grep -n 'ON_ERROR_STOP=1' "$WORK/calls.log" | head -1 | cut -d: -f1)"
start_line="$(grep -n ' start api-1' "$WORK/calls.log" | head -1 | cut -d: -f1)"
check "order: stop < restore < start" test "${stop_line:-9}" -lt "${dump_line:-0}" -a "${dump_line:-9}" -lt "${start_line:-0}"
check "good restore prints core table row counts" has "Restored rows in tenants"
check "good restore never touches postgres/nginx lifecycle" test "$(calls ' stop .*postgres')" = 0

# 2. SQL error: non-zero exit, services left stopped, start command printed, never started.
run_restore 1
check "failed restore exits non-zero" test "$rc" -ne 0
check "failed restore does not start the services" test "$(calls ' start ')" = 0
check "failed restore prints the start command" has "start api-1 api-2 worker"
check "failed restore does not claim success" lacks "Succeeded"

# 3. a target-database argument is refused before anything runs.
run_restore 0 other_db
check "target database argument is refused" test "$rc" -ne 0
check "refused argument stops nothing" test "$(calls ' stop ')" = 0

# 4. a corrupt archive is refused before anything is stopped or dropped.
GOOD_DUMP="$DUMP"
DUMP="$WORK/pos_backup_corrupt.sql.gz"
printf 'not a gzip stream' > "$DUMP"
run_restore 0
check "corrupt archive is refused" test "$rc" -ne 0
check "corrupt archive stops nothing" test "$(calls ' stop ')" = 0
check "corrupt archive never reaches psql" test "$(calls 'ON_ERROR_STOP')" = 0
DUMP="$GOOD_DUMP"

if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all restore-db checks passed"
