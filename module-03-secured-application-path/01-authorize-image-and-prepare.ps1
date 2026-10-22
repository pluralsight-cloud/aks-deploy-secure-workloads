# Module 3 - Authorize Image Source
param(
    [string]$ResourceGroup = $(if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { "rg-globomantics-aks" }),
    [string]$ClusterName = $(if ($env:CLUSTER_NAME) { $env:CLUSTER_NAME } else { "aks-globomantics-prod" }),
    [string]$RegistryName = $(if ($env:REGISTRY_NAME) { $env:REGISTRY_NAME } else { "acrglobomantics" }),
    [string]$Repository = "orders-api",
    [string]$ImageTag = "1.0.0"
)

$ErrorActionPreference = "Stop"

$user = az account show --query user.name -o tsv
Write-Host "Signed-in setup identity: $user"

$tag = az acr repository show-tags --name $RegistryName --repository $Repository --query "[?@=='$ImageTag'] | [0]" -o tsv
if ($tag -ne $ImageTag) {
    Write-Error "Expected image tag $ImageTag in $RegistryName/$Repository; got: $tag"
}
Write-Host "Image tag confirmed: ${RegistryName}.azurecr.io/${Repository}:${ImageTag}"

$roleAssignmentMode = az acr show --name $RegistryName --resource-group $ResourceGroup --query roleAssignmentMode -o tsv
Write-Host "Registry permission model: $roleAssignmentMode"
$normalizedMode = "$roleAssignmentMode".ToLower()

$kubeletObjectId = az aks show --resource-group $ResourceGroup --name $ClusterName --query identityProfile.kubeletidentity.objectId -o tsv
if (-not $kubeletObjectId) {
    Write-Error "Could not resolve the AKS kubelet identity object ID."
}
Write-Host "Kubelet identity objectId: $kubeletObjectId"

if ($normalizedMode -like "*abac*") {
    $registryId = az acr show --name $RegistryName --resource-group $ResourceGroup --query id -o tsv
    $existing = az role assignment list --assignee-object-id $kubeletObjectId --scope $registryId --role "Container Registry Repository Reader" --query "[].id | [0]" -o tsv
    if (-not $existing) {
        az role assignment create --assignee-object-id $kubeletObjectId --assignee-principal-type ServicePrincipal --role "Container Registry Repository Reader" --scope $registryId -o none
    } else {
        Write-Host "Container Registry Repository Reader assignment already exists."
    }
} elseif ($normalizedMode -match "rbac|legacy") {
    az aks update --resource-group $ResourceGroup --name $ClusterName --attach-acr $RegistryName -o none
} else {
    Write-Error "Unsupported registry permission model: $roleAssignmentMode"
}

Write-Host "Registry authorization is prepared." -ForegroundColor Green
Write-Host "The Deployment manifest is intentionally not applied in Module 3."
