# Module 1 - Configure administrative boundary
param(
    [string]$OperatorObjectId = $env:OPERATOR_OBJECT_ID,
    [string]$ResourceGroup = $(if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { "rg-globomantics-aks" }),
    [string]$ClusterName = $(if ($env:CLUSTER_NAME) { $env:CLUSTER_NAME } else { "aks-globomantics-prod" }),
    [string]$Namespace = $(if ($env:NAMESPACE) { $env:NAMESPACE } else { "orders" }),
    [string]$GroupName = $(if ($env:GROUP_NAME) { $env:GROUP_NAME } else { "grp-globomantics-orders-operators" }),
    [switch]$ConfirmRotateCerts
)

$ErrorActionPreference = "Stop"

if (-not $OperatorObjectId) {
    Write-Error "Set OPERATOR_OBJECT_ID or pass -OperatorObjectId <id>."
}

$user = az account show --query user.name -o tsv
Write-Host "Signed-in setup identity: $user"

$azureRbacEnabled = az aks show --resource-group $ResourceGroup --name $ClusterName --query aadProfile.enableAzureRbac -o tsv
if ($azureRbacEnabled -ne "true") {
    Write-Error "Expected Azure RBAC for Kubernetes Authorization to be true; got: $azureRbacEnabled"
}

az aks update --resource-group $ResourceGroup --name $ClusterName --disable-local-accounts -o none

$disableLocalAccounts = az aks show --resource-group $ResourceGroup --name $ClusterName --query disableLocalAccounts -o tsv
if ($disableLocalAccounts -ne "true") {
    Write-Error "Expected disableLocalAccounts=true; got: $disableLocalAccounts"
}

if ($ConfirmRotateCerts -or ($env:CONFIRM_ROTATE_CERTS -eq "YES")) {
    az aks rotate-certs --resource-group $ResourceGroup --name $ClusterName
} else {
    Write-Host "Certificate rotation skipped. Set CONFIRM_ROTATE_CERTS=YES to rotate (nodes are recreated; allow up to 30 minutes of downtime)."
}

$groupId = az ad group show --group $GroupName --query id -o tsv 2>$null
if (-not $groupId) {
    $groupId = az ad group create --display-name $GroupName --mail-nickname $GroupName --query id -o tsv
}
if (-not $groupId) {
    Write-Error "Could not resolve the operator group object ID."
}

$isMember = az ad group member check --group $groupId --member-id $OperatorObjectId --query value -o tsv
if ($isMember -ne "true") {
    az ad group member add --group $groupId --member-id $OperatorObjectId
}

$aksId = az aks show --resource-group $ResourceGroup --name $ClusterName --query id -o tsv

az role assignment create `
  --assignee-object-id $groupId `
  --assignee-principal-type Group `
  --role "Azure Kubernetes Service Cluster User Role" `
  --scope $aksId -o none

az role assignment create `
  --assignee-object-id $groupId `
  --assignee-principal-type Group `
  --role "Azure Kubernetes Service RBAC Writer" `
  --scope "$aksId/namespaces/$Namespace" -o none

Write-Host "Cluster-scope assignment:"
az role assignment list --assignee $groupId --scope $aksId -o table

Write-Host "Namespace-scope assignment:"
az role assignment list --assignee $groupId --scope "$aksId/namespaces/$Namespace" -o table
