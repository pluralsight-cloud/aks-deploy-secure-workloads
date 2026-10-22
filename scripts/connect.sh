#!/usr/bin/env bash
# Fetches the kubeconfig and makes kubectl reuse your current 'az login'
# account, so there are no extra interactive prompts. Re-run it after you
# switch accounts with 'az login'.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

need az
need kubelogin

az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli
