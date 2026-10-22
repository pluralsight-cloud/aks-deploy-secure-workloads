#!/usr/bin/env bash
set -Eeuo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-globomantics-aks}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-globomantics-prod}"

command -v az >/dev/null || { printf '%s\n' "Azure CLI (az) is required." >&2; exit 1; }

printf 'Signed-in setup identity: '
az account show --query user.name -o tsv

set +e
admin_output="$(az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --admin 2>&1)"
admin_status=$?
set -e

printf '%s\n' "$admin_output"
if [[ "$admin_status" -eq 0 ]]; then
  printf '%s\n' "Unexpected success: local admin credentials are still available." >&2
  exit 1
fi
if [[ "$admin_output" != *"Getting static credential isn't allowed because this cluster is set to disable local accounts."* ]]; then
  printf '%s\n' "The command failed, but not with the expected local-account denial." >&2
  exit 1
fi

printf '%s\n' "Verified: the local admin credential path is denied."
