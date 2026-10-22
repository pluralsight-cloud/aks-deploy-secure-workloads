#!/usr/bin/env bash
# Read-only, anonymous check that the Module 2 identity-test image can be pulled
# from GHCR the way the cluster pulls it (no credentials).
#
# Usage (from the repo root):
#   bash scripts/check-identity-test-image.sh [image]
#
# Image precedence: explicit argument, then $IDENTITY_TEST_IMAGE, then the image:
# in module-02-workload-identity/orders-api-sa-test.yaml.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

MANIFEST="$REPO_ROOT/module-02-workload-identity/orders-api-sa-test.yaml"

[[ $# -le 1 ]] || die "Usage: bash scripts/check-identity-test-image.sh [image]"
need curl
need jq
IMAGE="${1:-${IDENTITY_TEST_IMAGE:-}}"
if [[ -z "$IMAGE" ]]; then
  IMAGE="$(awk '$1 == "image:" { print $2; exit }' "$MANIFEST")"
fi
[[ -n "$IMAGE" ]] || die "No test image found in $MANIFEST."
[[ "$IMAGE" =~ ^ghcr.io/[a-z0-9._/-]+(:[A-Za-z0-9._-]+|@sha256:[a-f0-9]{64})?$ ]] \
  || die "Expected a GHCR image, optionally with a tag or sha256 digest: $IMAGE"

image_path="${IMAGE#ghcr.io/}"
if [[ "$image_path" == *@* ]]; then
  repository="${image_path%@*}"
  reference="${image_path##*@}"
elif [[ "$image_path" == *:* ]]; then
  repository="${image_path%:*}"
  reference="${image_path##*:}"
else
  repository="$image_path"
  reference=latest
fi
[[ "$repository" == */* ]] || die "Expected a GHCR owner/repository: $IMAGE"

# Docker can discover native credential helpers even with an empty config.
# Request an anonymous registry token directly, without Docker or curl config.
check_dir="$(mktemp -d)"
trap 'rm -f "$check_dir/token.json" "$check_dir/headers" "$check_dir/manifest.json"; rmdir "$check_dir"' EXIT
check_manifest() {
  curl --disable --fail --silent --show-error --connect-timeout 10 --max-time 30 \
    --get --data-urlencode service=ghcr.io \
    --data-urlencode "scope=repository:$repository:pull" \
    --output "$check_dir/token.json" https://ghcr.io/token || return
  local token
  token="$(jq -er '.token | select(type == "string" and length > 0)' "$check_dir/token.json")" \
    || { printf '%s\n' "GHCR returned no anonymous pull token." >&2; return 1; }
  printf 'Authorization: Bearer %s\n' "$token" > "$check_dir/headers"
  curl --disable --fail --silent --show-error --connect-timeout 10 --max-time 30 \
    --header "@$check_dir/headers" \
    --header 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    --output "$check_dir/manifest.json" \
    "https://ghcr.io/v2/$repository/manifests/$reference"
}
printf 'Checking anonymous manifest access: %s\n' "$IMAGE"
if ! check_manifest; then
  printf '%s\n' \
    "The test image is not anonymously accessible, or the registry could not be reached." \
    "A 401/403/404 here is an image-pull problem (tag missing, package private, or wrong name)," \
    "not a Workload Identity failure. Do not change Azure roles or retry identity grants for it." \
    "Use the default public course image, or publish your own with" \
    "  bash apps/identity-test/build-and-push.sh <your-ghcr-owner>" \
    "then set the package visibility to Public and rerun this check with that exact image." >&2
  exit 1
fi
printf 'Anonymous manifest access passed: %s\n' "$IMAGE"
