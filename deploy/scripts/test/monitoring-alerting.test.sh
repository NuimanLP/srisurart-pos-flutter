#!/usr/bin/env bash
# Boot test for the alerting + uptime half of deploy/compose/monitoring.yml (07 §10.5). Brings up
# prometheus + grafana + gatus (+ node-exporter, a dependency) from monitoring.yml ITSELF — same
# pinned digests, env defaults, user/read_only, mounts — on a throwaway compose project with
# random loopback ports, and checks:
#   * Grafana is healthy, loaded the pos-overview dashboard, and provisioned every rule in
#     pos-alerts.yml, the Discord contact point and the policy that routes to it; annotations reach Grafana un-interpolated;
#   * after one evaluation no rule has health "error" (bad PromQL / datasource uid / expression);
#   * every metric name the rules' PromQL selects has at least one series in this Prometheus — an
#     empty vector is not an error, so a misspelled name would otherwise pass as "OK / no data".
#     Names are extracted from the expressions Grafana provisioned, never from a list kept here;
#     only NO_SERIES_IN_TEST below may be absent (the backup gauge is seeded, not allowlisted);
#   * Gatus loads its config (every endpoint shows up in /api/v1/endpoints/statuses), its
#     grafana + prometheus checks pass, and Prometheus scrapes it (up{job="gatus"} == 1);
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

# Metric names a rule may select although nothing in this stack exports them (no api runs here).
# Every other name must have a series. An entry no rule references any more is a failure too.
declare -A NO_SERIES_IN_TEST=(
  [http_requests_total]="exported by api-1..3 (server/src/metrics), which this test does not boot"
  [http_request_duration_seconds_bucket]="exported by api-1..3 (server/src/metrics), which this test does not boot"
  [pos_db_pool_connections]="exported by api-1..3 (server/src/metrics), which this test does not boot"
)

# The backup freshness gauge, seeded the way backup-db.sh writes it, so pos-backup-stale's metric
# name is checked against a real series. node-exporter's textfile directory is pointed at it; the
# rest of its command is monitoring.yml's own (read back from `compose config`, `$` re-escaped).
mkdir -m 0755 "$WORK/textfile"
printf 'pos_backup_last_success_timestamp_seconds %s\n' "$(date -u +%s)" >"$WORK/textfile/pos_backup.prom"
chmod 0644 "$WORK/textfile/pos_backup.prom"
NE_COMMAND="$(MONITORING_CONFIG_DIR="$ROOT/deploy" GRAFANA_ADMIN_PASSWORD="$GRAFANA_PW" \
  docker compose -p "$PROJECT" -f "$MON" config --format json |
  jq -c '.services["node-exporter"].command
    | map(if startswith("--collector.textfile.directory=") then "--collector.textfile.directory=/pos-textfile" else . end
      | gsub("\\$"; "$$"))')"

# Random loopback ports so the test never collides with a dev stack on 3000/9090/3300.
cat > "$WORK/override.yml" <<EOF
services:
  node-exporter:
    command: $NE_COMMAND
    volumes: ["$WORK/textfile:/pos-textfile:ro"]
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
dashboard_ok() { gf /api/dashboards/uid/srisurart-pos-overview | jq -e '(.dashboard.panels | length) > 0'; }
check "grafana loaded the pos-overview dashboard from deploy/grafana/dashboards" \
  wait_for 60 "pos-overview dashboard" dashboard_ok
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

# 5b. every metric name a rule selects has a series. The expressions are the ones Grafana provisioned
# (it parsed pos-alerts.yml). No Prometheus parse API is relied on, so the names are what is left
# of each expression after removing strings, {matchers}, [ranges] and by/on/... label lists:
# identifiers not followed by "(" (functions, aggregations) and not PromQL keywords. Anything else
# that slipped through still has to have a series, so a mistake here fails loudly, never quietly.
cat >"$WORK/metric-names.jq" <<'JQ'
def metric_names:
  gsub("\"(\\\\.|[^\"\\\\])*\"|'(\\\\.|[^'\\\\])*'|`[^`]*`"; "")
  | gsub("\\{[^}]*\\}|\\[[^\\]]*\\]"; "")
  | gsub("(?i)\\b(by|without|on|ignoring|group_left|group_right)\\s*\\([^)]*\\)"; "")
  | [scan("(?<![0-9.a-zA-Z_:])([a-zA-Z_:][a-zA-Z0-9_:]*)(\\s*\\()?") | select(.[1] == null) | .[0]
     | select(ascii_downcase | IN("and", "or", "unless", "bool", "offset", "by", "without", "on",
         "ignoring", "group_left", "group_right", "inf", "nan") | not)];
JQ
exprs="$(gf /api/v1/provisioning/alert-rules | jq '[.[].data[] | select(.datasourceUid == "Prometheus") | .model.expr]')"
metric_names="$WORK/metric-names"
jq -r "$(cat "$WORK/metric-names.jq") .[] | metric_names | .[]" <<<"$exprs" | sort -u >"$metric_names"
nameless() { jq -e "$(cat "$WORK/metric-names.jq") [.[] | select(metric_names | length == 0)] | length == 0" <<<"$exprs"; }
check "every rule expression names at least one metric" nameless
echo "     metric names in the rules: $(tr '\n' ' ' <"$metric_names")"
has_series() {
  curl -sf -G "$PROM/api/v1/series" --data-urlencode "match[]={__name__=\"$1\"}" | jq -e '.data | length > 0'
}
while IFS= read -r name; do
  if [[ -n "${NO_SERIES_IN_TEST[$name]+x}" ]]; then
    echo "     skip $name — ${NO_SERIES_IN_TEST[$name]}"
    continue
  fi
  check "metric $name has a series in prometheus" has_series "$name"
done <"$metric_names"
for name in "${!NO_SERIES_IN_TEST[@]}"; do
  check "NO_SERIES_IN_TEST entry $name is still used by a rule" grep -qxF "$name" "$metric_names"
done

# 6. gatus
expected_endpoints="$(grep -c '^  - name: ' "$GATUS_CFG")"
statuses_ok() { curl -sf "$GATUS/api/v1/endpoints/statuses" | jq -e --argjson n "$expected_endpoints" 'length == $n'; }
check "gatus loads its config ($expected_endpoints endpoints in /api/v1/endpoints/statuses)" \
  wait_for 90 "gatus statuses" statuses_ok
# Of the endpoints Gatus watches, only grafana and prometheus run in this test; their conditions must
# pass against the real services (catches a wrong status/path in config.yaml for them).
monitoring_green() {
  curl -sf "$GATUS/api/v1/endpoints/statuses" | jq -e '
    [.[] | select(.group == "monitoring")] | length == 2
    and all(.[]; (.results | length) > 0 and .results[-1].success == true)'
}
check "gatus reports grafana + prometheus healthy" wait_for 90 "gatus monitoring endpoints green" monitoring_green
gatus_scraped() { curl -sf "$PROM/api/v1/query" --data-urlencode 'query=up{job="gatus"}' | jq -e '.data.result[0].value[1] == "1"'; }
check "prometheus scrapes gatus (up{job=\"gatus\"} == 1)" wait_for 60 "gatus scrape" gatus_scraped

if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
