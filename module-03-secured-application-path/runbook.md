# Module 3 runbook — Configuring the secured application path

## What you will do

Build the road before the traffic arrives: authorize the cluster to pull a
private image, put a Gateway in front of the app, and limit which sources can
reach it. You run each command yourself, in this order. The Orders API is not
deployed in this module; its Deployment is only read. Gateway creation does
create a separate managed proxy Deployment.

## Prerequisites

- **Shell and tools:** Bash 3.2+, Azure CLI **2.86.0 or later** (Gateway API
  enablement), `kubectl`, and `kubelogin`. `kubectl` should be the same minor
  as the AKS server. Kubernetes supports one minor of skew either way, so a
  pair such as server 1.35 and client 1.36 is supported, but record your actual
  pair rather than assuming an exact match.
- **Account:** the **setup/admin** Microsoft Entra user from the repository
  `README.md`: it creates role assignments and administers the cluster. The
  limited operator from the first module cannot do this. Stay signed in as
  setup/admin for the whole module.
- **Existing environment:** the repository `README.md` environment is
  provisioned: cluster `aks-globomantics-prod` in `rg-globomantics-aks`,
  registry `acrglobomantics`, namespace `orders`, and the Azure CNI Overlay
  cluster with Cilium as dataplane and policy engine. Gateway API and the
  application routing implementation are enabled (shared setup runs the
  command shown in step 2). The Istio service-mesh add-on is **not** enabled;
  AKS does not support it together with the managed Gateway API
  implementation.
- **Earlier work:** the workload-identity module is complete, so the
  `orders-api-sa` ServiceAccount exists, and its test pod
  `orders-api-sa-test` has been removed (`kubectl delete pod
  orders-api-sa-test --namespace orders --ignore-not-found`).
- **Start state:** no `orders-ingress` namespace, Gateway, Service, route,
  policy or `orders-api` Deployment. Check with
  `kubectl get namespace orders-ingress` (expect `NotFound`) and
  `kubectl get deployment,service,httproute,networkpolicy --namespace orders`.
- **Names:** commands use the course values `rg-globomantics-aks`,
  `aks-globomantics-prod` and `acrglobomantics`. If you chose other names,
  substitute them in every command, and edit the `image:` line in
  `k8s/base/deployment.yaml` (and the `KEY_VAULT_NAME` value if your vault name
  differs).
- **Cost:** the Gateway creates a managed proxy and may allocate a load
  balancer address; it is billable until cleaned up.

From the repository root, set the working directory and check who you are:

```bash
cd module-03-secured-application-path
az account show --query user.name -o tsv
kubectl config current-context
```

Expect your setup/admin sign-in name and a context for
`aks-globomantics-prod`. All commands below run from this folder.

## Choose manual commands or scripts

Follow the **manual commands** below, which are what the video demonstrates.
The numbered scripts (`01-…`, `02-…`, `03-…`) are an **alternative** that does
the same actions for you; use one path or the other, not both, because both
change the same cluster objects. If you use the scripts, skip to
"Optional scripts".

## Steps

### 1. Authorize the image pull (setup/admin)

**1a. Inspect the Orders API source.** This Python application and its
Dockerfile are in `../apps/orders-api`. It is a different program from the
public diagnostic image used earlier.

```bash
cat ../apps/orders-api/app.py
```

Find `WorkloadIdentityCredential` and `SecretClient`: the application uses the
ServiceAccount's federated identity to call `get_secret`. The Deployment sets
`KEY_VAULT_NAME`; `SECRET_NAME` defaults to the existing
`orders-db-connection-string` secret. If your secret has another name, set
`SECRET_NAME` in the Deployment's environment too. `Handler.do_GET` returns
HTTP 200 with `keyVaultConfig: loaded` on success, or 503 with `unavailable`
on failure. `secretValue` is always `redacted`; the secret is never returned
or logged. Only the read status/reason is cached, for 30 seconds.

**1b. Build the image into your registry** (done once, before this module).
If `1c` already lists `1.0.0`, skip this. Otherwise run:

