# Helpers shared by Module 2 PowerShell scripts. Sourced or dot-sourced.
$Namespace = if ($env:NAMESPACE) { $env:NAMESPACE } else { "orders" }
$PodName = if ($env:POD_NAME) { $env:POD_NAME } else { "orders-api-sa-test" }
$Manifest = if ($env:MANIFEST) { $env:MANIFEST } else { "orders-api-sa-test.yaml" }
$IdentityTestImage = $env:IDENTITY_TEST_IMAGE

function Apply-TestPod {
    if ($IdentityTestImage) {
        $content = Get-Content $Manifest -Raw
        $content = $content -replace "image: .*", "image: $IdentityTestImage"
        $content | kubectl apply -f -
    } else {
        kubectl apply -f $Manifest
    }
}

function Restart-TestPod {
    kubectl delete pod $PodName --namespace $Namespace --ignore-not-found
    Apply-TestPod
    kubectl wait --namespace $Namespace --for=jsonpath='{.status.phase}'=Running "pod/$PodName" --timeout=180s
    for ($i = 1; $i -le 30; $i++) {
        $logs = kubectl logs $PodName --namespace $Namespace 2>$null | Out-String
        if ($logs -match "^RESULT:") {
            return $true
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Test-LogHasResult([string]$expected) {
    $log = kubectl logs $PodName --namespace $Namespace | Out-String
    Write-Host $log
    return ($log -match "^RESULT: $expected")
}

function Assert-ExpectedResult([string]$expected, [int]$attempts = 10, [int]$pause = 30) {
    for ($i = 1; $i -le $attempts; $i++) {
        Restart-TestPod | Out-Null
        if (Test-LogHasResult $expected) {
            return $true
        }
        Write-Host "Attempt $i/$attempts : not $expected yet; waiting ${pause}s for Azure to apply the change..."
        Start-Sleep -Seconds $pause
    }
    Write-Error "Expected RESULT: $expected but it never appeared."
    return $false
}
