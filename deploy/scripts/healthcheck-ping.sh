#!/usr/bin/env bash
# Uptime heartbeat for the demo VM: checks the stack from the VM itself, then tells
# Healthchecks.io the result. Run by cron every 5 minutes (deploy/ansible/provision.yml).
#
# Why push instead of an uptime monitor on the VM: a monitor on `mob04` dies with `mob04`.
# Healthchecks.io alerts when the pings STOP — VM down, network down, cron dead, or this
# check failing all look the same from outside, and all of them page.
#
#   ready  -> GET  <ping URL>        (the check passed)
#   broken -> POST <ping URL>/fail   (the check failed; the curl error is the request body,
#                                     shown in the Healthchecks.io event log)
#
# What is checked: https://127.0.0.1/health/ready through Nginx — Nginx, one api instance,
# Postgres and redis-cache together (health.service.ts). `-k` because the certificate is
# issued for the VM's IP, not for 127.0.0.1; this probe never leaves the host.
#
# The ping URL is a secret (anyone holding it can report "all fine"): it lives only in
# /opt/pos/.env as HEALTHCHECKS_PING_URL=, never in this repo. Read with grep, not `source`
# — the .env carries multi-line PEM values a shell would choke on.
#
# Unset URL -> one `::warning::` line and exit 0, same rule as backup-db.sh's offsite step:
# not configured yet is not a failure. A configured URL that cannot be reached (FortiGate,
# DNS) -> `::error::` and exit 1. Output goes to syslog: journalctl -t pos-healthcheck
set -uo pipefail

ENV_FILE="${POS_ENV_FILE:-/opt/pos/.env}"
READY_URL="${HEALTHCHECK_READY_URL:-https://127.0.0.1/health/ready}"

url="${HEALTHCHECKS_PING_URL:-}"
if [ -z "$url" ] && [ -r "$ENV_FILE" ]; then
  # The last line wins, as in Compose.
  url="$(grep '^HEALTHCHECKS_PING_URL=' "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d '"'"'"'\r')"
fi
if [ -z "$url" ]; then
  echo "::warning::HEALTHCHECKS_PING_URL is not set in $ENV_FILE — no heartbeat sent"
  exit 0
fi

# Retried before reporting: a /fail alerts at once (no grace period), and a deploy restarting
# the api instances or a single slow answer must not page anyone. Worst case ~2 min (probe
# ~85 s + ping ~47 s), well inside the 5-minute cron period.
if detail="$(curl -fsS -k --max-time 10 --retry 3 --retry-delay 15 --retry-connrefused \
  -o /dev/null "$READY_URL" 2>&1)"; then
  target="$url"
  body=()
else
  target="$url/fail"
  body=(--data-raw "health/ready failed: ${detail:-no detail}")
fi

# --retry covers a transient blip on the way out. The URL is the secret: it reaches curl as a
# config on stdin (-K -), never in argv (readable by any user via ps), and is never echoed.
esc="${target//'\'/'\\'}"
esc="${esc//'"'/'\"'}"
if ! err="$(curl -fsS --max-time 10 --retry 3 -o /dev/null ${body[@]+"${body[@]}"} -K - \
  <<<"url = \"$esc\"" 2>&1)"; then
  echo "::error::could not reach Healthchecks.io: ${err//"$url"/<ping URL>}"
  exit 1
fi
[ "$target" = "$url" ] || echo "::warning::reported FAIL to Healthchecks.io: $detail"
exit 0
