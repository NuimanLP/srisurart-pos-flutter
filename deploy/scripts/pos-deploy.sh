#!/usr/bin/env bash
# pos-deploy — deploy one release to the demo VM, with automatic rollback (#67, 07_CICD_DEPLOY.md §6.1–6.2,
# ADR-0013 addendum 2026-09-15).
#
#   pos-deploy auto   <40-hex sha>   # from a workflow_run: never moves the VM to an older release
#   pos-deploy manual <40-hex sha>   # from workflow_dispatch: may go back (that is how a manual rollback works)
#
# Installed root-owned at /usr/local/bin/pos-deploy and run by the self-hosted runner's user
# (`gha-runner`, no docker group) through ONE sudoers rule, as `deploy`:
#   Defaults!/usr/local/bin/pos-deploy env_reset
#   gha-runner ALL=(deploy) NOPASSWD: /usr/local/bin/pos-deploy
# So a job on that runner — including one that should never have reached it — can do nothing with
# the docker group or /opt/pos/.env except redeploy a commit that is already on `main`. That is why
# this script, not the job, fetches the repo and checks the commit out: the playbook and compose
# files it runs come from GitHub's `main`, never from the job's workspace. Changing this file in the
# repo changes nothing on the VM until the owner reinstalls it (07 §6.2).
set -euo pipefail

readonly REPO_URL="https://github.com/NuimanLP/srisurart-pos-flutter.git"
readonly APP_DIR="/opt/pos"
readonly STATE_DIR="/home/deploy/pos-deploy"
readonly CLONE="$STATE_DIR/repo"
# Releases before #233 crash-loop on a real host (no POSTGRES_PASSWORD in the app containers, and a
# forgeable JWT_PLATFORM_SECRET fallback), so nothing older is ever deployed here, rollback included.
readonly ROLLBACK_FLOOR="4f3a24447094547bdcc00486bd29b53833f81c3f"
# A hung compose command must fail this attempt (and so trigger the rollback) instead of running
# into the job's timeout. Budget against the job's timeout-minutes (50): two attempts (deploy +
# rollback) × (20 min + 1 min kill grace) = 42 min, which leaves 8 min for the lock wait, the
# fetch and the checkouts — hence a 5-minute lock wait.
readonly PLAYBOOK_TIMEOUT_SECONDS=1200
readonly KILL_GRACE_SECONDS=60
readonly LOCK_WAIT_SECONDS=300
# The whole output of the deploy section, also kept here in case the job log went away (a cancelled run).
readonly LOG="$STATE_DIR/last-deploy.log"

die() { echo "::error::pos-deploy: $*"; exit 1; }

[[ "$(id -un)" == "deploy" ]] || die "must run as deploy (sudo -n -u deploy $0 ...)"
export HOME=/home/deploy

mode="${1:-}"
release="${2:-}"
[[ "$mode" == "auto" || "$mode" == "manual" ]] || die "usage: pos-deploy auto|manual <40-hex sha>"
[[ "$release" =~ ^[0-9a-f]{40}$ ]] || die "usage: pos-deploy auto|manual <40-hex sha>"

mkdir -p "$STATE_DIR"
# The workflow serialises deploys; this lock also serialises anything else that calls the script.
exec 9>"$STATE_DIR/lock"
flock -w "$LOCK_WAIT_SECONDS" 9 \
  || die "another pos-deploy still holds the lock after ${LOCK_WAIT_SECONDS}s (a cancelled run's deploy may still be finishing; see $LOG)"

if [[ ! -d "$CLONE/.git" ]]; then
  git clone --quiet --no-checkout "$REPO_URL" "$CLONE"
fi
git -C "$CLONE" fetch --quiet --prune origin "+refs/heads/main:refs/remotes/origin/main"

# A commit this repo's main contains, at or after the floor. Unknown commits fail both checks.
deployable() {
  git -C "$CLONE" merge-base --is-ancestor "$1" origin/main 2>/dev/null \
    && git -C "$CLONE" merge-base --is-ancestor "$ROLLBACK_FLOOR" "$1" 2>/dev/null
}

checkout() {
  git -C "$CLONE" checkout --quiet --force --detach "$1"
  git -C "$CLONE" clean --quiet -ffdx
}

