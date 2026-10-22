#!/usr/bin/env bash
# Optional: build the Module 2 identity-test image and push it to YOUR GHCR namespace.
# Normal follow-along does not need this; the course uses a public prebuilt image.
#
# Usage (from the repo root):
#   bash apps/identity-test/build-and-push.sh <ghcr-owner>
#
# Authenticate to GHCR separately first (this script never logs in):
#   gh auth refresh -h github.com -s write:packages
#   gh auth token | docker login ghcr.io --username <ghcr-owner> --password-stdin
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf '%s\n' "$*" >&2; exit 1; }

[[ $# -eq 1 && -n "$1" ]] || die "Usage: bash apps/identity-test/build-and-push.sh <ghcr-owner>
The owner is required so you never publish into someone else's namespace."
OWNER="$1"
[[ "$OWNER" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] \
  || die "Invalid GitHub user or organization name: $OWNER"
OWNER="$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')"

command -v docker >/dev/null 2>&1 || die "docker is required but was not found."
docker buildx version >/dev/null 2>&1 || die "Docker Buildx is required (docker buildx version failed)."

IMAGE="ghcr.io/${OWNER}/orders-identity-test:1.0.1"
printf 'Building and pushing %s (linux/amd64)\n' "$IMAGE"
if ! docker buildx build --platform linux/amd64 --push -t "$IMAGE" "$HERE"; then
  printf '%s\n' \
    "Build or push failed for $IMAGE. Check network access (Docker Hub, PyPI, ghcr.io)," \
    "that you are logged in to ghcr.io, and that your token has write:packages." >&2
  exit 1
fi
printf '%s\n' \
  "Pushed $IMAGE." \
  "Next: set the package visibility to Public (GitHub > Your profile > Packages >" \
  "orders-identity-test > Package settings > Change visibility), then verify anonymously:" \
  "  bash scripts/check-identity-test-image.sh $IMAGE" \
  "Then: export IDENTITY_TEST_IMAGE=$IMAGE   (see apps/identity-test/README.md)"
