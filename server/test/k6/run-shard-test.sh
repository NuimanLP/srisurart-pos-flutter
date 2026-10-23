#!/usr/bin/env bash
# run-shard-test.sh — Automated per-shard k6 load runner (#251, #184 Slice 22)
#
# Runs distributed load test scenarios matching 02_API_SCREENS.md §9, 03_ARCHITECTURE.md §8,
# and docs/handoff_log/ticket-184-k6-rss-runbook.md.
#
# Usage:
#   ./run-shard-test.sh <SHARD_INDEX> [TOTAL_SHARDS] [SCENARIO] [TESTID] [MACHINE_NAME]
#
# Arguments:
#   SHARD_INDEX   : 1, 2, or 3 (Required)
#   TOTAL_SHARDS  : Total shards count (Default: 3)
#   SCENARIO      : Specific scenario to run: 1, 2, 3, 4, or all (Default: all)
#   TESTID        : Shared test identifier (Default: current UTC timestamp YYYYMMDDTHHMMSSZ)
#   MACHINE_NAME  : Machine tag in metrics (Default: laptop-<SHARD_INDEX>)
#
# Environment variables:
#   NON_INTERACTIVE: Set to 'true' to skip pause barriers (e.g. for CI / automated dry run)
#   DRY_RUN        : Set to 'true' to run Scenario 4 with 30s instead of rubric 10m
#   MIXED_DURATION : Duration for Scenario 4 (Default: 10m, or 30s if DRY_RUN=true)
#
# Examples:
#   # Interactive synchronized 3-laptop run (recommended for submission):
#   ./run-shard-test.sh 1 3
#
#   # Run only Scenario 1 for quick smoke / dry run:
#   ./run-shard-test.sh 1 3 1
#
#   # Dry run all scenarios with 30s mixed test and no interactive pauses:
#   NON_INTERACTIVE=true DRY_RUN=true ./run-shard-test.sh 1 1 all
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

SHARD_INDEX="${1:-}"
TOTAL_SHARDS="${2:-3}"
TARGET_SCENARIO="${3:-all}"
TESTID="${4:-$(date -u +%Y%m%dT%H%M%SZ)}"
MACHINE_NAME="${5:-laptop-$SHARD_INDEX}"

if [[ -z "$SHARD_INDEX" ]]; then
  echo "Error: SHARD_INDEX is required (1 to $TOTAL_SHARDS)." >&2
  echo "Usage: $0 <SHARD_INDEX> [TOTAL_SHARDS] [SCENARIO: 1|2|3|4|all] [TESTID] [MACHINE_NAME]" >&2
  exit 1
fi

# k6 runs from the local binary when there is one. Without it, the pinned grafana/k6 image is
# used instead — pinned by version AND index digest (amd64+arm64), never `:latest`, so every
# laptop in one distributed run executes the same k6 (2026-09-15 used `grafana/k6:latest`).
# Bump it by `docker buildx imagetools inspect grafana/k6:<version>` and pasting the index digest.
K6_IMAGE="grafana/k6:2.3.0@sha256:9c2dee7f8ed74d317e4027c06a10f169b625638189de8d4555d0b3486a5aeb34"
if command -v k6 >/dev/null 2>&1; then
  K6_MODE=local
elif command -v docker >/dev/null 2>&1; then
  K6_MODE=docker
else
  echo "Error: neither k6 nor docker is installed on this machine. Install k6 (https://k6.io/docs/get-started/installation/) or Docker." >&2
  exit 1
fi

if [[ ! -f "$SCRIPT_DIR/k6-env.json" ]]; then
  echo "Error: $SCRIPT_DIR/k6-env.json not found." >&2
  echo "Please run 'pnpm k6:setup' on one laptop or copy k6-env.json from another team member." >&2
  exit 1
fi

# Duration configuration for Scenario 4
if [[ "${DRY_RUN:-false}" == "true" ]]; then
  MIXED_DURATION="${MIXED_DURATION:-30s}"
else
  MIXED_DURATION="${MIXED_DURATION:-10m}"
fi

echo "================================================================="
echo " Starting Distributed k6 Load Runner"
echo " Shard:        $SHARD_INDEX / $TOTAL_SHARDS"
echo " Machine:      $MACHINE_NAME"
echo " Scenario:     $TARGET_SCENARIO"
echo " k6:           $([[ "$K6_MODE" == "local" ]] && k6 version 2>/dev/null | head -1 || echo "$K6_IMAGE")"
echo " Test ID:      $TESTID"
echo " Scenario 4:   Duration = $MIXED_DURATION"
echo " Prometheus:   ${K6_PROMETHEUS_RW_SERVER_URL:-<local terminal output only>}"
echo " Interactive:  $([[ "${NON_INTERACTIVE:-false}" == "true" ]] && echo "No (automatic)" || echo "Yes (synchronized barrier)")"
echo "================================================================="

cd "$SERVER_DIR"

