# Module 2 - Configure Workload Identity
param(
    [string]$ResourceGroup = $(if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { "rg-globomantics-aks" }),
    [string]$ClusterName = $(if ($env:CLUSTER_NAME) { $env:CLUSTER_NAME } else { "aks-globomantics-prod" }),
    [string]$Namespace = $(if ($env:NAMESPACE) { $env:NAMESPACE } else { "orders" }),
    [string]$IdentityName = $(if ($env:IDENTITY_NAME) { $env:IDENTITY_NAME } else { "id-globomantics-orders" }),
    [string]$FederatedCredentialName = $(if ($env:FEDERATED_CREDENTIAL_NAME) { $env:FEDERATED_CREDENTIAL_NAME } else { "fed-orders-api" }),
    [string]$ServiceAccountName = $(if ($env:SERVICE_ACCOUNT_NAME) { $env:SERVICE_ACCOUNT_NAME } else { "orders-api-sa" }),
    [string]$KeyVaultName = $(if ($env:KEY_VAULT_NAME) { $env:KEY_VAULT_NAME } else { "kv-globomantics-orders" })
)

$ErrorActionPreference = "Stop"

$user = az account show --query user.name -o tsv
Write-Host "Signed-in setup identity: $user"

$workloadIdentityEnabled = az aks show --resource-group $ResourceGroup --name $ClusterName --query securityProfile.workloadIdentity.enabled -o tsv
$oidcEnabled = az aks show --resource-group $ResourceGroup --name $ClusterName --query oidcIssuerProfile.issuerUrl -o tsv

if ($workloadIdentityEnabled -ne "true" -or (-not $oidcEnabled)) {
    Write-Error "The cluster must have Workload ID and an OIDC issuer enabled."
}

az identity create --resource-group $ResourceGroup --name $IdentityName --query '{clientId:clientId,principalId:principalId}' -o table

$identityClientId = az identity show --resource-group $ResourceGroup --name $IdentityName --query clientId -o tsv
$identityPrincipalId = az identity show --resource-group $ResourceGroup --name $IdentityName --query principalId -o tsv
$issuerUrl = az aks show --resource-group $ResourceGroup --name $ClusterName --query oidcIssuerProfile.issuerUrl -o tsv

az identity federated-credential create `
  --resource-group $ResourceGroup `
  --identity-name $IdentityName `
  --name $FederatedCredentialName `
  --issuer $issuerUrl `
  --subject "system:serviceaccount:${Namespace}:${ServiceAccountName}" `
  --audiences api://AzureADTokenExchange -o none

$keyVaultId = az keyvault show --name $KeyVaultName --query id -o tsv
$keyVaultRbac = az keyvault show --name $KeyVaultName --query properties.enableRbacAuthorization -o tsv
if ($keyVaultRbac -ne "true") {
    Write-Error "Key Vault must use the Azure RBAC permission model."
}

az role assignment create `
  --assignee-object-id $identityPrincipalId `
  --assignee-principal-type ServicePrincipal `
  --role "Key Vault Secrets User" `
  --scope $keyVaultId -o none

kubectl create serviceaccount $ServiceAccountName --namespace $Namespace --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount $ServiceAccountName --namespace $Namespace "azure.workload.identity/client-id=$identityClientId" --overwrite

Write-Host "Configured workload identity:"
Write-Host "  clientId: $identityClientId"
Write-Host "  principalId: $identityPrincipalId"
Write-Host "  subject: system:serviceaccount:${Namespace}:${ServiceAccountName}"
Write-Host "  vault: $KeyVaultName"
Write-Host "Federated credential and role assignment may need propagation time."
