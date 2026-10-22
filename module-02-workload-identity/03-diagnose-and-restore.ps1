# Module 2 - Diagnose and Restore
param(
    [string]$ResourceGroup = $(if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { "rg-globomantics-aks" }),
    [string]$ClusterName = $(if ($env:CLUSTER_NAME) { $env:CLUSTER_NAME } else { "aks-globomantics-prod" }),
    [string]$IdentityName = $(if ($env:IDENTITY_NAME) { $env:IDENTITY_NAME } else { "id-globomantics-orders" }),
    [string]$FederatedCredentialName = $(if ($env:FEDERATED_CREDENTIAL_NAME) { $env:FEDERATED_CREDENTIAL_NAME } else { "fed-orders-api" }),
    [string]$ServiceAccountName = $(if ($env:SERVICE_ACCOUNT_NAME) { $env:SERVICE_ACCOUNT_NAME } else { "orders-api-sa" }),
    [string]$KeyVaultName = $(if ($env:KEY_VAULT_NAME) { $env:KEY_VAULT_NAME } else { "kv-globomantics-orders" })
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib.ps1"

if (-not (Test-Path $Manifest)) {
    Write-Error "Test pod manifest not found: $Manifest"
}

$identityPrincipalId = az identity show --resource-group $ResourceGroup --name $IdentityName --query principalId -o tsv
$issuerUrl = az aks show --resource-group $ResourceGroup --name $ClusterName --query oidcIssuerProfile.issuerUrl -o tsv
$keyVaultId = az keyvault show --name $KeyVaultName --query id -o tsv

function Set-FederatedSubject([string]$subject) {
    az identity federated-credential delete --resource-group $ResourceGroup --identity-name $IdentityName --name $FederatedCredentialName --yes 2>$null
    az identity federated-credential create `
      --resource-group $ResourceGroup `
      --identity-name $IdentityName `
      --name $FederatedCredentialName `
      --issuer $issuerUrl `
      --subject $subject `
      --audiences api://AzureADTokenExchange -o none
}

function Grant-VaultRole {
    az role assignment create `
      --assignee-object-id $identityPrincipalId `
      --assignee-principal-type ServicePrincipal `
      --role "Key Vault Secrets User" `
      --scope $keyVaultId -o none
}

Write-Host "`n== Step 1: break trust with a subject that does not exist =="
Set-FederatedSubject "system:serviceaccount:${Namespace}:nonexistent-sa"
Start-Sleep -Seconds 15
Assert-ExpectedResult "TOKEN_EXCHANGE_FAILED" 5 20
Write-Host "Trust failure: the token exchange failed before Key Vault was reached." -ForegroundColor Yellow

Write-Host "`n== Step 2: restore trust, then break permission =="
Set-FederatedSubject "system:serviceaccount:${Namespace}:${ServiceAccountName}"
Start-Sleep -Seconds 15
Assert-ExpectedResult "SUCCESS" 5 20
Write-Host "Trust restored: the read succeeds again." -ForegroundColor Green

az role assignment delete `
  --assignee-object-id $identityPrincipalId `
  --role "Key Vault Secrets User" `
  --scope $keyVaultId -o none
Assert-ExpectedResult "KEY_VAULT_DENIED" 10 30
Write-Host "Permission failure: the token worked, Key Vault returned 403." -ForegroundColor Yellow

Write-Host "`n== Step 3: restore permission and verify =="
Grant-VaultRole
Assert-ExpectedResult "SUCCESS" 15 30

Write-Host "`nDiagnostic arc complete: trust is the token exchange; permission is vault access." -ForegroundColor Green
