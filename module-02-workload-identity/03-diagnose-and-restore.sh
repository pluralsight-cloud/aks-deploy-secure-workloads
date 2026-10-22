#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-globomantics-aks}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-globomantics-prod}"
IDENTITY_NAME="${IDENTITY_NAME:-id-globomantics-orders}"
FEDERATED_CREDENTIAL_NAME="${FEDERATED_CREDENTIAL_NAME:-fed-orders-api}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-orders-api-sa}"
KEY_VAULT_NAME="${KEY_VAULT_NAME:-kv-globomantics-orders}"

command -v az >/dev/null || { printf '%s\n' "Azure CLI (az) is required." >&2; exit 1; }
command -v kubectl >/dev/null || { printf '%s\n' "kubectl is required." >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { printf 'Test pod manifest not found: %s\n' "$MANIFEST" >&2; exit 1; }

IDENTITY_PRINCIPAL_ID="$(az identity show \
  --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" \
  --query principalId -o tsv)"
ISSUER_URL="$(az aks show \
  --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" \
  --query oidcIssuerProfile.issuerUrl -o tsv)"
KEY_VAULT_ID="$(az keyvault show --name "$KEY_VAULT_NAME" --query id -o tsv)"

set_federated_subject() {
  local subject="$1"
  az identity federated-credential delete \
    --resource-group "$RESOURCE_GROUP" \
    --identity-name "$IDENTITY_NAME" \
    --name "$FEDERATED_CREDENTIAL_NAME" \
    --yes
  az identity federated-credential create \
    --resource-group "$RESOURCE_GROUP" \
    --identity-name "$IDENTITY_NAME" \
    --name "$FEDERATED_CREDENTIAL_NAME" \
    --issuer "$ISSUER_URL" \
    --subject "$subject" \
    --audiences api://AzureADTokenExchange
}

grant_vault_role() {
  az role assignment create \
    --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Key Vault Secrets User" \
    --scope "$KEY_VAULT_ID"
}

printf '\n%s\n' "== Step 1: break trust with a subject that does not exist =="
set_federated_subject "system:serviceaccount:${NAMESPACE}:nonexistent-sa"
sleep 15
expect_result TOKEN_EXCHANGE_FAILED 5 20
printf '%s\n' "Trust failure: the token exchange failed before Key Vault was reached."

printf '\n%s\n' "== Step 2: restore trust, then break permission =="
set_federated_subject "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}"
sleep 15
expect_result SUCCESS 5 20
printf '%s\n' "Trust restored: the read succeeds again."

az role assignment delete \
  --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
  --role "Key Vault Secrets User" \
  --scope "$KEY_VAULT_ID"
expect_result KEY_VAULT_DENIED 10 30
printf '%s\n' "Permission failure: the token worked, Key Vault returned 403."

printf '\n%s\n' "== Step 3: restore permission and verify =="
grant_vault_role
expect_result SUCCESS 15 30

printf '\n%s\n' "Diagnostic arc complete: trust is the token exchange; permission is vault access."