# `k6 …` either way. In docker mode server/ is mounted at /work (the scripts open
# ./k6-env.json relative to themselves) and only the env vars the scripts and the
# remote-write output read are passed through; `-e NAME` with no value forwards the
# caller's value, and nothing when it is unset. MSYS_NO_PATHCONV + `pwd -W` keep Git Bash on
# Windows from rewriting /work into a Windows path.
k6_cmd() {
  if [[ "$K6_MODE" == "local" ]]; then
    k6 "$@"
    return
  fi
  local host_dir
  host_dir="$(pwd -W 2>/dev/null || pwd)"
  MSYS_NO_PATHCONV=1 docker run --rm -i \
    -v "$host_dir:/work:ro" -w /work \
    -e SHARD -e DURATION -e RATE_PER_SHARD -e TOTAL_CONTENDERS -e TOTAL_REPLAY_VUS \
    -e K6_PROMETHEUS_RW_SERVER_URL -e K6_PROMETHEUS_RW_TREND_STATS \
    "$K6_IMAGE" "$@"
}

sync_barrier() {
  local sc_num="$1"
  local sc_title="$2"

  if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
    return 0
  fi

  echo ""
  echo "================================================================="
  echo " 🛑 [BARRIER] Scenario $sc_num: $sc_title"
  echo " Coordinate with your teammates (all laptops must start within 2s)."
  echo "================================================================="
  read -r -p ">>> When all laptops are ready, press [ENTER] to fire (Ctrl+C to abort)... " _
}

run_scenario() {
  local script_name="$1"
  local scenario_title="$2"
  local extra_flags="${3:-}"

  echo ""
  echo "-----------------------------------------------------------------"
  echo " 🚀 Running $scenario_title ($script_name)..."
  echo "-----------------------------------------------------------------"

  local k6_output_flags=()
  if [[ -n "${K6_PROMETHEUS_RW_SERVER_URL:-}" ]]; then
    k6_output_flags=(-o experimental-prometheus-rw)
  fi

  SHARD="${SHARD_INDEX}/${TOTAL_SHARDS}" k6_cmd run \
    ${k6_output_flags[@]+"${k6_output_flags[@]}"} \
    --insecure-skip-tls-verify \
    --tag testid="$TESTID" \
    --tag machine="$MACHINE_NAME" \
    $extra_flags \
    "test/k6/$script_name"
}

# 1. Read heavy (01-read-products.js)
if [[ "$TARGET_SCENARIO" == "all" || "$TARGET_SCENARIO" == "1" || "$TARGET_SCENARIO" == "01" ]]; then
  sync_barrier "1" "Read-heavy products catalogue (01-read-products.js)"
  run_scenario "01-read-products.js" "Scenario 1: Read-heavy products catalogue"
fi

# 2. Write sales contention (02-write-sales-contention.js)
if [[ "$TARGET_SCENARIO" == "all" || "$TARGET_SCENARIO" == "2" || "$TARGET_SCENARIO" == "02" ]]; then
  sync_barrier "2" "Write sales contention (02-write-sales-contention.js)"
  run_scenario "02-write-sales-contention.js" "Scenario 2: Write sales contention (200 on 50 stock)"

  # Integrity Check prompt after Scenario 2 finishes
  if [[ "$SHARD_INDEX" == "1" ]]; then
    echo ""
    echo "================================================================="
    echo " 🔍 [INTEGRITY CHECK REQUIRED]"
    echo " Shard 1 is the coordinator. Running verify-integrity before any re-seeding!"
    echo "================================================================="
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
      pnpm k6:verify || true
    else
      read -r -p ">>> Run 'pnpm k6:verify' now? [Y/n]: " do_verify
      if [[ ! "$do_verify" =~ ^[Nn] ]]; then
        pnpm k6:verify
      else
        echo "⚠️ Skipped pnpm k6:verify. Remember to run it before re-seeding!"
      fi
    fi
  fi
fi

# 3. Idempotent replay (03-idempotent-replay.js)
if [[ "$TARGET_SCENARIO" == "all" || "$TARGET_SCENARIO" == "3" || "$TARGET_SCENARIO" == "03" ]]; then
  sync_barrier "3" "Idempotent sales replay (03-idempotent-replay.js)"
  run_scenario "03-idempotent-replay.js" "Scenario 3: Idempotent sales replay"
fi

# 4. Mixed workload (04-mixed-workload.js)
if [[ "$TARGET_SCENARIO" == "all" || "$TARGET_SCENARIO" == "4" || "$TARGET_SCENARIO" == "04" ]]; then
  sync_barrier "4" "Mixed 80/20 workload ($MIXED_DURATION) (04-mixed-workload.js)"
  run_scenario "04-mixed-workload.js" "Scenario 4: Mixed 80/20 workload" "-e DURATION=$MIXED_DURATION ${MIXED_EXTRA_FLAGS:-}"
fi

echo ""
echo "================================================================="
echo "✅ k6 Run finished for target '$TARGET_SCENARIO' on Shard $SHARD_INDEX/$TOTAL_SHARDS!"
echo "Test ID:      $TESTID"
echo "Machine:      $MACHINE_NAME"
echo "Prometheus:   ${K6_PROMETHEUS_RW_SERVER_URL:-<local terminal only>}"
echo "================================================================="

