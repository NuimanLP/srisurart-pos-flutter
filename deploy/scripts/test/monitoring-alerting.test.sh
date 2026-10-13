#!/usr/bin/env bash
# Boot test for the alerting + uptime half of deploy/compose/monitoring.yml (07 §10.5). Brings up
# prometheus + grafana + gatus (+ node-exporter, a dependency) from monitoring.yml ITSELF — same
# pinned digests, env defaults, user/read_only, mounts — on a throwaway compose project with
# random loopback ports, and checks:
#   * Grafana is healthy and provisioned every rule in pos-alerts.yml, the Discord contact point
#     and the policy that routes to it; annotations reach Grafana un-interpolated;
#   * after one evaluation no rule has health "error" (bad PromQL / datasource uid / expression);
#   * Gatus loads its config (every endpoint shows up in /api/v1/endpoints/statuses) and
#     Prometheus scrapes it (up{job="gatus"} == 1);
#   * the amd64 Gatus binary is GOAMD64=v1 (mob04 is a qemu64 CPU, below x86-64-v2);
#   * deploy/gatus-ca/pos-ca.crt is still a byte copy of frontend/assets/certs/pos-ca.crt.
# No webhook is set, so the placeholder in monitoring.yml is what boots (nothing is ever sent).
# Needs docker + compose >= 2.24.4 (`!override`), curl, jq. Usage: deploy/scripts/test/monitoring-alerting.test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MON="$ROOT/deploy/compose/monitoring.yml"
RULES="$ROOT/deploy/grafana/provisioning/alerting/pos-alerts.yml"
GATUS_CFG="$ROOT/deploy/gatus/config.yaml"
PROJECT="pos-alerting-test-$$-$RANDOM"
WORK="$(mktemp -d)"
GRAFANA_PW="test-only-$RANDOM$RANDOM"

fails=0
check() { # description, command...
  local d="$1"
  shift
  if "$@" >/dev/null; then echo "ok   - $d"; else echo "FAIL - $d"; fails=$((fails + 1)); fi
}

compose() {
  MONITORING_CONFIG_DIR="$ROOT/deploy" GRAFANA_ADMIN_PASSWORD="$GRAFANA_PW" \
    docker compose -p "$PROJECT" -f "$MON" -f "$WORK/override.yml" "$@"
}

