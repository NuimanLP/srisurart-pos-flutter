#!/usr/bin/env bash
# Validation script for deploy/ substrate (ADR-0013, 07_CICD_DEPLOY.md §6).
# Verifies:
# 1. Compose configuration and override merging
# 2. Ansible inventory and playbooks structure
# 3. Playbook syntax check (if ansible-playbook is installed)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

echo "=== 1. Validating Docker Compose Override Merging ==="
IMAGE_TAG="test-sha-validation" \
POS_APP_PASSWORD="dummy_pos_app_password" \
REDIS_PASSWORD="dummy_redis_password" \
POSTGRES_PASSWORD="dummy_postgres_password" \
JWT_PRIVATE_KEY="dummy_private_key" \
JWT_PUBLIC_KEYS='{"dummy":"dummy"}' \
JWT_PLATFORM_SECRET="dummy_jwt_platform_secret" \
BULL_BOARD_PASSWORD="dummy_bull_board_password" \
ETCD_ROOT_PASSWORD="dummy_etcd_password" \
K6_REMOTE_WRITE_BASIC_AUTH_USER="dummy_k6_user" \
K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD="dummy_k6_password" \
docker compose -f server/docker-compose.yml -f deploy/compose/vm.override.yml config --quiet

echo "  -> Compose override merges successfully with zero errors."

echo "=== 1b. Validating the monitoring overlay (#63 ops.1) ==="
IMAGE_TAG="test-sha-validation" \
POS_APP_PASSWORD="dummy_pos_app_password" \
REDIS_PASSWORD="dummy_redis_password" \
POSTGRES_PASSWORD="dummy_postgres_password" \
JWT_PRIVATE_KEY="dummy_private_key" \
JWT_PUBLIC_KEYS='{"dummy":"dummy"}' \
JWT_PLATFORM_SECRET="dummy_jwt_platform_secret" \
BULL_BOARD_PASSWORD="dummy_bull_board_password" \
ETCD_ROOT_PASSWORD="dummy_etcd_password" \
GRAFANA_ADMIN_PASSWORD="dummy_grafana_password" \
K6_REMOTE_WRITE_BASIC_AUTH_USER="dummy_k6_user" \
K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD="dummy_k6_password" \
docker compose -f server/docker-compose.yml -f deploy/compose/vm.override.yml -f deploy/compose/monitoring.yml config --quiet

echo "  -> Base + VM override + monitoring overlay merge successfully with zero errors."

echo "=== 1c. Nginx config syntax check (nginx -t, #251) ==="
if command -v docker >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
  # Under the repo root, not $(mktemp -d): Docker Desktop on Windows/Git Bash cannot bind-mount
  # MSYS's own /tmp (it isn't a real path the daemon can resolve), only a path under a shared
  # drive. Cleaned up unconditionally on exit, success or failure.
  NGINX_TMP="$REPO_ROOT/.tmp-nginx-validate"
  trap 'rm -rf "$NGINX_TMP"' EXIT
  rm -rf "$NGINX_TMP"
  mkdir -p "$NGINX_TMP/certs" "$NGINX_TMP/auth"
  # nginx -t opens every file a directive names (ssl_certificate*, auth_basic_user_file), so a
  # placeholder cert + htpasswd is required even for a pure syntax check — the real ones are
  # generated at container start by certgen / htpasswd-gen. The leading "//" on -subj and on
  # every CONTAINER-side path below is the standard Git-Bash-on-Windows escape: MSYS auto
  # path-converts any argument that looks like a single-leading-slash absolute path (mangling
  # "/CN=localhost" and the container side of -v into Windows paths), but leaves a doubled
  # leading slash alone; the extra slash is a no-op to openssl/Nginx/Docker on Linux (CI), so
  # this needs no OS branch.
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "//CN=localhost" \
    -keyout "$NGINX_TMP/certs/server.key" -out "$NGINX_TMP/certs/server.crt" >/dev/null 2>&1
  printf 'dummy:%s\n' "$(openssl passwd -apr1 dummy)" >"$NGINX_TMP/auth/k6-remote-write.htpasswd"
  docker run --rm \
    -v "$REPO_ROOT/server/docker/nginx/nginx.conf://etc/nginx/nginx.conf:ro" \
    -v "$NGINX_TMP/certs://etc/nginx/certs:ro" \
    -v "$NGINX_TMP/auth://etc/nginx/auth:ro" \
    nginx:1.29-alpine nginx -t
  rm -rf "$NGINX_TMP"
  trap - EXIT
  echo "  -> nginx -t passed."
