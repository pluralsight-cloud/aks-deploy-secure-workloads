#!/usr/bin/env bash
# Deletes everything the labs created. This cannot be undone.
#   CONFIRM_CLEANUP=YES bash scripts/cleanup.sh
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

[[ "${CONFIRM_CLEANUP:-}" == "YES" ]] ||
  die "This deletes resource group $RESOURCE_GROUP. Re-run with CONFIRM_CLEANUP=YES."

az group delete --name "$RESOURCE_GROUP" --yes

# Key Vault keeps deleted vaults for the soft-delete period; purge it so the
# name can be reused.
az keyvault purge --name "$KEY_VAULT_NAME" --location "$LOCATION" 2>/dev/null || true

group_id="$(az ad group show --group "$GROUP_NAME" --query id -o tsv 2>/dev/null || true)"
[[ -z "$group_id" ]] || az ad group delete --group "$group_id"

printf '%s\n' "Cleanup complete."