```bash
az acr build --registry acrglobomantics \
  --image orders-api:1.0.0 \
  --platform linux/amd64 \
  ../apps/orders-api
```

This builds in Azure Container Registry and stores
`acrglobomantics.azurecr.io/orders-api:1.0.0`. If ACR Tasks is unavailable in
your subscription, `bash ../scripts/build-images.sh` tries this command and
falls back to a local Docker build (requires Docker with Buildx).

**1c. Confirm the tag.**

```bash
az acr repository show-tags --name acrglobomantics \
  --repository orders-api -o tsv
```

Expect `1.0.0`. Stop if it is missing.

**1d. Read the registry's permission model.**

```bash
az acr show --name acrglobomantics \
  --resource-group rg-globomantics-aks \
  --query roleAssignmentMode -o tsv
```

Expect `LegacyRegistryPermissions` for a registry created with the course
templates. An ABAC-enabled registry reports `AbacRepositoryPermissions`.
ABAC means attribute-based access control. If the output is empty or neither
recognized value, stop; do not guess the branch and do not change the
registry's mode for this exercise.

**1e. Capture the kubelet identity and the registry ID.** The kubelet is the
agent on each node that pulls images; it has its own managed identity, which
is **not** the workload identity the application uses to call Azure.

```bash
KUBELET_ID=$(az aks show \
  --resource-group rg-globomantics-aks \
  --name aks-globomantics-prod \
  --query identityProfile.kubeletidentity.objectId -o tsv)
ACR_ID=$(az acr show --name acrglobomantics \
  --resource-group rg-globomantics-aks --query id -o tsv)
printf 'kubelet: %s\nregistry: %s\n' \
  "${KUBELET_ID:-<empty>}" "${ACR_ID:-<empty>}"
```

Expect a GUID and a resource ID ending in `/registries/acrglobomantics`. Stop
if either shows `<empty>`. These variables exist only in this shell session;
recapture them in a new terminal.

**1f. Grant the pull role: run exactly one branch.**

*`LegacyRegistryPermissions` (the expected case for this lab):*

```bash
az aks update \
  --resource-group rg-globomantics-aks \
  --name aks-globomantics-prod \
  --attach-acr acrglobomantics -o none
```

This assigns `AcrPull` on the registry to the kubelet identity and can take a
minute or two.

*`AbacRepositoryPermissions` only (do not run for a legacy registry):*
`--attach-acr` is not supported with ABAC, so assign the repository reader
role to the same kubelet ID at registry scope:

```bash
az role assignment create \
  --assignee-object-id "$KUBELET_ID" \
  --assignee-principal-type ServicePrincipal \
  --role 'Container Registry Repository Reader' \
  --scope "$ACR_ID" -o none
```

Without an ABAC condition, this role covers all repositories in that registry.
This exercise uses a dedicated lab registry; use a repository-scoped ABAC
condition when a shared registry requires a narrower boundary.

**1g. Read the actual grant.**

```bash
az role assignment list \
  --assignee-object-id "$KUBELET_ID" \
  --scope "$ACR_ID" \
  --query "[].roleDefinitionName" -o tsv
```

Expect `AcrPull` (or `Container Registry Repository Reader` on ABAC). If it is
empty, wait a minute and repeat only this read, up to about five times, then
stop and check the previous step. A new assignment can take minutes to
propagate. This lists a grant; it does not prove a pull.

**1h. Read the Deployment (not applied here).**

```bash
cat k8s/base/deployment.yaml
```

It sets two replicas, the private image, port 8080,
`serviceAccountName: orders-api-sa`, the workload identity label, resource
requests/limits and a TCP readiness probe. That probe checks the port opens;
it does not prove the API can read Key Vault. The image has not been pulled
yet, so `ImagePullBackOff` is still possible later.

### 2. Configure the Gateway API path

**2a. Platform enablement (already done by shared setup; do not repeat).**
For reference, the command that enabled it on this existing cluster is:

```bash
az aks update \
  --resource-group rg-globomantics-aks \
  --name aks-globomantics-prod \
  --enable-gateway-api \
  --enable-app-routing-istio -o none
```

**2b. Check the control plane and GatewayClass.**

