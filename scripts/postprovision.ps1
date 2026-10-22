# azd postprovision hook for Windows (PowerShell)
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path "$PSScriptRoot\.."
$resourceGroup = if ($env:AZURE_RESOURCE_GROUP) { $env:AZURE_RESOURCE_GROUP } else { "rg-globomantics-aks" }
$clusterName = if ($env:AZURE_AKS_CLUSTER_NAME) { $env:AZURE_AKS_CLUSTER_NAME } else { "aks-globomantics-prod" }
$registryName = if ($env:AZURE_CONTAINER_REGISTRY_NAME) { $env:AZURE_CONTAINER_REGISTRY_NAME } else { "acrglobomantics" }
$namespace = if ($env:NAMESPACE) { $env:NAMESPACE } else { "orders" }

foreach ($tool in @("az", "kubectl", "kubelogin", "curl")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool is required."
    }
}
$azVersion = az version --query '"azure-cli"' -o tsv
if ($LASTEXITCODE -ne 0) { throw "Could not read Azure CLI version." }
if ([version]$azVersion -lt [version]"2.86.0") { throw "Azure CLI 2.86.0 or later is required." }
az account show -o none
if ($LASTEXITCODE -ne 0) { throw "Sign in as setup/admin with 'az login'." }

Write-Host "`n== Running Post-Provision Configuration ==" -ForegroundColor Cyan

# 1. Connect kubectl and convert kubeconfig
Write-Host "Configuring kubectl context..."
az aks get-credentials --resource-group $resourceGroup --name $clusterName --overwrite-existing
if ($LASTEXITCODE -ne 0) { throw "Could not fetch the AKS kubeconfig." }
kubelogin convert-kubeconfig -l azurecli
if ($LASTEXITCODE -ne 0) { throw "Could not configure Azure CLI authentication for kubectl." }

# 2. Wait for Kubernetes RBAC propagation
Write-Host -NoNewline "Waiting for Kubernetes access to take effect"
for ($i = 1; $i -le 40; $i++) {
    $canI = kubectl auth can-i '*' '*' 2>$null
    if ($LASTEXITCODE -eq 0) { break }
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 10
}
Write-Host ""
if ($LASTEXITCODE -ne 0) {
    throw "No Kubernetes access yet. Wait a few minutes and re-run 'azd hooks run postprovision'."
}

# 3. Enable Gateway API & App Routing
$gwClass = kubectl get gatewayclass approuting-istio 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Enabling Gateway API and App Routing Istio add-on..."
    az aks update -g $resourceGroup -n $clusterName --enable-gateway-api --enable-app-routing-istio -o none
    if ($LASTEXITCODE -ne 0) { throw "Gateway API enablement failed." }
}

# 4. Create orders namespace
$namespaceManifest = kubectl create namespace $namespace --dry-run=client -o yaml
if ($LASTEXITCODE -ne 0) { throw "Could not generate the namespace manifest." }
$namespaceManifest | kubectl apply -f -
if ($LASTEXITCODE -ne 0) { throw "Could not create the application namespace." }

# 5. Wait for GatewayClass to be Accepted
Write-Host "Waiting for GatewayClass approuting-istio to be ready..."
for ($i = 1; $i -le 30; $i++) {
    $gwClass = kubectl get gatewayclass approuting-istio 2>$null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 10
}
kubectl wait --for=condition=Accepted gatewayclass/approuting-istio --timeout=300s
if ($LASTEXITCODE -ne 0) { throw "GatewayClass approuting-istio is not Accepted." }

# 6. Build and push orders-api:1.0.0
Write-Host "Building and pushing orders-api:1.0.0 image to ACR..."
$ordersAppDir = Join-Path $repoRoot "apps\orders-api"
az acr build --registry $registryName --image "orders-api:1.0.0" --platform linux/amd64 $ordersAppDir
if ($LASTEXITCODE -ne 0) {
    Write-Host "ACR Tasks is unavailable here; building locally with Docker instead."
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker is required for the local build fallback." }
    az acr login --name $registryName
    if ($LASTEXITCODE -ne 0) { throw "Could not sign in to the container registry." }
    docker buildx build --platform linux/amd64 --push --tag "$registryName.azurecr.io/orders-api:1.0.0" $ordersAppDir
    if ($LASTEXITCODE -ne 0) { throw "Local image build/push failed." }
}
az acr repository show-tags --name $registryName --repository orders-api -o tsv
if ($LASTEXITCODE -ne 0) { throw "Could not verify the published image tags." }

Write-Host "`n== Environment is fully ready for the course! ==" -ForegroundColor Green
az aks show -g $resourceGroup -n $clusterName --query "{version:kubernetesVersion,networkPolicy:networkProfile.networkPolicy,dataplane:networkProfile.networkDataplane,localAccountsDisabled:disableLocalAccounts}" -o table
if ($LASTEXITCODE -ne 0) { throw "Could not read the AKS configuration." }
