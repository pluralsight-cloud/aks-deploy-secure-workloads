# Module 4 runbook — Deploying and verifying a protected workload

## Scope

This runbook deploys the Orders API onto the application path Module 3
prepared, confirms it reaches a serving steady state, and then verifies the
path with one positive request and two negative ones. It is the last module of
the course and creates no new Azure resources.

Run all commands from this directory as the setup/admin identity. Bash is
the demonstrated path. The numbered scripts are an optional alternative that
bundles the same actions; use the manual commands or the scripts, not both.
Shell variables (`GATEWAY_IP`, `CLUSTER_IP`) exist only in the shell where you
set them.

## Prerequisites

- Bash 3.2+, `curl`, Azure CLI 2.86.0+, and `kubectl` within one minor version
  of the AKS server (the supported skew; a same-minor pin is preferred. The
  observed lab pair is server 1.35.x with kubectl 1.36.1, which is supported but
  not an exact match). See <https://kubernetes.io/releases/version-skew-policy/>.
- An active Azure login and Kubernetes context as the **setup/admin** account
  that created the cluster. The Module 1 operator cannot create resources in
  `default`.
- The kubelet identity can pull `orders-api:1.0.0` from your registry (the
  Module 3 grant).
- Every Module 3 object already exists: the kubelet identity's registry
  authorization, the `orders-api` Service, the `orders-gateway` Gateway in
  `orders-ingress`, the `orders-api` HTTPRoute, and the
  `orders-api-allow-gateway` NetworkPolicy.
- `orders-gateway` reports `Programmed=True` and has a published address.
- No `orders-api` Deployment or pods exist yet.
- The Module 2 test pod `orders-api-sa-test` has been removed, so the only
  `orders-api-sa` consumer is the real Deployment.
- `../module-03-secured-application-path/k8s/base/deployment.yaml` is unchanged
  from Module 3. That file is the single source for the Deployment; this module
  does not carry its own copy.

## Environment for optional scripts

These variables configure the optional numbered scripts, not the literal
manual commands below. For the manual path, substitute your chosen values in
each command and the manifests so the names stay consistent.

| Variable | Default |
| --- | --- |
| `NAMESPACE` | `orders` |
| `INGRESS_NAMESPACE` | `orders-ingress` |
| `GATEWAY_NAME` | `orders-gateway` |
| `SERVICE_NAME` | `orders-api` |
| `SERVICE_PORT` | `8080` |
| `ROUTE_HOST` | `orders-api.example` |
| `WRONG_HOST` | `not-orders-api.example` |
| `TEST_NAMESPACE` | `default` |
| `BYPASS_POD` | `bypass-test` |
| `BYPASS_MAX_TIME` | `5` |
| `REQUEST_MAX_TIME` | `15` |
| `ROLLOUT_TIMEOUT` | `180s` |
| `DEPLOYMENT_MANIFEST` | `../module-03-secured-application-path/k8s/base/deployment.yaml` |

## Setup and commands

From the repository root:

```bash
cd module-04-deploying-verifying-protected-workload
az account show --query user.name -o tsv
```

### 1. Check the start state

```bash
kubectl get deployment,pods --namespace orders --selector app=orders-api
```

Expect no Deployment or pods. A leftover `orders-api-sa-test` pod has a
different label and is not listed, but remove it before continuing (it is an
earlier test, so only delete it if you created it):
`kubectl delete pod orders-api-sa-test --namespace orders --ignore-not-found`.

### 2. Deploy the workload and confirm steady state

Read the Deployment from the previous module, then apply it. The readiness
probe is a TCP check on port 8080: it shows the port opens, not that the
application can read Key Vault (the request in step 4 checks that).

```bash
cat ../module-03-secured-application-path/k8s/base/deployment.yaml
kubectl apply -f ../module-03-secured-application-path/k8s/base/deployment.yaml \
  --namespace orders
kubectl rollout status deployment/orders-api \
  --namespace orders --timeout=180s
kubectl get pods --namespace orders
kubectl get deployment orders-api --namespace orders
kubectl get endpointslice --namespace orders \
  --selector kubernetes.io/service-name=orders-api \
  --output jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
```

Expected output: the apply receipt, then
`deployment "orders-api" successfully rolled out`, then two pods `Running` with
`READY 1/1`, `AVAILABLE` equal to 2 on the Deployment, and two endpoint
addresses with `ready=true`, across every slice returned.

`kubectl rollout status` watches and blocks by default and honours
`--timeout`. Following standard kubectl behaviour it exits non-zero when the
rollout fails or the timeout is reached.

Allow time for the first image pull. A successful rollout is supporting
evidence, not isolated proof of a fresh authenticated registry pull, because a
node may already have cached the image.

If the rollout fails or times out, **stop**. Read the evidence before changing
anything:

```bash
kubectl get pods --namespace orders
kubectl describe pods --namespace orders --selector app=orders-api
kubectl get events --namespace orders --sort-by=.lastTimestamp
```

`ImagePullBackOff` points to the registry grant or the tag; do not reapply
repeatedly. To inspect the full EndpointSlice objects, repeat the last read
with `--output yaml` instead of the JSONPath expression.

