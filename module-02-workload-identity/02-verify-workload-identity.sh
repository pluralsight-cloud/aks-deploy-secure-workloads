#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v kubectl >/dev/null || { printf '%s\n' "kubectl is required." >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { printf 'Test pod manifest not found: %s\n' "$MANIFEST" >&2; exit 1; }

# The role assignment can take several minutes to apply, so retry.
expect_result SUCCESS 10 30

printf '\n%s\n' "Injected Azure environment:"
kubectl exec --namespace "$NAMESPACE" "$POD_NAME" -- env | grep '^AZURE_'

printf '\n%s\n' "Verified: the pod read the secret with no stored credential."
