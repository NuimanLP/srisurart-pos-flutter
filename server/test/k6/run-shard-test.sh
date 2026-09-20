#!/usr/bin/env bash
# run-shard-test.sh — Automated per-shard k6 load runner (#251, #184 Slice 22)
#
# Runs distributed load test scenarios matching 02_API_SCREENS.md §9 and server/test/k6/README.md.
#
# Usage:
#   ./run-shard-test.sh <SHARD_INDEX> [TOTAL_SHARDS] [TESTID] [MACHINE_NAME]
#
# Examples:
#   ./run-shard-test.sh 1 3
#   ./run-shard-test.sh 2 3 20260920T150000Z laptop-b
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

SHARD_INDEX="${1:-}"
TOTAL_SHARDS="${2:-3}"
TESTID="${3:-$(date -u +%Y%m%dT%H%M%SZ)}"
MACHINE_NAME="${4:-$(hostname -s 2>/dev/null || echo "laptop-$SHARD_INDEX")}"

if [[ -z "$SHARD_INDEX" ]]; then
  echo "Error: SHARD_INDEX is required (1 to $TOTAL_SHARDS)." >&2
  echo "Usage: $0 <SHARD_INDEX> [TOTAL_SHARDS] [TESTID] [MACHINE_NAME]" >&2
  exit 1
fi

if ! command -v k6 >/dev/null 2>&1; then
  echo "Error: k6 is not installed on this machine. Install k6 first (https://k6.io/docs/get-started/installation/)." >&2
  exit 1
fi

if [[ ! -f "$SCRIPT_DIR/k6-env.json" ]]; then
  echo "Error: $SCRIPT_DIR/k6-env.json not found." >&2
  echo "Please run 'pnpm k6:setup' on one laptop or copy k6-env.json from another team member." >&2
  exit 1
fi

echo "================================================================="
echo " Starting Distributed k6 Run (Scenario 1..4)"
echo " Shard:        $SHARD_INDEX / $TOTAL_SHARDS"
echo " Machine:      $MACHINE_NAME"
echo " Test ID:      $TESTID"
echo " Prometheus:   ${K6_PROMETHEUS_RW_SERVER_URL:-<local terminal output only>}"
echo "================================================================="

cd "$SERVER_DIR"

run_scenario() {
  local script_name="$1"
  local scenario_title="$2"
  local extra_flags="${3:-}"

  echo ""
  echo "-----------------------------------------------------------------"
  echo " Running $scenario_title ($script_name)..."
  echo "-----------------------------------------------------------------"

  local k6_output_flags=()
  if [[ -n "${K6_PROMETHEUS_RW_SERVER_URL:-}" ]]; then
    k6_output_flags=(-o experimental-prometheus-rw)
  fi

  SHARD="${SHARD_INDEX}/${TOTAL_SHARDS}" k6 run \
    "${k6_output_flags[@]}" \
    --insecure-skip-tls-verify \
    --tag testid="$TESTID" \
    --tag machine="$MACHINE_NAME" \
    $extra_flags \
    "test/k6/$script_name"
}

# 1. Read heavy (01-read-products.js)
run_scenario "01-read-products.js" "Scenario 1: Read-heavy products catalogue"

# 2. Write sales contention (02-write-sales-contention.js)
run_scenario "02-write-sales-contention.js" "Scenario 2: Write sales contention (200 on 50 stock)"

# 3. Idempotent replay (03-idempotent-replay.js)
run_scenario "03-idempotent-replay.js" "Scenario 3: Idempotent sales replay"

# 4. Mixed workload (04-mixed-workload.js)
run_scenario "04-mixed-workload.js" "Scenario 4: Mixed 80/20 workload" "${MIXED_EXTRA_FLAGS:-}"

echo ""
echo "================================================================="
echo "✅ All 4 load test scenarios completed on Shard $SHARD_INDEX/$TOTAL_SHARDS!"
echo "Test ID: $TESTID"

if [[ "$SHARD_INDEX" == "1" ]]; then
  echo ""
  echo "As Shard 1 coordinator, run verify-integrity now:"
  echo "  pnpm k6:verify"
fi
echo "================================================================="
