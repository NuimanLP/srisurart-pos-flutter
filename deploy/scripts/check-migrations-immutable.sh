#!/usr/bin/env bash
# Fails when a change edits, deletes or renames a migration that already exists on the base
# branch (CLAUDE.md: "Applied migrations are never edited" — commit 225ecf7 once did, and every
# database that had run the old text silently kept it). Adding a new migration is allowed; a fix
# to a shipped one is a NEW migration (e.g. 1788652804200-OwnerReviewItemsFixes.ts).
#
#   check-migrations-immutable.sh <base-sha> [<head-sha>]   (head defaults to HEAD)
#
# Compares against the merge base (base...head), so commits that landed on the base branch
# after this branch was cut never count against it. Renames are reported as delete + add
# (--no-renames): moving a migration file changes its identity just as much as editing it.
# Needs both commits and their merge base in the clone (CI: fetch-depth 0).
set -euo pipefail

BASE="${1:?usage: check-migrations-immutable.sh <base-sha> [<head-sha>]}"
HEAD_REF="${2:-HEAD}"
DIR="${MIGRATIONS_DIR:-server/src/db/migrations}"

changed="$(git diff --no-renames --name-status --diff-filter=DMT "$BASE...$HEAD_REF" -- "$DIR/")"

if [[ -n "$changed" ]]; then
  echo "::error::existing migrations were modified or deleted — add a new migration instead:"
  while IFS=$'\t' read -r status path; do
    echo "::error file=$path::$status $path (applied migrations are never edited)"
  done <<< "$changed"
  exit 1
fi
echo "migrations: no existing file under $DIR modified or deleted (base $BASE)"
