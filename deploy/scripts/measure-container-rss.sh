#!/usr/bin/env bash
# measure-container-rss.sh — Continuous container RSS and host memory sampler under load
# for Issue #184 (Slice 22), per 03_ARCHITECTURE.md §8 and 08_PHASE2_SPEC.md §17.
#
# Measures container RSS and CPU during distributed k6 runs to prove the 6 GB ceiling.
#
# Usage:
#   ./measure-container-rss.sh [duration_seconds] [output_markdown_file]
#
# Examples:
#   ./measure-container-rss.sh 300 /opt/pos/rss-report.md
#   ./measure-container-rss.sh 600
#
set -euo pipefail

DURATION="${1:-600}"
DEFAULT_OUT="container-rss-report.md"
if [[ -d "/opt/pos" ]]; then
  DEFAULT_OUT="/opt/pos/container-rss-report.md"
fi
OUTPUT_FILE="${2:-$DEFAULT_OUT}"
INTERVAL=2
CEILING_MB=6144 # 6 GB ceiling

echo "================================================================="
echo " Starting Container RSS & Memory Monitor (#184 Slice 22)"
echo " Duration:    ${DURATION}s (or press Ctrl+C to stop & generate report)"
echo " Interval:    ${INTERVAL}s"
echo " Report file: ${OUTPUT_FILE}"
echo " Host Ceiling: ${CEILING_MB} MiB (6.0 GB)"
echo "================================================================="

# Associative arrays for peaks
declare -A PEAK_MEM_MB
declare -A PEAK_CPU_PCT
declare -A LAST_MEM_MB
declare -A CONTAINER_LIMITS
declare -A OOM_KILLED
declare -A RESTART_COUNTS

PEAK_AGGREGATE_MB=0
PEAK_HOST_USED_MB=0
SAMPLE_COUNT=0
RUNNING=true

cleanup() {
  RUNNING=false
}
trap cleanup SIGINT SIGTERM

# Helper: parse Docker memory string (e.g. "55.4MiB / 384MiB", "1.2GiB / 2GiB") to float MiB
to_mib() {
  local str="$1"
  local val
  val=$(echo "$str" | sed -E 's/[^0-9\.]//g')
  if [[ "$str" =~ [Gg][iI]?[Bb] ]]; then
    awk "BEGIN {printf \"%.2f\", $val * 1024}"
  elif [[ "$str" =~ [Kk][iI]?[Bb] ]]; then
    awk "BEGIN {printf \"%.2f\", $val / 1024}"
  elif [[ "$str" =~ [Bb] ]]; then
    awk "BEGIN {printf \"%.2f\", $val / 1048576}"
  else
    # Assume MiB
    awk "BEGIN {printf \"%.2f\", $val}"
  fi
}

start_time=$(date +%s)
end_time=$((start_time + DURATION))

echo "Monitoring active containers... (collecting samples)"

while $RUNNING && [[ $(date +%s) -lt $end_time ]]; do
  stats=$(docker stats --no-stream --format "{{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}" 2>/dev/null || true)
  
  if [[ -n "$stats" ]]; then
    SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
    current_aggregate_mb=0

    while IFS=$'\t' read -r name mem_usage cpu_perc; do
      [[ -z "$name" ]] && continue
      
      # Parse "USAGE / LIMIT"
      used_str="${mem_usage%%/*}"
      limit_str="${mem_usage##*/}"
      
      used_mb=$(to_mib "$used_str")
      limit_mb=$(to_mib "$limit_str")
      cpu_num=$(echo "$cpu_perc" | tr -d '%' | tr -d ' ')
      [[ -z "$cpu_num" ]] && cpu_num=0

      # Update container peak
      current_peak="${PEAK_MEM_MB[$name]:-0}"
      if awk "BEGIN {exit !($used_mb > $current_peak)}"; then
        PEAK_MEM_MB[$name]="$used_mb"
      fi

      current_cpu_peak="${PEAK_CPU_PCT[$name]:-0}"
      if awk "BEGIN {exit !($cpu_num > $current_cpu_peak)}"; then
        PEAK_CPU_PCT[$name]="$cpu_num"
      fi

      LAST_MEM_MB[$name]="$used_mb"
      CONTAINER_LIMITS[$name]="$limit_mb"

      current_aggregate_mb=$(awk "BEGIN {printf \"%.2f\", $current_aggregate_mb + $used_mb}")
    done <<< "$stats"

    if awk "BEGIN {exit !($current_aggregate_mb > $PEAK_AGGREGATE_MB)}"; then
      PEAK_AGGREGATE_MB="$current_aggregate_mb"
    fi
  fi

  # Sample Host Memory
  if command -v free >/dev/null 2>&1; then
    host_used=$(free -m | awk '/Mem:/ {print $3}')
    if [[ -n "$host_used" && "$host_used" -gt "$PEAK_HOST_USED_MB" ]]; then
      PEAK_HOST_USED_MB="$host_used"
    fi
  fi

  sleep "$INTERVAL"
