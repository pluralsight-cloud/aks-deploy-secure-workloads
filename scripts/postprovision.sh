#!/usr/bin/env bash
# azd postprovision hook for Linux/macOS
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/env.sh"

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-$RESOURCE_GROUP}"
CLUSTER_NAME="${AZURE_AKS_CLUSTER_NAME:-$CLUSTER_NAME}"
REGISTRY_NAME="${AZURE_CONTAINER_REGISTRY_NAME:-$REGISTRY_NAME}"
KEY_VAULT_NAME="${AZURE_KEY_VAULT_NAME:-$KEY_VAULT_NAME}"
LOCATION="${AZURE_LOCATION:-$LOCATION}"
NAMESPACE="${NAMESPACE:-orders}"
export RESOURCE_GROUP CLUSTER_NAME REGISTRY_NAME KEY_VAULT_NAME LOCATION NAMESPACE

bash "$REPO_ROOT/scripts/check-prerequisites.sh"

printf '\n\033[1m== Running Post-Provision Configuration ==\033[0m\n'

bash "$REPO_ROOT/scripts/configure-platform.sh"

printf 'Building and pushing orders-api:1.0.0 image to ACR...\n'
bash "$REPO_ROOT/scripts/build-images.sh"

printf '\n\033[1;32m== Environment is fully ready for the course! ==\033[0m\n'
az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
  --query "{version:kubernetesVersion,networkPolicy:networkProfile.networkPolicy,dataplane:networkProfile.networkDataplane,localAccountsDisabled:disableLocalAccounts}" \
  -o table
