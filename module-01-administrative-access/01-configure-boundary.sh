#!/usr/bin/env bash
set -Eeuo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-globomantics-aks}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-globomantics-prod}"
NAMESPACE="${NAMESPACE:-orders}"
GROUP_NAME="${GROUP_NAME:-grp-globomantics-orders-operators}"
OPERATOR_OBJECT_ID="${OPERATOR_OBJECT_ID:-}"
CONFIRM_ROTATE_CERTS="${CONFIRM_ROTATE_CERTS:-}"

if [[ -z "$OPERATOR_OBJECT_ID" ]]; then
  printf '%s\n' "Set OPERATOR_OBJECT_ID to the lab operator's Entra object ID."
  exit 1
fi

command -v az >/dev/null || { printf '%s\n' "Azure CLI (az) is required." >&2; exit 1; }

printf 'Signed-in setup identity: '
az account show --query user.name -o tsv

azure_rbac_enabled="$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query aadProfile.enableAzureRbac \
  -o tsv)"
if [[ "$azure_rbac_enabled" != "true" ]]; then
  printf 'Expected Azure RBAC for Kubernetes Authorization to be true; got: %s\n' \
    "$azure_rbac_enabled" >&2
  exit 1
fi

az aks update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --disable-local-accounts

disable_local_accounts="$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query disableLocalAccounts \
  -o tsv)"
if [[ "$disable_local_accounts" != "true" ]]; then
  printf 'Expected disableLocalAccounts=true; got: %s\n' \
    "$disable_local_accounts" >&2
  exit 1
fi

if [[ "$CONFIRM_ROTATE_CERTS" == "YES" ]]; then
  az aks rotate-certs \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CLUSTER_NAME"
else
  printf '%s\n' \
    "Certificate rotation skipped. Set CONFIRM_ROTATE_CERTS=YES to rotate (nodes are recreated; allow up to 30 minutes of downtime)."
fi

group_id="$(az ad group show --group "$GROUP_NAME" --query id -o tsv 2>/dev/null || true)"
if [[ -z "$group_id" ]]; then
  group_id="$(az ad group create \
    --display-name "$GROUP_NAME" \
    --mail-nickname "$GROUP_NAME" \
    --query id \
    -o tsv)"
fi
if [[ -z "$group_id" ]]; then
  printf '%s\n' "Could not resolve the operator group object ID." >&2
  exit 1
fi

# Add the operator to the group (skipped if already a member).
if [[ "$(az ad group member check --group "$group_id" --member-id "$OPERATOR_OBJECT_ID" --query value -o tsv)" != "true" ]]; then
  az ad group member add \
    --group "$group_id" \
    --member-id "$OPERATOR_OBJECT_ID"
fi

aks_id="$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query id \
  -o tsv)"

az role assignment create \
  --assignee-object-id "$group_id" \
  --assignee-principal-type Group \
  --role "Azure Kubernetes Service Cluster User Role" \
  --scope "$aks_id"

az role assignment create \
  --assignee-object-id "$group_id" \
  --assignee-principal-type Group \
  --role "Azure Kubernetes Service RBAC Writer" \
  --scope "$aks_id/namespaces/$NAMESPACE"

printf '%s\n' "Cluster-scope assignment:"
az role assignment list --assignee "$group_id" --scope "$aks_id" -o table
printf '%s\n' "Namespace-scope assignment:"
az role assignment list \
  --assignee "$group_id" \
  --scope "$aks_id/namespaces/$NAMESPACE" \
  -o table
