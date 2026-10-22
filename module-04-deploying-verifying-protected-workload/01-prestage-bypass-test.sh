#!/usr/bin/env bash
set -Eeuo pipefail

TEST_NAMESPACE="${TEST_NAMESPACE:-default}"
BYPASS_POD="${BYPASS_POD:-bypass-test}"

command -v kubectl >/dev/null || {
  printf '%s\n' "kubectl is required." >&2
  exit 1
}

kubectl apply -f k8s/test/bypass-test.yaml
kubectl wait \
  --for=condition=Ready \
  "pod/${BYPASS_POD}" \
  --namespace "$TEST_NAMESPACE" \
  --timeout=120s

kubectl get pod "$BYPASS_POD" --namespace "$TEST_NAMESPACE" -o wide
