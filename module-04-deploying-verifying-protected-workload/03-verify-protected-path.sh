#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-orders}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-orders-ingress}"
GATEWAY_NAME="${GATEWAY_NAME:-orders-gateway}"
SERVICE_NAME="${SERVICE_NAME:-orders-api}"
SERVICE_PORT="${SERVICE_PORT:-8080}"
ROUTE_HOST="${ROUTE_HOST:-orders-api.example}"
WRONG_HOST="${WRONG_HOST:-not-orders-api.example}"
TEST_NAMESPACE="${TEST_NAMESPACE:-default}"
BYPASS_POD="${BYPASS_POD:-bypass-test}"
BYPASS_MAX_TIME="${BYPASS_MAX_TIME:-5}"
REQUEST_MAX_TIME="${REQUEST_MAX_TIME:-15}"

command -v kubectl >/dev/null || {
  printf '%s\n' "kubectl is required." >&2
  exit 1
}
command -v curl >/dev/null || {
  printf '%s\n' "curl is required on the workstation." >&2
  exit 1
}

assert_http_status() {
  local expected="$1"
  local label="$2"
  local response="$3"
  local actual

  if [[ "$response" =~ ^HTTP/[0-9.]+[[:space:]]([0-9][0-9][0-9])([[:space:]]|$) ]]; then
    actual="${BASH_REMATCH[1]}"
  else
    printf '%s response did not include an HTTP status line.\n' "$label" >&2
    exit 1
  fi

  if [[ "$actual" != "$expected" ]]; then
    printf '%s response returned HTTP %s; expected HTTP %s.\n' \
      "$label" "$actual" "$expected" >&2
    exit 1
  fi
}

GATEWAY_IP="$(kubectl get gateway "$GATEWAY_NAME" \
  --namespace "$INGRESS_NAMESPACE" \
  -o jsonpath='{.status.addresses[0].value}')"

[ -n "$GATEWAY_IP" ] || {
  printf '%s\n' "Gateway ${GATEWAY_NAME} has no published address yet." >&2
  exit 1
}

printf 'Gateway address: %s\n' "$GATEWAY_IP"

printf '\n--- Positive test: matching host (expect HTTP 200 and the Key Vault-backed body) ---\n'
positive_response="$(curl --max-time "$REQUEST_MAX_TIME" -sS -i \
  -H "Host: ${ROUTE_HOST}" "http://${GATEWAY_IP}/")"
printf '%s\n' "$positive_response"
assert_http_status 200 "Positive test" "$positive_response"

printf '\n--- Negative test 1: wrong host (expect HTTP 404, no matching route) ---\n'
wrong_host_response="$(curl --max-time "$REQUEST_MAX_TIME" -sS -i \
  -H "Host: ${WRONG_HOST}" "http://${GATEWAY_IP}/")"
printf '%s\n' "$wrong_host_response"
assert_http_status 404 "Wrong-host test" "$wrong_host_response"

CLUSTER_IP="$(kubectl get service "$SERVICE_NAME" \
  --namespace "$NAMESPACE" \
  -o jsonpath='{.spec.clusterIP}')"

[ -n "$CLUSTER_IP" ] || {
  printf '%s\n' "Service ${SERVICE_NAME} has no cluster IP." >&2
  exit 1
}

printf '\n--- Negative test 2: in-cluster bypass from %s/%s to %s:%s ---\n' \
  "$TEST_NAMESPACE" "$BYPASS_POD" "$CLUSTER_IP" "$SERVICE_PORT"
printf 'A denial may time out or be refused/reset, depending on the policy engine.\n'
printf 'The upstream NetworkPolicy spec defines allowed traffic, not the denial signal.\n'

bypass_status=0
bypass_output=""
bypass_output="$(kubectl exec \
  --namespace "$TEST_NAMESPACE" \
  "$BYPASS_POD" \
  -- curl --max-time "$BYPASS_MAX_TIME" -s -o /dev/null -w '%{http_code}\n' \
  "http://${CLUSTER_IP}:${SERVICE_PORT}/")" || bypass_status=$?
printf '%s\n' "$bypass_output"

if [[ "$bypass_output" != "000" ]] ||
  [[ "$bypass_status" -ne 28 && "$bypass_status" -ne 7 &&
     "$bypass_status" -ne 56 ]]; then
  printf '\nUNEXPECTED: bypass result was exit %s with HTTP %s; expected a timeout or transport-level connection error.\n' \
    "$bypass_status" "${bypass_output:-<empty>}" >&2
  exit 1
fi

case "$bypass_status" in
  28) printf '\nBypass request timed out (curl exit 28, HTTP 000).\n' ;;
  7) printf '\nBypass connection was refused (curl exit 7, HTTP 000).\n' ;;
  56) printf '\nBypass request ended with a receive error (curl exit 56, HTTP 000).\n' ;;
esac