```bash
kubectl get pods --namespace aks-istio-system
kubectl get gatewayclass approuting-istio
```

Expect `istiod` pods Ready and `ACCEPTED` = `True`. An accepted class means
the implementation is available; it does not mean any application is
reachable.

**2c. Read the Gateway, then create its namespace and apply it.**

```bash
cat k8s/base/gateway.yaml
kubectl create namespace orders-ingress
kubectl apply -f k8s/base/gateway.yaml
```

The Gateway names the `approuting-istio` class, listens for HTTP on port 80
and admits routes only from the `orders` namespace. If the namespace already
exists, `AlreadyExists` is fine; continue.

**2d. Wait for `Programmed`.**

```bash
kubectl wait --for=condition=Programmed gateway/orders-gateway \
  --namespace orders-ingress --timeout=120s
kubectl get deployment,service --namespace orders-ingress
```

Expect `condition met` and a managed proxy Deployment and Service named from
`orders-gateway` and `approuting-istio`. `Programmed` means the implementation
applied the Gateway's configuration, not that a backend is serving. On a
timeout, stop: confirm 2b, run
`kubectl describe gateway orders-gateway --namespace orders-ingress`, and wait
before retrying only the wait. Do not rerun the other commands.

**2e. Read and apply the Service, then the route.**

```bash
cat k8s/base/service.yaml
kubectl apply -f k8s/base/service.yaml
cat k8s/base/httproute.yaml
kubectl apply -f k8s/base/httproute.yaml
```

