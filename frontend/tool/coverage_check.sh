#!/usr/bin/env bash
# Coverage ratchet (2026-10-03). Computes line coverage from an lcov file and
# fails when it drops below the committed baseline.
#
#   tool/coverage_check.sh [lcov.info] [baseline-file]
#
# - Generated code (*.g.dart) is excluded: database.g.dart alone is thousands of
#   lines whose coverage says nothing about the hand-written code.
# - Only files some test imports appear in lcov.info at all; a file no test
#   loads is invisible here (a known limit of `flutter test --coverage`).
# - The baseline is an integer percentage. Raise it by hand (never lower it to
#   make CI green) when coverage has grown by a whole point.
# - Appends a line to $GITHUB_STEP_SUMMARY when that is set.
set -euo pipefail

lcov="${1:-coverage/lcov.info}"
baseline_file="${2:-coverage_baseline.txt}"

[[ -f "$lcov" ]] || { echo "::error::$lcov not found — run flutter test --coverage first"; exit 1; }
[[ -f "$baseline_file" ]] || { echo "::error::$baseline_file not found"; exit 1; }

baseline=$(tr -d '[:space:]' < "$baseline_file")
[[ "$baseline" =~ ^[0-9]+$ ]] || { echo "::error::$baseline_file must hold an integer percentage, got '$baseline'"; exit 1; }

# Sum LF (lines found) / LH (lines hit) over every non-generated record.
read -r found hit < <(awk '
  /^SF:/ { skip = ($0 ~ /\.g\.dart\r?$/) }
  /^LF:/ && !skip { f += substr($0, 4) }
  /^LH:/ && !skip { h += substr($0, 4) }
  END { print f + 0, h + 0 }
' "$lcov")

[[ "$found" -gt 0 ]] || { echo "::error::$lcov has no instrumented lines"; exit 1; }

pct=$(awk -v h="$hit" -v f="$found" 'BEGIN { printf "%.2f", 100 * h / f }')
echo "Line coverage: ${pct}% (${hit}/${found} lines, *.g.dart excluded); baseline ${baseline}%"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  echo "### Flutter line coverage: ${pct}% (baseline ${baseline}%, ${hit}/${found} lines, \`*.g.dart\` excluded)" >> "$GITHUB_STEP_SUMMARY"
fi

if awk -v p="$pct" -v b="$baseline" 'BEGIN { exit !(p < b) }'; then
  echo "::error::Flutter line coverage ${pct}% is below the committed baseline ${baseline}% (frontend/${baseline_file}). Add tests for the code you changed."
  exit 1
fi
