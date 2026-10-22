#!/usr/bin/env bash
set -Eeuo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-globomantics-aks}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-globomantics-prod}"
NAMESPACE="${NAMESPACE:-orders}"
IDENTITY_NAME="${IDENTITY_NAME:-id-globomantics-orders}"
FEDERATED_CREDENTIAL_NAME="${FEDERATED_CREDENTIAL_NAME:-fed-orders-api}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-orders-api-sa}"
KEY_VAULT_NAME="${KEY_VAULT_NAME:-kv-globomantics-orders}"

command -v az >/dev/null || { printf '%s\n' "Azure CLI (az) is required." >&2; exit 1; }
command -v kubectl >/dev/null || { printf '%s\n' "kubectl is required." >&2; exit 1; }

printf 'Signed-in setup identity: '
az account show --query user.name -o tsv

workload_identity_enabled="$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query securityProfile.workloadIdentity.enabled \
  -o tsv)"
oidc_enabled="$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query oidcIssuerProfile.issuerUrl \
  -o tsv)"
if [[ "$workload_identity_enabled" != "true" || -z "$oidc_enabled" ]]; then
  printf '%s\n' "The cluster must have Workload ID and an OIDC issuer enabled." >&2
  printf 'workloadIdentity.enabled=%s, issuer=%s\n' \
    "$workload_identity_enabled" "$oidc_enabled" >&2
  exit 1
fi

az identity create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$IDENTITY_NAME" \
  --query '{clientId:clientId,principalId:principalId}' \
  -o table

IDENTITY_CLIENT_ID="$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$IDENTITY_NAME" \
  --query clientId \
  -o tsv)"
IDENTITY_PRINCIPAL_ID="$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$IDENTITY_NAME" \
  --query principalId \
  -o tsv)"
ISSUER_URL="$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query oidcIssuerProfile.issuerUrl \
  -o tsv)"

az identity federated-credential create \
  --resource-group "$RESOURCE_GROUP" \
  --identity-name "$IDENTITY_NAME" \
  --name "$FEDERATED_CREDENTIAL_NAME" \
  --issuer "$ISSUER_URL" \
  --subject "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}" \
  --audiences api://AzureADTokenExchange

KEY_VAULT_ID="$(az keyvault show \
  --name "$KEY_VAULT_NAME" \
  --query id \
  -o tsv)"
KEY_VAULT_RBAC="$(az keyvault show \
  --name "$KEY_VAULT_NAME" \
  --query properties.enableRbacAuthorization \
  -o tsv)"
if [[ "$KEY_VAULT_RBAC" != "true" ]]; then
  printf '%s\n' "Key Vault must use the Azure RBAC permission model." >&2
  exit 1
fi

az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" \
  --scope "$KEY_VAULT_ID"

kubectl create serviceaccount "$SERVICE_ACCOUNT_NAME" \
  --namespace "$NAMESPACE" \
  --dry-run=client \
  -o yaml | kubectl apply -f -
kubectl annotate serviceaccount "$SERVICE_ACCOUNT_NAME" \
  --namespace "$NAMESPACE" \
  "azure.workload.identity/client-id=$IDENTITY_CLIENT_ID" \
  --overwrite

printf '%s\n' "Configured workload identity:"
printf '  clientId: %s\n' "$IDENTITY_CLIENT_ID"
printf '  principalId: %s\n' "$IDENTITY_PRINCIPAL_ID"
printf '  subject: system:serviceaccount:%s:%s\n' "$NAMESPACE" "$SERVICE_ACCOUNT_NAME"
printf '  vault: %s\n' "$KEY_VAULT_NAME"
printf '%s\n' "Federated credential and role assignment may need propagation time."
