# Module 4 - Pre-stage Bypass Test Pod
param(
    [string]$TestNamespace = $(if ($env:TEST_NAMESPACE) { $env:TEST_NAMESPACE } else { "default" }),
    [string]$BypassPod = $(if ($env:BYPASS_POD) { $env:BYPASS_POD } else { "bypass-test" })
)

$ErrorActionPreference = "Stop"

kubectl apply -f k8s/test/bypass-test.yaml
kubectl wait --for=condition=Ready "pod/$BypassPod" --namespace $TestNamespace --timeout=120s
kubectl get pod $BypassPod --namespace $TestNamespace -o wide
