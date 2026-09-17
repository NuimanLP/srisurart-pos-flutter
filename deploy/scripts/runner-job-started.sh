#!/usr/bin/env bash
# Job-started hook for the demo VM's self-hosted runner (#67, 07_CICD_DEPLOY.md §6.2).
# Installed root-owned and named by ACTIONS_RUNNER_HOOK_JOB_STARTED in the runner's .env; a non-zero
# exit fails the job before any of its steps run. It admits exactly one workflow: this repo's
# deploy.yml as it is on `main`, started by workflow_run or workflow_dispatch. Anything else that
# reaches the runner's label — a branch push, a dispatch of a modified copy from another branch, a
# fork PR someone approved — is refused here, whatever its own `if:` says.
#
# Fails closed: a variable the runner does not pass reads as empty and is refused. The owner confirms
# on the first real run that the admitted job's log shows the three values (07 §6.2 step 6).
set -u

readonly WANT_REPO="NuimanLP/srisurart-pos-flutter"
readonly WANT_WORKFLOW_REF="${WANT_REPO}/.github/workflows/deploy.yml@refs/heads/main"

echo "runner-job-started: repository=${GITHUB_REPOSITORY:-<unset>} workflow_ref=${GITHUB_WORKFLOW_REF:-<unset>} event=${GITHUB_EVENT_NAME:-<unset>}"

refuse() {
  echo "::error::This runner only runs ${WANT_WORKFLOW_REF} (workflow_run / workflow_dispatch). Refused: $1"
  exit 1
}

[[ "${GITHUB_REPOSITORY:-}" == "$WANT_REPO" ]] || refuse "repository"
[[ "${GITHUB_WORKFLOW_REF:-}" == "$WANT_WORKFLOW_REF" ]] || refuse "workflow ref"
case "${GITHUB_EVENT_NAME:-}" in
  workflow_run | workflow_dispatch) ;;
  *) refuse "event" ;;
esac
exit 0
