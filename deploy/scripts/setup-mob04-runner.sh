#!/usr/bin/env bash
# setup-mob04-runner.sh — Automated installer for the GitHub Actions self-hosted runner
# on the demo VM (mob04), complying with 07_CICD_DEPLOY.md §6.2 and ADR-0013.
#
# Usage:
#   sudo ./setup-mob04-runner.sh <RUNNER_REGISTRATION_TOKEN> [RUNNER_VERSION]
#
# Examples:
#   sudo ./setup-mob04-runner.sh AABBCCDDEEFFGG123456789
#   sudo ./setup-mob04-runner.sh AABBCCDDEEFFGG123456789 2.322.0
#
set -euo pipefail

readonly REPO_URL="https://github.com/NuimanLP/srisurart-pos-flutter"
readonly RUNNER_NAME="mob04-demo"
readonly RUNNER_LABELS="srisurart-demo-deploy"
readonly DEFAULT_RUNNER_VER="2.322.0"

if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root (or with sudo)." >&2
  exit 1
fi

TOKEN="${1:-}"
RUNNER_VER="${2:-$DEFAULT_RUNNER_VER}"

if [[ -z "$TOKEN" ]]; then
  echo "Error: GitHub Actions runner registration token is required." >&2
  echo "Usage: sudo $0 <REGISTRATION_TOKEN> [RUNNER_VERSION]" >&2
  echo "Generate token at: GitHub Repo -> Settings -> Actions -> Runners -> New self-hosted runner" >&2
  echo "or via CLI: gh api -X POST repos/NuimanLP/srisurart-pos-flutter/actions/runners/registration-token --jq .token" >&2
  exit 1
fi

echo "================================================================="
echo " Starting mob04 self-hosted runner setup (#67 cd.2-run)"
echo " Target repository: $REPO_URL"
echo " Runner name:       $RUNNER_NAME"
echo " Runner labels:     $RUNNER_LABELS"
echo " Runner version:    $RUNNER_VER"
echo "================================================================="

# 1. Prerequisites check & installation
echo "[1/8] Installing prerequisite packages..."
apt-get update -qq
apt-get install -y -qq ansible-core git curl tar

# 2. Locate or fetch deploy scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_SRC=""

if [[ -f "$SCRIPT_DIR/pos-deploy.sh" && -f "$SCRIPT_DIR/runner-job-started.sh" ]]; then
  POS_DEPLOY_SRC="$SCRIPT_DIR/pos-deploy.sh"
  HOOK_SRC="$SCRIPT_DIR/runner-job-started.sh"
else
  echo "[2/8] Fetching pos-deploy scripts from repository main branch..."
  TEMP_SRC="$(mktemp -d)"
  git clone --depth 1 "$REPO_URL.git" "$TEMP_SRC"
  POS_DEPLOY_SRC="$TEMP_SRC/deploy/scripts/pos-deploy.sh"
  HOOK_SRC="$TEMP_SRC/deploy/scripts/runner-job-started.sh"
fi

# Cleanup temp git clone on exit
cleanup() {
  if [[ -n "$TEMP_SRC" && -d "$TEMP_SRC" ]]; then
    rm -rf "$TEMP_SRC"
  fi
}
trap cleanup EXIT

# 3. Create gha-runner user
echo "[3/8] Configuring gha-runner user..."
if ! id "gha-runner" &>/dev/null; then
  useradd --create-home --shell /bin/bash gha-runner
  echo "  Created user gha-runner (no password, not in docker group)."
else
  echo "  User gha-runner already exists."
fi

# Verify gha-runner is NOT in docker or deploy group
if id -nG "gha-runner" | grep -qE "\b(docker|deploy)\b"; then
  echo "Error: gha-runner must NOT be in docker or deploy group (security constraint ADR-0013 §6.2)." >&2
  exit 1
fi

if [[ -d "/home/deploy" ]]; then
  chmod 0750 /home/deploy
  echo "  Secured /home/deploy mode to 0750."
fi

# 4. Install scripts & hooks
echo "[4/8] Installing /usr/local/bin/pos-deploy and job-started.sh hook..."
install -o root -g root -m 0755 "$POS_DEPLOY_SRC" /usr/local/bin/pos-deploy
install -d -o root -g root -m 0755 /usr/local/lib/pos-runner
install -o root -g root -m 0755 "$HOOK_SRC" /usr/local/lib/pos-runner/job-started.sh

