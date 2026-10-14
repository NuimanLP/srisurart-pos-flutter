#!/usr/bin/env bash
# Helper script to verify that both server and web release images exist in GHCR (ADR-0013, 07_CICD_DEPLOY.md §6.1).
# Usage: ./deploy/scripts/verify-ghcr-tags.sh <image_tag> [linux/amd64|linux/arm64]
# With no platform: the tag only has to exist (what deploy.yml's resolve job asks today).
# With a platform: the tag must also hold an image for it. Since the multi-arch release (07 §3) a
# tag is a manifest list / OCI index of linux/amd64 + linux/arm64; a legacy single-image tag (every
# release before it) counts as linux/amd64 only. `linux/arm64/v8` counts as linux/arm64, and the
# `unknown/unknown` attestation entries an index may carry are ignored.
# Exit codes:
#   0  both images exist (and, with a platform, both hold that platform)
#   1  at least one image is missing (GHCR answered 404) — "not yet", the normal first-completion case
#   2  the registry could not be asked (no token, network error, any status other than 200/404), bad
#      usage, an unreadable manifest, or a tag that exists WITHOUT the requested platform (waiting will
#      not add it — that release was simply not built for it)
# .github/workflows/deploy.yml treats 1 as a quiet skip and 2 as a red run (#67): a GHCR outage must
# not look like "the other image is not built yet".
set -euo pipefail

TAG="${1:-}"
PLATFORM="${2:-}"

if [[ -z "$TAG" || $# -gt 2 ]]; then
  echo "Usage: $0 <image_tag> [linux/amd64|linux/arm64]" >&2
  exit 2
fi
case "$PLATFORM" in
  '' | linux/amd64 | linux/arm64) ;;
  *)
    echo "Unsupported platform '${PLATFORM}' (expected linux/amd64 or linux/arm64)." >&2
    exit 2
    ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Prints one os/architecture per image a manifest body holds (variant dropped, so linux/arm64/v8 is
# linux/arm64). An index lists its entries' platforms; a single image manifest names no platform —
# every pre-multi-arch release was built on an amd64 runner, so it is linux/amd64. Returns 1 when
# the body is neither.
manifest_platforms() {
  local flat p os arch
  flat="$(tr -d ' \t\r\n' < "$1")"
  if [[ "$flat" == *'"manifests":['* ]]; then
    while IFS= read -r p; do
      os="$(sed -n 's/.*"os":"\([^"]*\)".*/\1/p' <<<"$p")"
      arch="$(sed -n 's/.*"architecture":"\([^"]*\)".*/\1/p' <<<"$p")"
      echo "${os}/${arch}"
    done < <(grep -o '"platform":{[^}]*}' <<<"$flat" || true)
  elif [[ "$flat" == *'"config":{'* ]]; then
    echo "linux/amd64"
  else
    return 1
  fi
}

# Returns 0 found (with the platform, when one was asked for), 1 not found (404), 2 could not
# check, 3 found but without the requested platform.
check_ghcr_tag() {
  local repo="$1"
  local tag="$2"
  local body="$WORK/${repo//\//_}.json"

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

  # Both list types are accepted: a multi-arch tag is an OCI index or a Docker manifest list
  # (whichever `docker buildx imagetools create` wrote), and a registry may refuse to serve a list
  # type the client did not name.
  local http_code
  http_code=$(curl -s -o "$body" -w "%{http_code}" --max-time 15 \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    -H "Accept: application/vnd.oci.image.index.v1+json" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    "https://ghcr.io/v2/${repo}/manifests/${tag}" 2>/dev/null || echo "000")

  case "$http_code" in
    200)
      if [[ -z "$PLATFORM" ]]; then
        echo "  -> Found ${repo}:${tag} (HTTP 200)"
        return 0
      fi
      local platforms
      if ! platforms="$(manifest_platforms "$body")"; then
        echo "  -> Could not read the manifest of ${repo}:${tag} (neither an index nor an image manifest)" >&2
        return 2
      fi
      if grep -qxF "$PLATFORM" <<<"$platforms"; then
        echo "  -> Found ${repo}:${tag} for ${PLATFORM} (HTTP 200)"
        return 0
      fi
      echo "  -> ${repo}:${tag} exists but holds no ${PLATFORM} image (has: $(grep -vx 'unknown/unknown' <<<"$platforms" | paste -sd' ' -))" >&2
      return 3
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

if [[ "$server_rc" == 3 || "$web_rc" == 3 ]]; then
  echo "Release '${TAG}' was not built for ${PLATFORM} (server: ${server_rc}, web: ${web_rc}; 3 = no ${PLATFORM} image)." >&2
  exit 2
fi

if [[ "$server_rc" != 0 || "$web_rc" != 0 ]]; then
  echo "Release images for '${TAG}' are not both on GHCR yet (server: ${server_rc}, web: ${web_rc}; 0 = present)." >&2
  exit 1
fi

if [[ -n "$PLATFORM" ]]; then
  echo "Both server and web images for tag '${TAG}' are verified on GHCR for ${PLATFORM}."
else
  echo "Both server and web images for tag '${TAG}' are verified on GHCR."
fi
exit 0
