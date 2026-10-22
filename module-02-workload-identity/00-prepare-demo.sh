#!/usr/bin/env bash
# Prepares the disposable lab's existing cluster, ServiceAccount and sample vault.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/env.sh"

[[ $# -eq 0 ]] || die "Usage: bash 00-prepare-demo.sh (sign in and export lab names first)"
need az
need kubectl
need kubelogin
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-orders-api-sa}"

printf 'Preparing the lab as: '
az account show --query user.name -o tsv
SETUP_USER_ID="$(az ad signed-in-user show --query id -o tsv)"

workload_identity="$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
  --query securityProfile.workloadIdentity.enabled -o tsv)"
issuer="$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
  --query oidcIssuerProfile.issuerUrl -o tsv)"
if [[ "$workload_identity" != true || -z "$issuer" ]]; then
  printf '%s\n' "Enabling Workload ID and the OIDC issuer on the existing cluster."
  az aks update -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
    --enable-workload-identity --enable-oidc-issuer -o none
fi
bash "$REPO_ROOT/scripts/connect.sh"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create serviceaccount "$SERVICE_ACCOUNT_NAME" --namespace "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

KEY_VAULT_ID="$(az keyvault list --resource-group "$RESOURCE_GROUP" \
  --query "[?name=='$KEY_VAULT_NAME'].id | [0]" -o tsv)"
if [[ -z "$KEY_VAULT_ID" ]]; then
  printf 'Creating dedicated lab vault: %s\n' "$KEY_VAULT_NAME"
  az keyvault create --resource-group "$RESOURCE_GROUP" --name "$KEY_VAULT_NAME" \
    --location "$LOCATION" --enable-rbac-authorization true -o none
  KEY_VAULT_ID="$(az keyvault show --name "$KEY_VAULT_NAME" --query id -o tsv)"
fi
vault_rbac="$(az keyvault show --name "$KEY_VAULT_NAME" \
  --query properties.enableRbacAuthorization -o tsv)"
[[ "$vault_rbac" == true ]] || die "Vault $KEY_VAULT_NAME must already use Azure RBAC. This script will not convert an existing vault."

officer_role="$(az role assignment list --assignee "$SETUP_USER_ID" \
  --role "Key Vault Secrets Officer" --scope "$KEY_VAULT_ID" --query '[0].id' -o tsv)"
if [[ -z "$officer_role" ]]; then
  az role assignment create --assignee-object-id "$SETUP_USER_ID" \
    --assignee-principal-type User --role "Key Vault Secrets Officer" \
    --scope "$KEY_VAULT_ID" -o none
fi

if ! sample_secret="$(az keyvault secret list --vault-name "$KEY_VAULT_NAME" \
  --query "[?name=='orders-db-connection-string'].id | [0]" -o tsv)"; then
  die "Cannot list secrets. A new setup-user role can take up to 10 minutes to propagate; check vault network access, then rerun this script. No secret was written."
fi
if [[ -z "$sample_secret" ]]; then
  az keyvault secret set --vault-name "$KEY_VAULT_NAME" \
    --name orders-db-connection-string \
    --value 'demo-only-not-a-real-connection-string' -o none
else
  printf '%s\n' "The sample secret already exists; leaving its value unchanged."
fi

printf '%s\n' "Preparation complete. Continue with 01-configure-workload-identity.sh."
