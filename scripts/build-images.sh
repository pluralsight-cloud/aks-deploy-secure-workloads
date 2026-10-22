#!/usr/bin/env bash
# Builds the Orders API image and stores it in your Azure Container Registry
# as <registry>.azurecr.io/orders-api:1.0.0.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

need az
IMAGE_TAG="${IMAGE_TAG:-1.0.0}"

if az acr build --registry "$REGISTRY_NAME" \
  --image "orders-api:${IMAGE_TAG}" \
  --platform linux/amd64 \
  "$REPO_ROOT/apps/orders-api"; then
  :
else
  printf '%s\n' "ACR Tasks is unavailable here; building locally with Docker instead."
  need docker
  az acr login --name "$REGISTRY_NAME"
  docker buildx build --platform linux/amd64 --push \
    -t "${REGISTRY_NAME}.azurecr.io/orders-api:${IMAGE_TAG}" \
    "$REPO_ROOT/apps/orders-api"
fi

az acr repository show-tags --name "$REGISTRY_NAME" --repository orders-api -o tsv
