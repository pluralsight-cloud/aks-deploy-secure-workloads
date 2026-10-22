#!/usr/bin/env bash
set -Eeuo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-globomantics-aks}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-globomantics-prod}"
ALLOWED_NAMESPACE="${ALLOWED_NAMESPACE:-orders}"
DENIED_NAMESPACE="${DENIED_NAMESPACE:-kube-system}"

command -v az >/dev/null || { printf '%s\n' "Azure CLI (az) is required." >&2; exit 1; }
command -v kubectl >/dev/null || { printf '%s\n' "kubectl is required." >&2; exit 1; }
command -v kubelogin >/dev/null || { printf '%s\n' "kubelogin is required." >&2; exit 1; }

printf 'Signed-in operator identity: '
az account show --query user.name -o tsv

az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --overwrite-existing

# Reuse the current 'az login' account so kubectl does not prompt again.
kubelogin convert-kubeconfig -l azurecli

printf '%s\n' "Allowed read in namespace $ALLOWED_NAMESPACE:"
kubectl get pods --namespace "$ALLOWED_NAMESPACE"

printf '%s\n' "Denied read outside the boundary in namespace $DENIED_NAMESPACE:"
set +e
denied_output="$(kubectl get pods --namespace "$DENIED_NAMESPACE" 2>&1)"
denied_status=$?
set -e
printf '%s\n' "$denied_output"
if [[ "$denied_status" -eq 0 || "$denied_output" != *"Forbidden"* ]]; then
  printf '%s\n' "Expected a Forbidden response outside the allowed namespace." >&2
  exit 1
fi

# `kubectl auth can-i` returns exit status 1 for an expected "no" result.
set +e
allowed_check="$(kubectl auth can-i create deployments --namespace "$ALLOWED_NAMESPACE")"
allowed_status=$?
denied_check="$(kubectl auth can-i create deployments --namespace "$DENIED_NAMESPACE")"
denied_can_i_status=$?
set -e
printf 'create deployments in %s: %s\n' "$ALLOWED_NAMESPACE" "$allowed_check"
printf 'create deployments in %s: %s\n' "$DENIED_NAMESPACE" "$denied_check"

if [[ "$allowed_status" -ne 0 || "$allowed_check" != "yes" ||
      "$denied_can_i_status" -ne 1 || "$denied_check" != "no" ]]; then
  printf '%s\n' "Expected yes in orders and no in kube-system." >&2
  exit 1
fi

printf '%s\n' "Verified: operator access is allowed only in the orders namespace."
