#!/usr/bin/env bash
# Helpers shared by the Module 2 scripts. Sourced, not run.

NAMESPACE="${NAMESPACE:-orders}"
POD_NAME="${POD_NAME:-orders-api-sa-test}"
MANIFEST="${MANIFEST:-orders-api-sa-test.yaml}"
# Set IDENTITY_TEST_IMAGE to use an image you published yourself
# (see ../apps/identity-test).
IDENTITY_TEST_IMAGE="${IDENTITY_TEST_IMAGE:-}"

apply_test_pod() {
  if [[ -n "$IDENTITY_TEST_IMAGE" ]]; then
    sed -E "s#^( *image: ).*#\1${IDENTITY_TEST_IMAGE}#" "$MANIFEST" | kubectl apply -f -
  else
    kubectl apply -f "$MANIFEST"
  fi
}

# Recreates the pod so it requests a fresh token, then waits for its result line.
restart_test_pod() {
  kubectl delete pod "$POD_NAME" --namespace "$NAMESPACE" --ignore-not-found
  apply_test_pod
  kubectl wait --namespace "$NAMESPACE" \
    --for=jsonpath='{.status.phase}'=Running "pod/$POD_NAME" --timeout=180s
  for _ in $(seq 1 30); do
    if kubectl logs "$POD_NAME" --namespace "$NAMESPACE" 2>/dev/null | grep -q '^RESULT:'; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# Prints the pod log and returns 0 when its RESULT line starts with $1.
log_has_result() {
  local expected="$1" log
  log="$(kubectl logs "$POD_NAME" --namespace "$NAMESPACE")"
  printf '%s\n' "$log"
  printf '%s\n' "$log" | grep -q "^RESULT: ${expected}"
}

# Restarts the pod until its result matches $1. Azure changes can take a few
# minutes to apply, so this retries ($2 attempts, $3 seconds apart).
expect_result() {
  local expected="$1" attempts="${2:-10}" pause="${3:-30}" i
  for i in $(seq 1 "$attempts"); do
    restart_test_pod || true
    if log_has_result "$expected"; then
      return 0
    fi
    printf 'Attempt %s/%s: not %s yet; waiting %ss for Azure to apply the change...\n' \
      "$i" "$attempts" "$expected" "$pause"
    sleep "$pause"
  done
  printf 'Expected RESULT: %s but it never appeared.\n' "$expected" >&2
  return 1
}