### 3. Create the in-cluster test pod

The negative test needs a client inside the cluster but outside `orders`.
Read the manifest first: a pod named `bypass-test` in `default`, image
`curlimages/curl:8.11.1`, running `sleep infinity` so it stays available.

```bash
cat k8s/test/bypass-test.yaml
kubectl apply -f k8s/test/bypass-test.yaml
kubectl wait --for=condition=Ready pod/bypass-test \
  --namespace default --timeout=120s
```

Setup/admin creates the pod. If it already exists, `apply` reports
`unchanged`; that is fine. The HTTP requests that follow are not authenticated
as an Azure user.
(`bash ./01-prestage-bypass-test.sh` does the same as an optional alternative.)

### 4. Verify the protected path

Check the Gateway, then capture its address and the Service's cluster IP with
separate commands:

```bash
kubectl get gateway orders-gateway --namespace orders-ingress
GATEWAY_IP=$(kubectl get gateway orders-gateway \
  --namespace orders-ingress \
  --output jsonpath='{.status.addresses[0].value}')
CLUSTER_IP=$(kubectl get service orders-api \
  --namespace orders \
  --output jsonpath='{.spec.clusterIP}')
printf 'Gateway: %s\nService: %s\n' "${GATEWAY_IP:-<empty>}" "${CLUSTER_IP:-<empty>}"
```

Expect `PROGRAMMED True` and two different IPs. Stop if either shows
`<empty>`.

From your workstation, test the correct host:

```bash
curl --max-time 15 -sS -i -H "Host: orders-api.example" "http://$GATEWAY_IP/"
```

Expect HTTP 200 and application-generated JSON with `keyVaultConfig: loaded`,
`secretValue: redacted`, and `detail: secret read succeeded`. This reports the
application's Key Vault read status, which it caches for 30 seconds; it does
not guarantee a fresh vault request for every HTTP request. An unsuccessful
check returns 503 with unavailable configuration. Never print the secret
value. Plain HTTP proves nothing about TLS.

On an initial 503, wait at least 30 seconds, then repeat only this curl
request, at most three attempts total. If it still fails or curl reports a
transport error, stop and inspect the application logs:

```bash
kubectl logs --namespace orders deployment/orders-api --tail=20
```

Check workload identity, vault permission and network reachability before
changing anything; reapplying the Deployment is not the remedy for a cached
status. Do not continue until the positive check succeeds.

Then test an unmatched host:

```bash
curl --max-time 15 -sS -i -H "Host: not-orders-api.example" "http://$GATEWAY_IP/"
```

Expect HTTP 404, not a transport error.

Finally, bypass the Gateway from the `default` namespace. Run it interactively
without `set -e`, because the failure is intentional:

```bash
kubectl exec --namespace default bypass-test -- \
  curl --max-time 5 -s -o /dev/null -w '%{http_code}\n' \
  "http://$CLUSTER_IP:8080/"
```

Then run this **immediately**, before any other command overwrites `$?`:

```bash
echo "curl exit status: $?"
```

The command discards the body and prints only the HTTP status. Expect `000`
and curl exit 28 (timed out), 7 (could not connect) or 56
(receiving failed); `kubectl exec` is expected to pass the
inner status through, which the recording will confirm. `000` means no HTTP
response arrived. The result is **consistent with** the policy dropping the
traffic; it is not isolated causal proof, because other causes (a pod or
network problem) could also fail. Do not weaken or delete the policy to
manufacture a stronger proof.

Takeaways: the correct host returned the application's redacted Key Vault
status, the wrong host returned a routing 404, and the in-cluster bypass got
no HTTP response. The Gateway listens on **plain HTTP**; this is not TLS.

## Optional scripts (alternative, not a prerequisite)

`bash ./02-deploy-and-confirm-steady-state.sh` replaces step 2, and
`bash ./03-verify-protected-path.sh` replaces step 4; the latter captures each
curl status for automation and accepts only HTTP `000` with exit 28, 7 or 56
for the bypass. `.ps1` equivalents exist. Do not run a script after doing the
same step manually.

## Cleanup

Remove only the negative-test pod this module added:

```bash
kubectl delete -f k8s/test/bypass-test.yaml --ignore-not-found
```

To remove the Orders API Deployment:

```bash
kubectl delete -f ../module-03-secured-application-path/k8s/base/deployment.yaml \
  -n orders --ignore-not-found
```

`scripts/cleanup.sh` at the repository root removes everything, including the
cluster.

## Verification status

2026-10-18 — **static/syntax** checks only. 2026-10-21 — the request handler
was exercised locally with a mocked Azure SDK (200 loaded/redacted on success;
503 unavailable on token-exchange and Key Vault 403 errors; no secret in
responses). **Pending (not yet executed live):** rollout, the real Key Vault
response, wrong-host result, bypass result and cleanup. Sources:
[Deployment rollout](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#checking-rollout-status),
[NetworkPolicy semantics](https://kubernetes.io/docs/concepts/services-networking/network-policies/),
and [Gateway API HTTPRoute](https://gateway-api.sigs.k8s.io/api-types/httproute/).
