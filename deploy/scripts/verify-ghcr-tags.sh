#!/usr/bin/env bash
# Helper script to verify that both server and web release images exist in GHCR (ADR-0013, 07_CICD_DEPLOY.md §6.1).
# Usage: ./deploy/scripts/verify-ghcr-tags.sh <image_tag>
# Exit codes:
#   0  both images exist
#   1  at least one image is missing (GHCR answered 404) — "not yet", the normal first-completion case
#   2  the registry could not be asked (no token, network error, any status other than 200/404) or bad usage
# .github/workflows/deploy.yml treats 1 as a quiet skip and 2 as a red run (#67): a GHCR outage must
# not look like "the other image is not built yet".
set -euo pipefail

TAG="${1:-}"

if [[ -z "$TAG" ]]; then
  echo "Usage: $0 <image_tag>" >&2
  exit 2
fi

check_ghcr_tag() {
  local repo="$1"
  local tag="$2"

  echo "Checking GHCR for ${repo}:${tag}..."

  # Request anonymous bearer token for the public repository
  local token_resp
  token_resp=$(curl -fsSL --max-time 10 "https://ghcr.io/token?scope=repository:${repo}:pull" 2>/dev/null || echo "")

  if [[ -z "$token_resp" ]]; then
    echo "  -> Failed to acquire anonymous token for ${repo}" >&2
    return 2
  fi

  local token
  token=$(echo "$token_resp" | grep -o '"token":"[^"]*' | cut -d'"' -f4)

  if [[ -z "$token" ]]; then
    echo "  -> Extracted empty token for ${repo}" >&2
    return 2
  fi

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    -H "Accept: application/vnd.oci.image.index.v1+json" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    "https://ghcr.io/v2/${repo}/manifests/${tag}" 2>/dev/null || echo "000")

  case "$http_code" in
    200)
      echo "  -> Found ${repo}:${tag} (HTTP 200)"
      return 0
      ;;
    404)
      echo "  -> Missing ${repo}:${tag} (HTTP 404)"
      return 1
      ;;
    *)
      echo "  -> Could not check ${repo}:${tag} (HTTP ${http_code})" >&2
      return 2
      ;;
  esac
}

SERVER_REPO="nuimanlp/srisurart-pos-server"
WEB_REPO="nuimanlp/srisurart-pos-web"

# Check both even when the first is missing, so an error on the second is never hidden behind "not yet".
server_rc=0
check_ghcr_tag "$SERVER_REPO" "$TAG" || server_rc=$?
web_rc=0
check_ghcr_tag "$WEB_REPO" "$TAG" || web_rc=$?

if [[ "$server_rc" == 2 || "$web_rc" == 2 ]]; then
  echo "Could not verify the release images for '${TAG}' on GHCR." >&2
  exit 2
fi

if [[ "$server_rc" != 0 || "$web_rc" != 0 ]]; then
  echo "Release images for '${TAG}' are not both on GHCR yet (server: ${server_rc}, web: ${web_rc}; 0 = present)." >&2
  exit 1
fi

echo "Both server and web images for tag '${TAG}' are verified on GHCR."
exit 0
