#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-orders}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-orders-ingress}"
GATEWAY_NAME="${GATEWAY_NAME:-orders-gateway}"

command -v kubectl >/dev/null || {
  printf '%s\n' "kubectl is required." >&2
  exit 1
}

kubectl get gatewayclass approuting-istio
kubectl create namespace "$INGRESS_NAMESPACE" --dry-run=client -o yaml |
  kubectl apply -f -
kubectl apply -f k8s/base/gateway.yaml
kubectl wait \
  --for=condition=Programmed \
  "gateway/${GATEWAY_NAME}" \
  --namespace "$INGRESS_NAMESPACE" \
  --timeout=120s

kubectl apply -f k8s/base/service.yaml
kubectl apply -f k8s/base/httproute.yaml

kubectl get gateway "$GATEWAY_NAME" \
  --namespace "$INGRESS_NAMESPACE" \
  -o yaml
kubectl get httproute orders-api \
  --namespace "$NAMESPACE" \
  -o yaml
kubectl get endpointslice \
  --namespace "$NAMESPACE" \
  -l kubernetes.io/service-name=orders-api
