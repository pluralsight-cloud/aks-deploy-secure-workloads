# Module 2 - Verify Workload Identity
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib.ps1"

if (-not (Test-Path $Manifest)) {
    Write-Error "Test pod manifest not found: $Manifest"
}

# The role assignment can take several minutes to apply, so retry.
Assert-ExpectedResult "SUCCESS" 10 30

Write-Host "`nInjected Azure environment:"
$envVars = kubectl exec --namespace $Namespace $PodName -- env 2>$null
$envVars | Select-String "^AZURE_"

Write-Host "`nVerified: the pod read the secret with no stored credential." -ForegroundColor Green
