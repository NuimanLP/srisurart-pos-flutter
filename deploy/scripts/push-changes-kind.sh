#!/usr/bin/env bash
# Classify the commits a `push` to main (2026-10-01) or develop (2026-10-07) added as
# "docs only" or "code".
# Used by the `changes` job of server.yml and flutter.yml so a docs-only merge skips the heavy
# test/image jobs — on main therefore no release image and no Deploy awaiting approval. Also used
# by deploy.yml `resolve` (main only).
#
# Env:  BEFORE = github.event.before, SHA = github.sha (needs full history of the range).
# Out:  "code=true|false" on $GITHUB_OUTPUT (stdout if unset).
#
# Conservative by design — `code=true` (run everything) unless EVERY changed file is docs:
#   * any `*.md`, or
#   * anything under docs/ EXCEPT docs/Backend_design/fixtures/ (server/frontend tests read it).
# Everything else — workflows, scripts, .json/.yml anywhere — counts as code. A zero/unknown
# BEFORE (new branch, force-push), a failing diff, or an empty file list also means code=true.
set -uo pipefail

out="${GITHUB_OUTPUT:-/dev/stdout}"
emit() { echo "code=$1" >> "$out"; echo "push classified: code=$1 ($2)"; exit 0; }

before="${BEFORE:-}"
sha="${SHA:?SHA is required}"

if [[ -z "$before" || "$before" =~ ^0+$ ]] || ! git cat-file -e "$before^{commit}" 2>/dev/null; then
  emit true "no usable before commit"
fi
if ! files=$(git diff --no-renames --name-only "$before" "$sha"); then
  emit true "git diff failed"
fi
[[ -n "$files" ]] || emit true "empty diff"

while IFS= read -r f; do
  case "$f" in
    docs/Backend_design/fixtures/*) emit true "fixture: $f" ;;
    docs/*|*.md) ;;
    *) emit true "code path: $f" ;;
  esac
done <<<"$files"
emit false "docs only"