# run_playbook <sha> [extra ansible-playbook args...] — the files and the images of one release.
# The playbook runs in its own session (setsid), so a signal sent to this script's process group
# never reaches it, and with INT/TERM/HUP ignored (see below) it inherits them ignored. GNU `timeout`
# is deliberately not used: it installs its own INT/TERM handlers, so the command it execs gets
# them back at their defaults and a cancelled run would stop the playbook between two API restarts.
# The watchdog is a separate session too, killed as a group when the playbook ends in time.
run_playbook() {
  local sha="$1"
  shift
  local pid watchdog rc=0
  # </dev/null: ansible-core refuses non-blocking stdio (handoff 2026-09-15 §4).
  (
    cd "$CLONE/deploy/ansible"
    # Relies on setsid NOT forking (this subshell is not a group leader), so $! is the playbook's pid
    # and its process group; never add `set -m` or `setsid -f`.
    IMAGE_TAG="$sha" exec setsid ansible-playbook -i 'vm-demo,' \
      -e ansible_connection=local \
      -e ansible_python_interpreter=/usr/bin/python3 \
      "$@" deploy.yml </dev/null
  ) &
  pid=$!
  # Same as above: setsid must not fork, so $! is the watchdog's pid and process group (no `set -m`, no `setsid -f`).
  # shellcheck disable=SC2016 # $1..$3 are the positional arguments passed to bash -c below
  setsid bash -c 'sleep "$1"; kill -TERM -- "-$2"; sleep "$3"; kill -KILL -- "-$2"' \
    watchdog "$PLAYBOOK_TIMEOUT_SECONDS" "$pid" "$KILL_GRACE_SECONDS" </dev/null >/dev/null 2>&1 &
  watchdog=$!
  disown "$watchdog" # no "Killed" job notice when it is stopped below
  wait "$pid" || rc=$?
  kill -KILL -- "-$watchdog" 2>/dev/null || true
  if [[ "$rc" == 137 || "$rc" == 143 ]]; then
    echo "::error::pos-deploy: the playbook for $sha was killed after ${PLAYBOOK_TIMEOUT_SECONDS}s"
  fi
  return "$rc"
}

deployable "$release" || die "$release is not a commit on main at or after $ROLLBACK_FLOOR; nothing deployed"

running=""
if [[ -r "$APP_DIR/.current_sha" ]]; then
  running="$(tr -d '[:space:]' < "$APP_DIR/.current_sha")"
fi
if [[ -n "$running" && ! "$running" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::warning::pos-deploy: $APP_DIR/.current_sha does not hold a commit SHA; no automatic rollback this run"
  running=""
fi
echo "pos-deploy: running=${running:-<none>} release=$release mode=$mode"

# A slow or re-run CI workflow for an older commit can complete after a newer release is live.
if [[ "$mode" == "auto" && -n "$running" && "$running" != "$release" ]] \
   && git -C "$CLONE" merge-base --is-ancestor "$release" "$running" 2>/dev/null; then
  echo "::notice::pos-deploy: not deploying $release; the VM already runs $running, which is newer"
  exit 0
fi

# From here on the VM can change, so a cancelled workflow run must not stop us between two API
# restarts, or between a failed deploy and its rollback. Cancelling a run in the Actions UI signals
# the step (INT, then TERM, then a kill of the processes the runner user may kill — not these,
# which run as `deploy`); sudo relays INT/TERM/HUP to this script, which ignores them, and so do the
# playbook and tee it starts. The deploy therefore always runs to its end, rollback included
# (07 §6.1). Output also goes to $LOG, and tee keeps writing it when the job log is gone.
trap '' INT TERM HUP
exec > >(tee --output-error=warn "$LOG") 2>&1
tee_pid=$!
# Let tee flush the last lines (the ::error:: annotation) to the job log before sudo returns.
trap 'exec >&- 2>&-; wait "$tee_pid" 2>/dev/null' EXIT

checkout "$release"
if run_playbook "$release"; then
  exit 0
fi
echo "::error::pos-deploy: release $release failed to deploy"

# Automatic rollback. deploy.yml writes .current_sha only after /health/ready returned 200 through
# Nginx, so it still names the release that was live before this attempt.
if [[ -z "$running" || "$running" == "$release" ]]; then
  die "no earlier release recorded in $APP_DIR/.current_sha to roll back to"
fi
deployable "$running" || die "the running release $running is not on main at or after $ROLLBACK_FLOOR; not rolling back to it"
checkout "$running"
# Releases from before force_redeploy existed would end the play at their duplicate-release check
# and silently roll back nothing. Match the `when:` expression itself, so a comment cannot pass.
grep -Eq 'when:.*not \(force_redeploy \| default\(false\) \| bool\)' "$CLONE/deploy/ansible/deploy.yml" \
  || die "$running's playbook predates force_redeploy; roll back by hand (07 §7)"

echo "::warning::pos-deploy: rolling back to $running (the schema is not rolled back; there are no down-migrations)"
# A rollback after a failure that happened before anything restarted (a pull flake, the network
# pre-flight check) is a wasted rolling restart of the same release, but harmless; the pre-flight
# check fails the same way for every SHA, so that rollback fails too, and .current_sha is untouched.
if run_playbook "$running" -e force_redeploy=true; then
  die "rolled back to $running; release $release is NOT deployed"
fi
die "rollback to $running failed as well; the VM may be running a mix of releases (07 §7)"
