#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-orders}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-orders-api}"
SERVICE_NAME="${SERVICE_NAME:-orders-api}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"
DEPLOYMENT_MANIFEST="${DEPLOYMENT_MANIFEST:-../module-03-secured-application-path/k8s/base/deployment.yaml}"

command -v kubectl >/dev/null || {
  printf '%s\n' "kubectl is required." >&2
  exit 1
}

[ -f "$DEPLOYMENT_MANIFEST" ] || {
  printf '%s\n' "Deployment manifest not found: ${DEPLOYMENT_MANIFEST}" >&2
  exit 1
}

kubectl apply -f "$DEPLOYMENT_MANIFEST" --namespace "$NAMESPACE"

kubectl rollout status \
  "deployment/${DEPLOYMENT_NAME}" \
  --namespace "$NAMESPACE" \
  --timeout="$ROLLOUT_TIMEOUT"

kubectl get pods --namespace "$NAMESPACE"
kubectl get deployment "$DEPLOYMENT_NAME" --namespace "$NAMESPACE"

kubectl get endpointslice \
  --namespace "$NAMESPACE" \
  -l "kubernetes.io/service-name=${SERVICE_NAME}" \
  -o yaml
