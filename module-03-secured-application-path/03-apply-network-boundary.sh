#!/usr/bin/env bash
set -Eeuo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-globomantics-aks}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-globomantics-prod}"
NAMESPACE="${NAMESPACE:-orders}"
POLICY_NAME="${POLICY_NAME:-orders-api-allow-gateway}"

command -v az >/dev/null || {
  printf '%s\n' "Azure CLI (az) is required." >&2
  exit 1
}
command -v kubectl >/dev/null || {
  printf '%s\n' "kubectl is required." >&2
  exit 1
}

az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query "{networkPolicy:networkProfile.networkPolicy,networkDataplane:networkProfile.networkDataplane}" \
  -o yaml

network_policy="$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query networkProfile.networkPolicy \
  -o tsv)"
network_dataplane="$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query networkProfile.networkDataplane \
  -o tsv)"
if [[ -z "$network_policy" || "$network_policy" == "None" ||
  -z "$network_dataplane" || "$network_dataplane" == "None" ]]; then
  printf '%s\n' \
    "A configured network-policy engine and dataplane are required before applying this policy." >&2
  exit 1
fi

kubectl apply -f k8s/base/networkpolicy.yaml
kubectl describe networkpolicy "$POLICY_NAME" --namespace "$NAMESPACE"