else
  echo "  -> docker and/or openssl not found in PATH (skipping nginx -t check)."
fi

if command -v promtool >/dev/null 2>&1; then
  promtool check config deploy/prometheus/prometheus.yml
elif command -v docker >/dev/null 2>&1; then
  # promtool's own arg parsing doesn't tolerate the "//cfg"-style escape used above (it takes
  # the doubled slash literally instead of the kernel collapsing it), so this needs the other
  # standard fix instead: MSYS_NO_PATHCONV disables Git Bash's path "correction" outright, which
  # then requires the HOST side already be a native Windows path (cygpath -w). Neither exists on
  # Linux (CI), where no conversion is needed in the first place.
  if command -v cygpath >/dev/null 2>&1; then
    PROMETHEUS_CFG_DIR="$(cygpath -w "$REPO_ROOT/deploy/prometheus")"
  else
    PROMETHEUS_CFG_DIR="$REPO_ROOT/deploy/prometheus"
  fi
  MSYS_NO_PATHCONV=1 docker run --rm --entrypoint promtool -v "$PROMETHEUS_CFG_DIR:/cfg" prom/prometheus:v2.55.1 check config /cfg/prometheus.yml
else
  echo "  -> promtool and docker not found in PATH (skipping Prometheus config check)."
fi

echo "=== 2. Checking File Existence & Basic Structure ==="
REQUIRED_FILES=(
  "deploy/compose/vm.override.yml"
  "deploy/compose/monitoring.yml"
  "deploy/prometheus/prometheus.yml"
  "deploy/grafana/provisioning/datasources/prometheus.yml"
  "deploy/grafana/provisioning/dashboards/dashboards.yml"
  "deploy/grafana/dashboards/pos-overview.json"
  "deploy/ansible/ansible.cfg"
  "deploy/ansible/inventory/hosts.ini"
  "deploy/ansible/provision.yml"
  "deploy/ansible/deploy.yml"
)

for file in "${REQUIRED_FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "ERROR: Missing required deploy file: $file" >&2
    exit 1
  fi
  echo "  -> Found $file"
done

echo "=== 3. Ansible Playbook Syntax Check ==="
if command -v ansible-playbook >/dev/null 2>&1; then
  echo "Running ansible-playbook --syntax-check on host..."
  ansible-playbook -i deploy/ansible/inventory/hosts.ini --syntax-check deploy/ansible/provision.yml
  ansible-playbook -i deploy/ansible/inventory/hosts.ini --syntax-check deploy/ansible/deploy.yml
  echo "  -> Ansible syntax check passed."
elif command -v docker >/dev/null 2>&1; then
  echo "ansible-playbook not found on host. Running syntax check in Docker container..."
  # Same Git-Bash-on-Windows fix as the promtool check above: MSYS_NO_PATHCONV plus a
  # cygpath-converted host path (a no-op on Linux/CI, where cygpath doesn't exist).
  if command -v cygpath >/dev/null 2>&1; then
    REPO_ROOT_HOST="$(cygpath -w "$REPO_ROOT")"
  else
    REPO_ROOT_HOST="$REPO_ROOT"
  fi
  MSYS_NO_PATHCONV=1 docker run --rm -v "$REPO_ROOT_HOST:/repo" -w /repo alpine sh -c "
    apk add --no-cache ansible >/dev/null 2>&1 && \
    ansible-playbook -i deploy/ansible/inventory/hosts.ini --syntax-check deploy/ansible/provision.yml deploy/ansible/deploy.yml
  "
  echo "  -> Containerized Ansible syntax check passed."
else
  echo "  -> ansible-playbook and docker not found in PATH (skipping CLI syntax check)."
fi

echo "=== All deploy validations passed successfully! ==="