cleanup() {
  if [[ "$fails" -ne 0 || "${KEEP_LOGS:-0}" == 1 ]]; then
    compose logs --no-color --tail 80 grafana gatus prometheus 2>/dev/null || true
  fi
  # A unique throwaway project: -v removes only this project's own volumes, never a real stack's.
  compose down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# The image a service in monitoring.yml pins (read from the file, never duplicated here).
image_of() {
  awk -v svc="$1" '$0 == "  " svc ":" { f = 1; next } f && $1 == "image:" { print $2; exit }' "$MON"
}

# Random loopback ports so the test never collides with a dev stack on 3000/9090/3300.
cat > "$WORK/override.yml" <<'EOF'
services:
  prometheus:
    ports: !override ["127.0.0.1::9090"]
  grafana:
    ports: !override ["127.0.0.1::3000"]
  gatus:
    ports: !override ["127.0.0.1::8080"]
EOF

# 1. static checks
check "deploy/gatus-ca/pos-ca.crt is a copy of frontend/assets/certs/pos-ca.crt" \
  cmp -s "$ROOT/deploy/gatus-ca/pos-ca.crt" "$ROOT/frontend/assets/certs/pos-ca.crt"
GATUS_IMAGE="$(image_of gatus)"
check "monitoring.yml pins gatus by digest" grep -q '@sha256:[0-9a-f]\{64\}$' <<<"$GATUS_IMAGE"

# 2. the amd64 binary's micro-architecture level (go version -m when Go is installed; otherwise the
# same build-info line read straight from the binary).
docker pull -q --platform linux/amd64 "$GATUS_IMAGE" >/dev/null
cid="$(docker create --platform linux/amd64 "$GATUS_IMAGE")"
docker cp "$cid:/gatus" "$WORK/gatus" >/dev/null
docker rm "$cid" >/dev/null
if command -v go >/dev/null 2>&1; then
  goamd64="$(go version -m "$WORK/gatus" | awk '$1 == "build" && $2 ~ /^GOAMD64=/ { sub("GOAMD64=", "", $2); print $2 }')"
else
  goamd64="$(grep -a -o 'GOAMD64=v[0-9]' "$WORK/gatus" | head -1 | cut -d= -f2)"
fi
echo "     gatus amd64 binary: GOAMD64=${goamd64:-<none>}"
check "gatus amd64 binary is GOAMD64=v1" test "$goamd64" = v1

# 3. boot
compose config -q
compose up -d --quiet-pull prometheus grafana gatus >/dev/null
port_of() { compose port "$1" "$2" | tail -1; }
GRAFANA="http://$(port_of grafana 3000)"
PROM="http://$(port_of prometheus 9090)"
GATUS="http://$(port_of gatus 8080)"
gf() { curl -sf -u "admin:$GRAFANA_PW" "$GRAFANA$1"; }

wait_for() { # seconds, description, command...
  local deadline=$((SECONDS + $1)) d="$2"
  shift 2
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      echo "     timed out waiting for: $d" >&2
      return 1
    fi
    sleep 3
  done
}

grafana_ok() { curl -sf "$GRAFANA/api/health" | jq -e '.database == "ok"'; }
check "grafana becomes healthy" wait_for 120 "grafana /api/health" grafana_ok

# 4. provisioning
expected_rules="$(grep -c '^        title: ' "$RULES")"  # rules only (the contact point's receiver also has a uid)
rule_count() { gf /api/v1/provisioning/alert-rules | jq 'length'; }
echo "     rules in pos-alerts.yml: $expected_rules, provisioned: $(rule_count || echo '?')"
check "grafana provisioned every rule in pos-alerts.yml" test "$(rule_count)" = "$expected_rules"
contact_ok() { gf /api/v1/provisioning/contact-points | jq -e 'any(.[]; .name == "discord" and .type == "discord")'; }
check "the Discord contact point is provisioned" contact_ok
policy_ok() { gf /api/v1/provisioning/policies | jq -e '.receiver == "discord"'; }
check "the notification policy routes to discord" policy_ok
annotation_ok() { gf /api/v1/provisioning/alert-rules/pos-api-instance-down | jq -e '.annotations.summary | contains("{{ $labels.instance }}")'; }
check "annotations reach grafana un-interpolated" annotation_ok

# 5. evaluation: every rule evaluated at least once, none with health "error".
rules_json() { gf /api/prometheus/grafana/api/v1/rules; }
all_evaluated() {
  rules_json | jq -e --argjson n "$expected_rules" \
    '[.data.groups[].rules[]] | length == $n and all(.[]; (.lastEvaluation // "0001") | startswith("0001") | not)'
}
check "every rule has been evaluated" wait_for 180 "one evaluation of every rule" all_evaluated
rules_json | jq -r '.data.groups[].rules[] | "     \(.health)\t\(.state)\t\(.name)\(if .lastError then "\t" + .lastError else "" end)"' || true
no_errors() { rules_json | jq -e '[.data.groups[].rules[] | select(.health == "error")] | length == 0'; }
check "no rule has health \"error\"" no_errors

# 6. gatus
expected_endpoints="$(grep -c '^  - name: ' "$GATUS_CFG")"
statuses_ok() { curl -sf "$GATUS/api/v1/endpoints/statuses" | jq -e --argjson n "$expected_endpoints" 'length == $n'; }
check "gatus loads its config ($expected_endpoints endpoints in /api/v1/endpoints/statuses)" \
  wait_for 90 "gatus statuses" statuses_ok
gatus_scraped() { curl -sf "$PROM/api/v1/query" --data-urlencode 'query=up{job="gatus"}' | jq -e '.data.result[0].value[1] == "1"'; }
check "prometheus scrapes gatus (up{job=\"gatus\"} == 1)" wait_for 60 "gatus scrape" gatus_scraped

if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