The Service is `ClusterIP` (internal only) and selects `app: orders-api`. The
route lives in `orders`, names one parent (the Gateway's `http` listener),
matches host `orders-api.example` and sends all paths to the Service on 8080.
The Gateway and route are in different namespaces on purpose: the operator
owns the Gateway, the app team owns the route.

**2f. Read the route's conditions and the endpoints.**

```bash
kubectl get httproute orders-api --namespace orders \
  -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status}{"\n"}{end}'
kubectl get endpointslice --namespace orders \
  --selector kubernetes.io/service-name=orders-api
```

Expect `Accepted=True` and `ResolvedRefs=True`, then no ready endpoints,
because no pods exist yet. Status can lag: wait about 30 seconds and repeat
only the first command, a few times at most. If either condition is missing or
`False`, stop and run
`kubectl describe httproute orders-api --namespace orders` to read the reason.
`Accepted` and `ResolvedRefs` do not prove a request can reach a pod.

### 3. Apply the network boundary

**3a. Check the running cluster's policy configuration.** The engine was
chosen when the cluster was created. Read the live settings before applying a
policy; inspecting the Bicep template is not an extra required demo step.

```bash
az aks show \
  --resource-group rg-globomantics-aks \
  --name aks-globomantics-prod \
  --query "{networkPolicy:networkProfile.networkPolicy,networkDataplane:networkProfile.networkDataplane}" \
  -o yaml
```

Expect `cilium` for both. If either is missing or `none`, stop: Kubernetes
accepts a NetworkPolicy even when nothing enforces it. Diagnose how the cluster
was created rather than enabling production features blindly.

For optional creation-time reference, `../infra/main.bicep` records the
Azure CNI Overlay/Cilium settings in `networkProfile`. This read does not
change the engine, and a reported engine is not proof of traffic enforcement.

**3b. Read the policy and the namespace label it uses.**

```bash
cat k8s/base/networkpolicy.yaml
kubectl get namespace orders-ingress --show-labels
```

The policy selects pods labeled `app: orders-api`, lists `Ingress`, and allows
TCP 8080 from namespaces labeled `kubernetes.io/metadata.name=orders-ingress`
(Kubernetes sets that label automatically). Policies are additive, and the
`namespaceSelector` trusts **every pod** in `orders-ingress`, not only one
proxy, so keep that namespace dedicated to ingress.

**3c. Apply and describe it.**

```bash
kubectl apply -f k8s/base/networkpolicy.yaml
kubectl describe networkpolicy orders-api-allow-gateway --namespace orders
```

Expect `created` and a description echoing the selector, namespace and port.
This shows the object was accepted, not that traffic is blocked; the next
module sends the requests.

**3d. Compare identity and routing for the same workload.**

```bash
grep -nE 'serviceAccountName|azure.workload.identity/use' k8s/base/deployment.yaml
kubectl get httproute orders-api --namespace orders \
  -o jsonpath='{.spec.hostnames[0]}{"\n"}'
```

Expect the workload identity label, `orders-api-sa`, then `orders-api.example`.

## Optional scripts (alternative to the manual commands)

Run these **instead of** the corresponding operations in steps 1f–3c, never
in addition. Still inspect the source/manifests and complete the comparison
in 3d. From this folder:

```bash
bash ./01-authorize-image-and-prepare.sh   # checks the tag, reads the mode, grants one role
bash ./02-configure-gateway-path.sh        # namespace, Gateway, Service, route
bash ./03-apply-network-boundary.sh        # reads the engine, applies the policy
```

Script 01 takes the legacy or ABAC branch itself and stops on an unrecognized
mode. Script 02 creates the namespace with a client-side dry run piped into
`kubectl apply`, so it is safe to rerun. The scripts print results but do not
replace reading the manifests above.

## PowerShell equivalents

Bash is the demonstrated path. The numbered `.ps1` scripts are an alternative
to the manual commands, with the same "one path, not both" rule. For manual
PowerShell use, inspect manifests with `Get-Content`, store the IDs with
`$KUBELET_ID = az aks show ...`, and use the same `az` and `kubectl` commands.

## Troubleshooting

| Symptom | Likely cause and next step |
| --- | --- |
| Gateway never `Programmed` | Gateway API/app routing not enabled, or the address is still being assigned. Check 2b, describe the Gateway, wait; do not rerun other steps. |
| `GatewayClass approuting-istio` not found | Run the enablement command in 2a (Azure CLI 2.86.0+) with permission to update the cluster. |
| `roleAssignmentMode` empty or unrecognized | Stop; check your Azure CLI version and `az acr show` output. Do not change the registry mode to suit the exercise. |
| Image tag not found | Run the build in 1b, then repeat 1c. |
| Grant list empty | Propagation can take minutes; repeat the read a few times, then recheck the 1f branch you ran. |
| `networkPolicy` missing or `none` | Stop. The policy would be accepted but unenforced; diagnose the cluster's creation settings. |

## Undo (scoped to this module)

Delete only what you created here. Do **not** delete other role assignments
on your registry unless you know they were created by this exercise.

```bash
kubectl delete -f k8s/base/networkpolicy.yaml --ignore-not-found
kubectl delete -f k8s/base/httproute.yaml --ignore-not-found
kubectl delete -f k8s/base/service.yaml --ignore-not-found
kubectl delete -f k8s/base/gateway.yaml --ignore-not-found
kubectl delete namespace orders-ingress --ignore-not-found
```

To also remove the registry role created in step 1f, list it (step 1g) and
delete only that assignment with `az role assignment delete` using its ID.
`scripts/cleanup.sh` at the repository root removes everything.

## Verification status

- 2026-10-18: **static/syntax** checks only for the module scripts.
- 2026-10-21: the Orders API request handler was exercised locally with a mocked
  Azure SDK; Azure CLI 2.90.0 and an existing cluster at Kubernetes 1.35 with
  `kubectl` 1.36.1 (within supported skew) were observed. The cluster reported
  Cilium for dataplane and policy, an accepted `approuting-istio`
  GatewayClass and a `LegacyRegistryPermissions` registry with the
  `orders-api:1.0.0` tag.
- **Pending (not yet executed live):** the manual commands above as written, the
  kubelet registry grant, Gateway `Programmed`, route conditions, policy
  application and any request enforcement. Treat expected outputs as
  expectations until recorded.

Sources: [AKS registry integration](https://learn.microsoft.com/azure/aks/cluster-container-registry-integration),
[Gateway API setup](https://learn.microsoft.com/azure/aks/app-routing-gateway-api),
[network policies](https://learn.microsoft.com/azure/aks/use-network-policies),
and [Kubernetes version skew](https://kubernetes.io/releases/version-skew-policy/).
