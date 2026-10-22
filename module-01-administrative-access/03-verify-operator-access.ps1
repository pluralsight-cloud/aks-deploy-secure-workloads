# Module 1 - Verify operator access
param(
    [string]$ResourceGroup = $(if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { "rg-globomantics-aks" }),
    [string]$ClusterName = $(if ($env:CLUSTER_NAME) { $env:CLUSTER_NAME } else { "aks-globomantics-prod" }),
    [string]$AllowedNamespace = $(if ($env:ALLOWED_NAMESPACE) { $env:ALLOWED_NAMESPACE } else { "orders" }),
    [string]$DeniedNamespace = $(if ($env:DENIED_NAMESPACE) { $env:DENIED_NAMESPACE } else { "kube-system" })
)

$ErrorActionPreference = "Stop"

$user = az account show --query user.name -o tsv
Write-Host "Signed-in operator identity: $user"

az aks get-credentials --resource-group $ResourceGroup --name $ClusterName --overwrite-existing
if (Get-Command kubelogin -ErrorAction SilentlyContinue) {
    kubelogin convert-kubeconfig -l azurecli
}

Write-Host "Allowed read in namespace ${AllowedNamespace}:"
kubectl get pods --namespace $AllowedNamespace

Write-Host "Denied read outside the boundary in namespace ${DeniedNamespace}:"
$deniedOutput = kubectl get pods --namespace $DeniedNamespace 2>&1 | Out-String
Write-Host $deniedOutput
if ($deniedOutput -notmatch "Forbidden") {
    Write-Error "Expected a Forbidden response outside the allowed namespace."
}

$allowedCheck = (kubectl auth can-i create deployments --namespace $AllowedNamespace 2>&1 | Out-String).Trim()
$deniedCheck = (kubectl auth can-i create deployments --namespace $DeniedNamespace 2>&1 | Out-String).Trim()

Write-Host "create deployments in $AllowedNamespace : $allowedCheck"
Write-Host "create deployments in $DeniedNamespace : $deniedCheck"

if ($allowedCheck -ne "yes" -or $deniedCheck -ne "no") {
    Write-Error "Expected yes in orders and no in kube-system."
}

Write-Host "Verified: operator access is allowed only in the orders namespace." -ForegroundColor Green
