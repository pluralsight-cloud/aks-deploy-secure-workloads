#!/usr/bin/env bash
# Shared defaults for the environment scripts. Sourced, not run.
# Every value can be overridden by exporting the variable first.

LOCATION="${LOCATION:-canadaeast}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-globomantics-aks}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-globomantics-prod}"
REGISTRY_NAME="${REGISTRY_NAME:-acrglobomantics}"
KEY_VAULT_NAME="${KEY_VAULT_NAME:-kv-globomantics-orders}"
NAMESPACE="${NAMESPACE:-orders}"
GROUP_NAME="${GROUP_NAME:-grp-globomantics-orders-operators}"
NODE_VM_SIZE="${NODE_VM_SIZE:-Standard_D4als_v6}"
NODE_COUNT="${NODE_COUNT:-2}"

# Directory that contains this scripts/ folder (the repo root).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { printf '%s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found."; }