# 5. Configure sudoers safely
echo "[5/8] Configuring sudoers for gha-runner..."
t="$(mktemp)"
printf '%s\n' \
  'Defaults!/usr/local/bin/pos-deploy env_reset' \
  'gha-runner ALL=(deploy) NOPASSWD: /usr/local/bin/pos-deploy' > "$t"

if visudo -cf "$t"; then
  install -o root -g root -m 0440 "$t" /etc/sudoers.d/pos-deploy
  rm -f "$t"
  echo "  Installed /etc/sudoers.d/pos-deploy successfully."
else
  rm -f "$t"
  echo "Error: visudo verification failed for generated sudoers rules." >&2
  exit 1
fi

# Verify sudo execution as deploy
echo "  Testing sudo rule for gha-runner..."
if sudo -u gha-runner sudo -n -u deploy /usr/local/bin/pos-deploy 2>&1 | grep -q usage; then
  echo "  sudoers verification PASSED (pos-deploy returned expected usage)."
else
  echo "Error: sudo -n -u deploy /usr/local/bin/pos-deploy failed from gha-runner." >&2
  exit 1
fi

# 6. Install Actions Runner
echo "[6/8] Downloading and configuring GitHub Actions Runner..."
RUNNER_HOME="/home/gha-runner"
RUNNER_DIR="$RUNNER_HOME/actions-runner"

mkdir -p "$RUNNER_DIR"
chown -R gha-runner:gha-runner "$RUNNER_DIR"

RUNNER_ARCHIVE="actions-runner-linux-x64-${RUNNER_VER}.tar.gz"
DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VER}/${RUNNER_ARCHIVE}"

sudo -u gha-runner bash -c '
  set -euo pipefail
  repo_url="$1"
  token="$2"
  name="$3"
  labels="$4"
  download_url="$5"
  runner_dir="$6"

  cd "$runner_dir"
  if [[ ! -f config.sh ]]; then
    echo "  Downloading $download_url..."
    curl -fsSLo runner.tar.gz "$download_url"
    tar xzf runner.tar.gz && rm -f runner.tar.gz
  fi

  echo "  Registering runner with GitHub..."
  ./config.sh --unattended \
    --url "$repo_url" \
    --token "$token" \
    --name "$name" \
    --labels "$labels" \
    --work _work \
    --replace

  echo "  Configuring job-started hook in runner environment..."
  if ! grep -q "ACTIONS_RUNNER_HOOK_JOB_STARTED" .env 2>/dev/null; then
    echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/lib/pos-runner/job-started.sh" >> .env
  fi
' _ "$REPO_URL" "$TOKEN" "$RUNNER_NAME" "$RUNNER_LABELS" "$DOWNLOAD_URL" "$RUNNER_DIR"

# 7. Install & Start Systemd Service
echo "[7/8] Installing and starting runner service..."
cd "$RUNNER_DIR"

if ./svc.sh status 2>/dev/null | grep -q "active (running)"; then
  echo "  Runner service already running, restarting..."
  ./svc.sh stop || true
  ./svc.sh uninstall || true
fi

./svc.sh install gha-runner
./svc.sh start

# 8. Final Status Check
echo "[8/8] Verifying runner service status..."
./svc.sh status

echo "================================================================="
echo "✅ mob04 self-hosted runner setup complete!"
echo "Runner Name:   $RUNNER_NAME"
echo "Runner Labels: $RUNNER_LABELS"
echo "Status:        Active (running as systemd service)"
echo ""
echo "Next steps (07_CICD_DEPLOY.md §6.2 Step 6 & 7):"
echo "1. Verify in GitHub: Settings -> Actions -> Runners"
echo "   Should see '$RUNNER_NAME' with status 'Idle/Online' and label '$RUNNER_LABELS'."
echo "2. Trigger Deploy (demo) workflow on main and verify:"
echo "   - Hook admits the job and logs repository/workflow_ref/event"
echo "   - Playbook completes with failed=0"
echo "   - .current_sha is updated"
echo "================================================================="
