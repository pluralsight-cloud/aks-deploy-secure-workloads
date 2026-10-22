# Module 3 - Apply Network Boundary
param(
    [string]$ResourceGroup = $(if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { "rg-globomantics-aks" }),
    [string]$ClusterName = $(if ($env:CLUSTER_NAME) { $env:CLUSTER_NAME } else { "aks-globomantics-prod" }),
    [string]$Namespace = $(if ($env:NAMESPACE) { $env:NAMESPACE } else { "orders" }),
    [string]$PolicyName = "orders-api-allow-gateway"
)

$ErrorActionPreference = "Stop"

az aks show --resource-group $ResourceGroup --name $ClusterName --query "{networkPolicy:networkProfile.networkPolicy,networkDataplane:networkProfile.networkDataplane}" -o yaml

$netPolicy = az aks show --resource-group $ResourceGroup --name $ClusterName --query networkProfile.networkPolicy -o tsv
$netData = az aks show --resource-group $ResourceGroup --name $ClusterName --query networkProfile.networkDataplane -o tsv

if (-not $netPolicy -or $netPolicy -eq "None" -or -not $netData -or $netData -eq "None") {
    Write-Error "A configured network-policy engine and dataplane are required before applying this policy."
}

kubectl apply -f k8s/base/networkpolicy.yaml
kubectl describe networkpolicy $PolicyName --namespace $Namespace
