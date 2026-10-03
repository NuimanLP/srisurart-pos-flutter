#!/usr/bin/env bash
# Tests for deploy/scripts/check-migrations-immutable.sh against a throwaway git repo:
# adding a migration passes; editing, deleting or renaming one fails; base-branch commits made
# after the branch was cut never count. Usage: deploy/scripts/test/check-migrations-immutable.test.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/check-migrations-immutable.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g init -q -b main .
mkdir -p server/src/db/migrations
echo one > server/src/db/migrations/0001-One.ts
echo two > server/src/db/migrations/0002-Two.ts
g add -A && g commit -qm base
BASE="$(git rev-parse HEAD)"

fails=0
expect() { # description, want-rc, ref
  local d="$1" want="$2" ref="$3" rc=0
  bash "$SCRIPT" "$BASE" "$ref" >"$WORK/out.log" 2>&1 || rc=$?
  if { [[ "$want" == 0 ]] && [[ $rc == 0 ]]; } || { [[ "$want" != 0 ]] && [[ $rc != 0 ]]; }; then
    echo "ok   - $d"
  else
    echo "FAIL - $d (rc=$rc)"; cat "$WORK/out.log"; fails=$((fails + 1))
  fi
}
branch() { g switch -q -c "$1" "$BASE"; }

branch add
echo three > server/src/db/migrations/0003-Three.ts
echo other > README.md
g add -A && g commit -qm add
expect "adding a migration (and other files) passes" 0 add

branch edit
echo changed >> server/src/db/migrations/0001-One.ts
g commit -qam edit
expect "editing an existing migration fails" 1 edit

branch delete
g rm -q server/src/db/migrations/0002-Two.ts
g commit -qm delete
expect "deleting an existing migration fails" 1 delete

branch rename
g mv server/src/db/migrations/0002-Two.ts server/src/db/migrations/0002-Renamed.ts
g commit -qm rename
expect "renaming an existing migration fails" 1 rename

# main moves on (a migration edited on main itself, e.g. before this check existed) after
# `add` was cut: the merge-base comparison must not blame the branch for it.
g switch -q main
echo hotfix >> server/src/db/migrations/0001-One.ts
g commit -qam hotfix
BASE="$(git rev-parse main)"
expect "a change only on the base branch is not counted" 0 add

if [[ $fails -gt 0 ]]; then echo "$fails failing"; exit 1; fi
echo "all passed"