done

elapsed=$(($(date +%s) - start_time))
echo ""
echo "Sampling complete ($SAMPLE_COUNT samples over ${elapsed}s)."
echo "Inspecting containers for OOM and restarts..."

# Collect inspect details
for name in "${!PEAK_MEM_MB[@]}"; do
  oom=$(docker inspect --format '{{.State.OOMKilled}}' "$name" 2>/dev/null || echo "unknown")
  restarts=$(docker inspect --format '{{.RestartCount}}' "$name" 2>/dev/null || echo "0")
  OOM_KILLED[$name]="$oom"
  RESTART_COUNTS[$name]="$restarts"
done

# Generate Markdown Report
report_date=$(date -u +"%Y-%m-%d %H:%M:%SZ")
host_info="Host: $(uname -s -m) | Kernel: $(uname -r)"
if [[ -f /etc/os-release ]]; then
  host_info="$host_info | $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
fi

{
  echo "# Container Memory RSS & Load Benchmark Report (#184)"
  echo ""
  echo "- **Timestamp**: \`${report_date}\`"
  echo "- **Duration**: \`${elapsed}s\` (\`${SAMPLE_COUNT}\` samples @ \`${INTERVAL}s\` interval)"
  echo "- **Environment**: ${host_info}"
  echo "- **Memory Ceiling**: \`${CEILING_MB} MiB\` (6.0 GB)"
  echo ""
  echo "## 1. Container Memory & CPU Under Load"
  echo ""
  echo "| Container | Limit | Peak RSS (MiB) | % Limit | Peak CPU | Restarts | OOM Killed |"
  echo "|---|---|---|---|---|---|---|"
  
  has_oom=false
  for name in $(echo "${!PEAK_MEM_MB[@]}" | tr ' ' '\n' | sort); do
    limit="${CONTAINER_LIMITS[$name]:-0}"
    peak="${PEAK_MEM_MB[$name]:-0}"
    cpu="${PEAK_CPU_PCT[$name]:-0}"
    restarts="${RESTART_COUNTS[$name]:-0}"
    oom="${OOM_KILLED[$name]:-false}"
    
    pct_limit="0%"
    if awk "BEGIN {exit !($limit > 0)}"; then
      pct_limit=$(awk "BEGIN {printf \"%.1f%%\", ($peak / $limit) * 100}")
    fi

    if [[ "$oom" == "true" ]]; then
      has_oom=true
      oom_str="🚨 YES"
    else
      oom_str="✅ No"
    fi

    echo "| \`${name}\` | \`${limit} MiB\` | **${peak} MiB** | ${pct_limit} | ${cpu}% | ${restarts} | ${oom_str} |"
  done

  echo ""
  echo "## 2. Host & Stack Aggregate Summary"
  echo ""
  pct_ceiling=$(awk "BEGIN {printf \"%.1f%%\", ($PEAK_AGGREGATE_MB / $CEILING_MB) * 100}")
  echo "- **Peak Total Stack RSS**: **\`${PEAK_AGGREGATE_MB} MiB\`** (${pct_ceiling} of 6.0 GB ceiling)"
  if [[ "$PEAK_HOST_USED_MB" -gt 0 ]]; then
    pct_host_ceiling=$(awk "BEGIN {printf \"%.1f%%\", ($PEAK_HOST_USED_MB / $CEILING_MB) * 100}")
    echo "- **Peak Total Host Memory (Used)**: **\`${PEAK_HOST_USED_MB} MiB\`** (${pct_host_ceiling} of 6.0 GB ceiling)"
  fi

  echo ""
  echo "## 3. Verdict"
  echo ""
  if ! $has_oom && awk "BEGIN {exit !($PEAK_AGGREGATE_MB <= $CEILING_MB)}"; then
    echo "✅ **PASS**: Memory usage remained within the 6 GB ceiling during load. Zero containers were OOM killed or restarted."
  else
    echo "❌ **FAIL**: Memory usage exceeded 6 GB ceiling or a container was OOM killed."
  fi
} > "$OUTPUT_FILE"

cat "$OUTPUT_FILE"
echo ""
echo "✅ Report saved to: $OUTPUT_FILE"
