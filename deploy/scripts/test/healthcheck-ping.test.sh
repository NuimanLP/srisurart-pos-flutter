#!/usr/bin/env bash
# Tests for deploy/scripts/healthcheck-ping.sh against a stub `curl` that logs its arguments:
# no network, no VM needed. Usage: deploy/scripts/test/healthcheck-ping.test.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/healthcheck-ping.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
PING='https://hc-ping.com/00000000-0000-0000-0000-000000000000'

# STUB_READY_FAIL=1: the readiness probe fails. STUB_PING_FAIL=1: Healthchecks.io is unreachable.
cat > "$STUBS/curl" <<'STUB'
#!/bin/sh
echo "$*" >> "$CURL_LOG"
case "$*" in
  *127.0.0.1/health/ready*) [ "${STUB_READY_FAIL:-0}" = 1 ] && { echo "curl: (22) The requested URL returned error: 503" >&2; exit 22; } ;;
  *) [ "${STUB_PING_FAIL:-0}" = 1 ] && { echo "curl: (35) SSL certificate problem" >&2; exit 35; } ;;
esac
exit 0
STUB
chmod +x "$STUBS/curl"

fails=0
check() { # description, command...
  local d="$1"
  shift
  if "$@"; then echo "ok   - $d"; else echo "FAIL - $d"; fails=$((fails + 1)); fi
}

rc=0
out=''
run() { # env-file-content, extra env... ; sets rc, out, CURL_LOG
  local env_file="$WORK/env"
  printf '%s' "$1" > "$env_file"
  shift
  export CURL_LOG="$WORK/curl.log"
  : > "$CURL_LOG"
  out="$(env -u HEALTHCHECKS_PING_URL PATH="$STUBS:$PATH" POS_ENV_FILE="$env_file" "$@" bash "$SCRIPT" 2>&1)"
  rc=$?
}
pings() { grep -v '127.0.0.1/health/ready' "$CURL_LOG"; }
last_ping_ends() { pings | tail -1 | grep -q -- "$1\$"; }

ENV_OK="$(printf 'JWT_PRIVATE_KEY="-----BEGIN KEY-----\nabc\n-----END KEY-----"\nHEALTHCHECKS_PING_URL=%s\nREDIS_PASSWORD=x\n' "$PING")"

# 1. healthy stack: probe through nginx, then a plain ping (no /fail), exit 0, silent.
run "$ENV_OK"
check "healthy: exits 0" test "$rc" -eq 0
check "healthy: probes /health/ready" grep -q 'https://127.0.0.1/health/ready' "$CURL_LOG"
check "healthy: pings the URL itself" last_ping_ends "$PING"
check "healthy: prints nothing" test -z "$out"
probe_retries() { grep '127.0.0.1/health/ready' "$CURL_LOG" | grep -q -- '--retry 3 --retry-delay 15 --retry-connrefused'; }
check "healthy: probe retries before reporting (a /fail has no grace period)" probe_retries

# 2. broken stack: ping /fail with the probe's error as the body, still exit 0.
run "$ENV_OK" STUB_READY_FAIL=1
check "broken: exits 0 (the report was delivered)" test "$rc" -eq 0
check "broken: pings /fail" last_ping_ends "$PING/fail"
check "broken: sends the probe error as the body" grep -q -- '--data-raw health/ready failed: curl: (22)' "$CURL_LOG"

# 3. Healthchecks.io unreachable (e.g. FortiGate): ::error:: and non-zero, URL never printed.
run "$ENV_OK" STUB_PING_FAIL=1
check "unreachable: exits non-zero" test "$rc" -ne 0
check "unreachable: says ::error::" grep -q '::error::' <<<"$out"
check "unreachable: never prints the ping URL" test "$(grep -c 'hc-ping.com/0000' <<<"$out")" = 0

# 4. not configured yet: ::warning::, exit 0, nothing sent anywhere.
run "$(printf 'REDIS_PASSWORD=x\n')"
check "unset: exits 0" test "$rc" -eq 0
check "unset: says ::warning::" grep -q '::warning::' <<<"$out"
check "unset: sends nothing" test ! -s "$CURL_LOG"

# 5. quoted value and CRLF line endings are tolerated.
run "$(printf 'HEALTHCHECKS_PING_URL="%s"\r\n' "$PING")"
check "quoted/CRLF: pings the bare URL" last_ping_ends "$PING"

# 6. the environment variable wins over the file.
run "$ENV_OK" HEALTHCHECKS_PING_URL="$PING-env"
check "env var overrides the file" last_ping_ends "$PING-env"

if [ "$fails" -ne 0 ]; then
  echo "$fails failed"
  exit 1
fi
echo "all healthcheck-ping tests passed"
