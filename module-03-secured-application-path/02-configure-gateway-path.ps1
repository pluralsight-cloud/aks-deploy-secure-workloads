# Module 3 - Configure Gateway API Path
param(
    [string]$Namespace = $(if ($env:NAMESPACE) { $env:NAMESPACE } else { "orders" }),
    [string]$IngressNamespace = $(if ($env:INGRESS_NAMESPACE) { $env:INGRESS_NAMESPACE } else { "orders-ingress" }),
    [string]$GatewayName = $(if ($env:GATEWAY_NAME) { $env:GATEWAY_NAME } else { "orders-gateway" })
)

$ErrorActionPreference = "Stop"

kubectl get gatewayclass approuting-istio
kubectl create namespace $IngressNamespace --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/base/gateway.yaml
kubectl wait --for=condition=Programmed "gateway/$GatewayName" --namespace $IngressNamespace --timeout=120s

kubectl apply -f k8s/base/service.yaml
kubectl apply -f k8s/base/httproute.yaml

kubectl get gateway $GatewayName --namespace $IngressNamespace -o yaml
kubectl get httproute orders-api --namespace $Namespace -o yaml
kubectl get endpointslice --namespace $Namespace -l kubernetes.io/service-name=orders-api
