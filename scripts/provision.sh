#!/usr/bin/env bash
# Creates the starting environment: resource group, AKS cluster, registry,
# Key Vault (via infra/main.bicep), the Gateway API platform feature, and the
# orders namespace. Safe to re-run.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

need az
need kubectl
need kubelogin

az account show >/dev/null 2>&1 || die "Not signed in. Run 'az login'."
admin_id="$(az ad signed-in-user show --query id -o tsv)"
printf 'Provisioning as: %s\n' "$(az account show --query user.name -o tsv)"

resource_group_exists="$(az group exists --name "$RESOURCE_GROUP" -o tsv)"
case "$resource_group_exists" in
  true) printf 'Using existing resource group: %s\n' "$RESOURCE_GROUP" ;;
  false) az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none ;;
  *) die "Could not determine whether resource group $RESOURCE_GROUP exists." ;;
esac

az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --name globomantics-environment \
  --template-file "$REPO_ROOT/infra/main.bicep" \
  --parameters \
    location="$LOCATION" \
    clusterName="$CLUSTER_NAME" \
    registryName="$REGISTRY_NAME" \
    keyVaultName="$KEY_VAULT_NAME" \
    nodeVmSize="$NODE_VM_SIZE" \
    nodeCount="$NODE_COUNT" \
    adminPrincipalId="$admin_id" \
  -o none

bash "$REPO_ROOT/scripts/configure-platform.sh"

printf '\n%s\n' "Environment ready."
az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
  --query "{version:kubernetesVersion,networkPolicy:networkProfile.networkPolicy,dataplane:networkProfile.networkDataplane,localAccountsDisabled:disableLocalAccounts}" \
  -o table
