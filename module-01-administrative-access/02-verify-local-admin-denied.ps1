# Module 1 - Verify local admin credential denial
param(
    [string]$ResourceGroup = $(if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { "rg-globomantics-aks" }),
    [string]$ClusterName = $(if ($env:CLUSTER_NAME) { $env:CLUSTER_NAME } else { "aks-globomantics-prod" })
)

$ErrorActionPreference = "Continue"

$user = az account show --query user.name -o tsv
Write-Host "Signed-in setup identity: $user"

$adminOutput = az aks get-credentials --resource-group $ResourceGroup --name $ClusterName --admin 2>&1
$adminStatus = $LASTEXITCODE

Write-Host $adminOutput

if ($adminStatus -eq 0) {
    Write-Error "Unexpected success: local admin credentials are still available."
    exit 1
}

if ($adminOutput -notmatch "Getting static credential isn't allowed because this cluster is set to disable local accounts.") {
    Write-Error "The command failed, but not with the expected local-account denial."
    exit 1
}

Write-Host "Verified: the local admin credential path is denied." -ForegroundColor Green
