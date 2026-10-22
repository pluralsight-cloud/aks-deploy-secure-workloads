#!/usr/bin/env bash
# Completes shared Kubernetes setup without redeploying the infrastructure.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

need az
need kubectl
need kubelogin

state="$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
  --query provisioningState -o tsv)"
[[ "$state" == "Succeeded" ]] ||
  die "Cluster $CLUSTER_NAME is $state, not Succeeded. Resolve the active/failed operation before resuming setup."

bash "$REPO_ROOT/scripts/connect.sh"

printf 'Waiting for Kubernetes access to take effect'
for _ in $(seq 1 40); do
  if kubectl auth can-i '*' '*' >/dev/null 2>&1; then break; fi
  printf '.'
  sleep 10
done
printf '\n'
kubectl auth can-i '*' '*' >/dev/null 2>&1 ||
  die "No Kubernetes access yet. Wait a few minutes and re-run shared platform setup."

if ! kubectl get gatewayclass approuting-istio >/dev/null 2>&1; then
  printf 'Enabling Gateway API and App Routing Istio add-on...\n'
  az aks update -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
    --enable-gateway-api --enable-app-routing-istio -o none
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

for _ in $(seq 1 30); do
  kubectl get gatewayclass approuting-istio >/dev/null 2>&1 && break
  sleep 10
done
kubectl wait --for=condition=Accepted gatewayclass/approuting-istio --timeout=300s
