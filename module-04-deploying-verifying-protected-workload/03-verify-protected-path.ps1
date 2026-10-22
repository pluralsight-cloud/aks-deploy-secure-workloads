# Module 4 - Verify Protected Path
param(
    [string]$Namespace = $(if ($env:NAMESPACE) { $env:NAMESPACE } else { "orders" }),
    [string]$IngressNamespace = $(if ($env:INGRESS_NAMESPACE) { $env:INGRESS_NAMESPACE } else { "orders-ingress" }),
    [string]$GatewayName = $(if ($env:GATEWAY_NAME) { $env:GATEWAY_NAME } else { "orders-gateway" }),
    [string]$ServiceName = $(if ($env:SERVICE_NAME) { $env:SERVICE_NAME } else { "orders-api" }),
    [string]$ServicePort = "8080",
    [string]$RouteHost = "orders-api.example",
    [string]$WrongHost = "not-orders-api.example",
    [string]$TestNamespace = $(if ($env:TEST_NAMESPACE) { $env:TEST_NAMESPACE } else { "default" }),
    [string]$BypassPod = $(if ($env:BYPASS_POD) { $env:BYPASS_POD } else { "bypass-test" }),
    [int]$BypassMaxTime = 5,
    [int]$RequestMaxTime = 15
)

$ErrorActionPreference = "Stop"

$gatewayIp = kubectl get gateway $GatewayName --namespace $IngressNamespace -o jsonpath='{.status.addresses[0].value}'
if (-not $gatewayIp) {
    Write-Error "Gateway $GatewayName has no published address yet."
}

Write-Host "Gateway address: $gatewayIp"

Write-Host "`n--- Positive test: matching host (expect HTTP 200 and the Key Vault-backed body) ---"
$posResponse = (curl.exe --max-time $RequestMaxTime -sS -i -H "Host: $RouteHost" "http://${gatewayIp}/") -join "`n"
if ($LASTEXITCODE -ne 0) { Write-Error "Positive request failed before an HTTP response was received." }
Write-Host $posResponse
if ($posResponse -notmatch "^HTTP/[0-9.]+\s200(\s|$)") {
    Write-Error "Positive test did not return HTTP 200."
}

Write-Host "`n--- Negative test 1: wrong host (expect HTTP 404, no matching route) ---"
$wrongResponse = (curl.exe --max-time $RequestMaxTime -sS -i -H "Host: $WrongHost" "http://${gatewayIp}/") -join "`n"
if ($LASTEXITCODE -ne 0) { Write-Error "Wrong-host request failed before an HTTP response was received." }
Write-Host $wrongResponse
if ($wrongResponse -notmatch "^HTTP/[0-9.]+\s404(\s|$)") {
    Write-Error "Wrong-host test did not return HTTP 404."
}

$clusterIp = kubectl get service $ServiceName --namespace $Namespace -o jsonpath='{.spec.clusterIP}'
if (-not $clusterIp) {
    Write-Error "Service $ServiceName has no cluster IP."
}

Write-Host "`n--- Negative test 2: in-cluster bypass from $TestNamespace/$BypassPod to ${clusterIp}:${ServicePort} ---"
Write-Host "A denial may time out or be refused/reset, depending on the policy engine."

$bypassOutput = kubectl exec --namespace $TestNamespace $BypassPod -- curl --max-time $BypassMaxTime -s -o /dev/null -w "%{http_code}\n" "http://${clusterIp}:${ServicePort}/"
$bypassExit = $LASTEXITCODE
$bypassOutput = ($bypassOutput -join "`n").Trim()

Write-Host "Bypass response code: $bypassOutput"

if ($bypassOutput -ne "000" -or ($bypassExit -ne 28 -and $bypassExit -ne 7 -and $bypassExit -ne 56)) {
    Write-Error "UNEXPECTED: bypass result was exit $bypassExit with HTTP $bypassOutput; expected timeout or connection failure."
} else {
    Write-Host "Bypass connection failed, consistent with the policy (curl exit $bypassExit, HTTP 000)." -ForegroundColor Green
}
