#!/usr/bin/env bash
# Tests for deploy/scripts/measure-container-rss.sh's `docker stats` parsing and verdict (#380:
# every MiB value parsed as 0, the table came out empty and the verdict still said PASS).
# Runs against a stub `docker`: no Docker needed. Each case samples once (~2 s). Needs bash >= 4.
# Usage: deploy/scripts/test/measure-container-rss.test.sh
# RSS_SCRIPT overrides the script under test (used to prove the test fails on the old script).
# The expected report rows hold literal Markdown backticks, not command substitutions:
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT="${RSS_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/measure-container-rss.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# docker: `stats` prints $STUB_STATS (printf %b, so \t and \n work); `inspect` reports a
# healthy container (not OOM-killed, no restarts).
cat > "$STUBS/docker" <<'STUB'
#!/bin/sh
case "$1" in
  stats) printf '%b' "${STUB_STATS:-}" ;;
  inspect) case "$*" in *OOMKilled*) echo false ;; *) echo 0 ;; esac ;;
esac
STUB
chmod +x "$STUBS/docker"

fails=0
check() { # description, command...
  local d="$1"
  shift
  if "$@"; then echo "ok   - $d"; else echo "FAIL - $d"; fails=$((fails + 1)); fi
}

rc=0
REPORT=""
run_rss() { # case-name, stats ; sets rc and REPORT
  REPORT="$WORK/$1.md"
  # Duration 2, not 1: with 1 a second boundary before the loop's first check can skip
  # sampling entirely. 2 still takes exactly one sample (the loop sleeps 2 s after it).
  PATH="$STUBS:$PATH" STUB_STATS="$2" bash "$SCRIPT" 2 "$REPORT" >"$WORK/$1.log" 2>&1
  rc=$?
}
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }

# 1. binary units as `docker stats` prints memory: every row parsed to the right MiB, PASS.
run_rss binary 'pos-api-1\t55.4MiB / 384MiB\t1.50%\npos-postgres-1\t1.2GiB / 2GiB\t10.00%\npos-etcd-1\t512KiB / 1GiB\t0.10%\npos-idle-1\t0B / 0B\t0.00%\n'
check "binary units: exits 0" test "$rc" -eq 0
check "binary units: MiB row parsed (55.40, not 0)" has "$REPORT" '| `pos-api-1` | `384.00 MiB` | **55.40 MiB** |'
check "binary units: GiB row parsed (1228.80)" has "$REPORT" '| `pos-postgres-1` | `2048.00 MiB` | **1228.80 MiB** |'
check "binary units: KiB row parsed (0.50)" has "$REPORT" '| `pos-etcd-1` | `1024.00 MiB` | **0.50 MiB** |'
check "binary units: a 0B container is still listed" has "$REPORT" '| `pos-idle-1` | `0.00 MiB` | **0.00 MiB** |'
check "binary units: aggregate is the sum (1284.70)" has "$REPORT" '`1284.70 MiB`'
check "binary units: verdict PASS" has "$REPORT" '**PASS**'

# 2. decimal units (kB/MB/GB) are converted to MiB too.
run_rss decimal 'pos-a-1\t100MB / 1GB\t1.00%\npos-b-1\t2048kB / 1GB\t1.00%\n'
check "decimal units: exits 0" test "$rc" -eq 0
check "decimal units: MB row parsed (95.37)" has "$REPORT" '| `pos-a-1` | `953.67 MiB` | **95.37 MiB** |'
check "decimal units: kB row parsed (1.95)" has "$REPORT" '| `pos-b-1` | `953.67 MiB` | **1.95 MiB** |'

# 3. no `docker stats` output at all: FAIL and a non-zero exit, never PASS.
run_rss empty ''
check "no data: exits non-zero" test "$rc" -ne 0
check "no data: verdict FAIL" has "$REPORT" '**FAIL**'
check "no data: verdict is not PASS" lacks "$REPORT" '**PASS**'

# 4. only unparseable rows: skipped with a warning, then the same FAIL as no data.
run_rss garbage 'pos-x-1\t-- / --\t--\n'
check "unparseable: exits non-zero" test "$rc" -ne 0
check "unparseable: warns about the skipped row" has "$WORK/garbage.log" "cannot parse memory"
check "unparseable: verdict is not PASS" lacks "$REPORT" '**PASS**'

# 5. one good row plus one unparseable row: incomplete data is a FAIL, not a PASS.
run_rss partial 'pos-api-1\t55.4MiB / 384MiB\t1.50%\npos-x-1\t-- / --\t--\n'
check "partial: exits non-zero" test "$rc" -ne 0
check "partial: the good row is still listed" has "$REPORT" '**55.40 MiB**'
check "partial: verdict is not PASS" lacks "$REPORT" '**PASS**'

# 6. over the 6 GB ceiling: FAIL and a non-zero exit.
run_rss over 'pos-big-1\t7GiB / 8GiB\t1.00%\n'
check "over ceiling: exits non-zero" test "$rc" -ne 0
check "over ceiling: verdict FAIL" has "$REPORT" '**FAIL**'
check "over ceiling: verdict is not PASS" lacks "$REPORT" '**PASS**'

if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all checks passed"
