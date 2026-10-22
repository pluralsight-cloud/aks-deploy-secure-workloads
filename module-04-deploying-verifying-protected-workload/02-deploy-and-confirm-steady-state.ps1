# Module 4 - Deploy and Confirm Steady State
param(
    [string]$Namespace = $(if ($env:NAMESPACE) { $env:NAMESPACE } else { "orders" }),
    [string]$DeploymentName = $(if ($env:DEPLOYMENT_NAME) { $env:DEPLOYMENT_NAME } else { "orders-api" }),
    [string]$ServiceName = $(if ($env:SERVICE_NAME) { $env:SERVICE_NAME } else { "orders-api" }),
    [string]$RolloutTimeout = $(if ($env:ROLLOUT_TIMEOUT) { $env:ROLLOUT_TIMEOUT } else { "180s" }),
    [string]$DeploymentManifest = $(if ($env:DEPLOYMENT_MANIFEST) { $env:DEPLOYMENT_MANIFEST } else { "..\module-03-secured-application-path\k8s\base\deployment.yaml" })
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $DeploymentManifest)) {
    Write-Error "Deployment manifest not found: $DeploymentManifest"
}

kubectl apply -f $DeploymentManifest --namespace $Namespace
kubectl rollout status "deployment/$DeploymentName" --namespace $Namespace --timeout=$RolloutTimeout

kubectl get pods --namespace $Namespace
kubectl get deployment $DeploymentName --namespace $Namespace
kubectl get endpointslice --namespace $Namespace -l "kubernetes.io/service-name=$ServiceName" -o yaml
