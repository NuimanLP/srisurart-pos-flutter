# Guide & Runbook: Slice 25 (#67 `cd.2-run`) — Self-Hosted Runner on `mob04`

This document details the exact execution steps and Acceptance Criteria (AC) verification to complete **Slice 25 (#67 `cd.2-run`)** for Lane C (`team/3` PattaraponKitcharoen), per `docs/Backend_design/07_CICD_DEPLOY.md §6.2` and `ADR-0013`.

---

## 1. Prerequisites & Environment Setup

### 1.1 GitHub Repository Security Gates (Required before registering runner)

Because the repository is **public**, these settings are mandatory security constraints:

1. **Fork PR Contributor Approval**:
   - **Via GitHub Web UI**: `Settings` → `Actions` → `General` → *Approval for running fork pull request workflows from contributors* = **Require approval for all external contributors**.
   - **Via GitHub CLI (`gh`)**:
     ```bash
     gh api -X PUT repos/NuimanLP/srisurart-pos-flutter/actions/permissions/fork-pr-contributor-approval \
       -f approval_policy=all_external_contributors
     ```

2. **Environment `demo` Branch Policy**:
   - **Via GitHub Web UI**: `Settings` → `Environments` → `demo` → `Deployment branches` = Selected branches (`main` only). No required reviewers. No secrets needed.
   - **Via GitHub CLI (`gh`)**:
     ```bash
     gh api -X PUT repos/NuimanLP/srisurart-pos-flutter/environments/demo --input - <<'JSON'
     { "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true } }
     JSON
     gh api -X POST repos/NuimanLP/srisurart-pos-flutter/environments/demo/deployment-branch-policies \
       -f name=main -f type=branch
     ```

---

## 2. Runner Installation on `mob04` (`172.30.58.20`)

### 2.1 Obtain Runner Registration Token (Valid for 1 hour)
- **Via GitHub Web UI**: Go to `Settings` → `Actions` → `Runners` → Click `New self-hosted runner` (Linux x64). Copy the token string after `--token`.
- **Via GitHub CLI (`gh`)**:
  ```bash
  gh api -X POST repos/NuimanLP/srisurart-pos-flutter/actions/runners/registration-token --jq .token
  ```
  *(Never commit or paste this token into chat/logs).*

### 2.2 Automated Execution on `mob04`

SSH into `mob04` as user `cloud` (using the campus network / VPN):
```bash
ssh cloud@172.30.58.20
```

Run the turnkey automated installer:
```bash
# Clone or update repository
git clone https://github.com/NuimanLP/srisurart-pos-flutter.git /tmp/pos-install 2>/dev/null || (cd /tmp/pos-install && git pull)
cd /tmp/pos-install

# Run the installer with your token
sudo ./deploy/scripts/setup-mob04-runner.sh <YOUR_REGISTRATION_TOKEN>
```

The script automatically performs:
1. Package installation: `ansible-core`, `git`, `curl`, `tar`.
2. Dedicated user creation: `gha-runner` without password and **strictly without docker/deploy groups**.
3. Perms lock: `chmod 0750 /home/deploy`.
4. Installs wrapper `/usr/local/bin/pos-deploy` and hook `/usr/local/lib/pos-runner/job-started.sh`.
5. Atomic sudoers validation and placement in `/etc/sudoers.d/pos-deploy` via `visudo -cf`.
6. Configures runner unattended with name `mob04-demo` and label `srisurart-demo-deploy`.
7. Enforces `ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/lib/pos-runner/job-started.sh`.
8. Installs and starts the runner systemd service (`active (running)`).

---

## 3. Acceptance Criteria (AC) Verification Checklist

To close Issue #67 (`cd.2-run`), execute and record the following 3 tests:

### ✅ AC 1: Automatic Deploy on Push to `main`
1. Push/merge a commit to `main`.
2. Observe `.github/workflows/deploy.yml`:
   - Both `Server CI` and `Flutter CI` finish `success`.
   - `resolve` job checks GHCR images and succeeds.
   - `deploy` job runs on `[self-hosted, srisurart-demo-deploy]`.
3. Check the job log:
   - Hook prints:
     ```text
     runner-job-started: repository=NuimanLP/srisurart-pos-flutter workflow_ref=.../.github/workflows/deploy.yml@refs/heads/main event=workflow_run
     ```
   - Playbook completes with `failed=0`.
4. On `mob04`:
   ```bash
   cat /opt/pos/.current_sha
   ```
   Matches the newly merged `main` commit SHA.

### ✅ AC 2: Non-main / Fork Job Refusal (Fail-Closed Hook)
1. Trigger a workflow dispatch or job against the runner from a branch other than `main` or a fork.
2. Hook immediately prints:
   ```text
   ::error::This runner only runs NuimanLP/srisurart-pos-flutter/.github/workflows/deploy.yml@refs/heads/main ... Refused: workflow ref
   ```
3. Job fails with exit code 1 *before* any deploy step runs.

### ✅ AC 3: Playbook Failure & Automatic Rollback
1. Trigger a manual deploy with a commit or simulated fault that fails playbook health check.
2. Verify `pos-deploy` catches the failure, invokes automatic rollback to `.current_sha` with `-e force_redeploy=true`.
3. The workflow run ends in a red/failed state, but `/opt/pos` remains on the last known-good release and `/health/ready` returns 200.
