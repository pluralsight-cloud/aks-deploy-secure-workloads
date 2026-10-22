# Deploy Secure Workloads on AKS — Sample Code

>> Course URL: https://www.pluralsight.com/courses/aks-deploy-secure-workloads

Use this repository to follow the course's commands in order. **Bash is the
demonstrated shell**, using Azure CLI and `kubectl`. PowerShell equivalents
are supplied for the core module exercise scripts; Module 2's preparation
and image helpers use Bash. `azd` is an alternative way to
prepare the same starting environment, not a second module workflow.

> **Cost and cleanup:** Setup creates billable Azure resources. Use a disposable
> lab subscription, review the configuration below, and delete the environment
> when finished. Nothing here is intended for a production cluster.

## Lab configuration

| Setting | Course value |
| --- | --- |
| Region | `canadaeast` |
| Resource group | `rg-globomantics-aks` |
| Cluster / tier | `aks-globomantics-prod` / AKS Standard |
| System pool | 2 × `Standard_D4als_v6`, each 4 vCPUs / 8 GiB, x64 |
| Registry | `acrglobomantics` |
| Key Vault | `kv-globomantics-orders` (Azure RBAC mode) |
| Application namespace | `orders` |
| Application image | `acrglobomantics.azurecr.io/orders-api:1.0.0` |
| Networking | Azure CNI Overlay, Cilium |
| Gateway implementation | Application routing Gateway API, `approuting-istio` |

The Linux VM retail price checked on 2026-10-18 was USD 0.179 per node-hour,
or USD 0.358/hour for two nodes. **That is not the full lab cost:** AKS
Standard, disks, load balancing/public IP, traffic, ACR and Key Vault add
charges. Your agreement and current prices may differ. See the
[Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/).

Use an x64 size with at least 4 vCPUs and 4 GB memory for the system pool;
B-series is unsupported. Keep two nodes for this lab. See
[AKS system-pool requirements](https://learn.microsoft.com/azure/aks/use-system-pools).
ARM64 sizes do not match this repository's `linux/amd64` image builds.

## Prerequisites

- A **setup/admin** account with resource-creation and role-assignment rights
  in the lab subscription (for example, Owner or Contributor plus User Access
  Administrator).
- Permission to create/manage an Entra group and add its operator member.
  Subscription Owner alone does not grant Entra directory permissions.
- A **different, low-privilege Entra user in the same tenant**, with sign-in
  and MFA available. It must have no unrelated direct, group, inherited, or
  in-cluster grants that would invalidate the Module 1 access checks.
- Azure CLI **2.86.0+**, Bash **3.2+**, `kubectl`, `kubelogin`, curl and jq.
  Use a `kubectl` version matching the AKS server minor.
- Docker with Buildx if ACR Tasks cannot build the application image.
- For the alternative setup: Azure Developer CLI (`azd`); on Windows,
  PowerShell **7.4+** and the same Azure/Kubernetes tools.

## 1. Prepare the environment (Bash — course path)

Run from this repository's root, signed in as **setup/admin**:

```bash
az login
az account set --subscription "<your-lab-subscription-name-or-id>"
az account show --query '{account:user.name,subscription:name}' -o table

export LOCATION=canadaeast
export NODE_VM_SIZE=Standard_D4als_v6
export NODE_COUNT=2
unset CONFIRM_ROTATE_CERTS

bash scripts/check-prerequisites.sh
```

Registry and vault names must be globally unique. If the course names are
unavailable, export your replacements **before** setup:

```bash
export REGISTRY_NAME="<your-unique-alphanumeric-registry-name>"
export KEY_VAULT_NAME="<your-unique-key-vault-name>"
```

Then provision and build the image (billable; allow at least 15 minutes):

```bash
bash scripts/provision.sh
bash scripts/build-images.sh
```

Keep these exports in the terminal used for the modules. In a new terminal,
restore any overrides before reconnecting with `bash scripts/connect.sh`.
If you changed names, also update the `image:` and `KEY_VAULT_NAME` values in
`module-03-secured-application-path/k8s/base/deployment.yaml`, and the vault
name in `module-02-workload-identity/orders-api-sa-test.yaml`. Scripts do not
rewrite the manifests.

### If Azure rejects the VM size

Check access for **your** subscription before choosing another size or region:

```bash
az vm list-skus --location "$LOCATION" \
  --resource-type virtualMachines --size "$NODE_VM_SIZE" --all \
  --query "[?name=='$NODE_VM_SIZE'].{name:name,restrictions:restrictions}" \
  -o json
```

A `Location` restriction with `NotAvailableForSubscription` blocks this size
in the region. Choose another compatible size/region or
[request SKU access](https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/error-sku-not-available).
Also check regional and VM-family vCPU quotas. An unrestricted listing does
not guarantee allocation or sufficient quota.

Only change regions before the lab resources exist; this does not move an
existing cluster. An empty resource group left by a failed attempt can be
reused even if its metadata location differs: the script passes the resource
location explicitly to Bicep.

### If the cluster stays in `Creating`

Do not start a second deployment or delete the cluster just because creation
is slow. Inspect failed Activity Log events in the cluster's **node resource
group**, not only the main resource group:

```bash
NODE_RESOURCE_GROUP="$(az aks show \
  -g rg-globomantics-aks -n aks-globomantics-prod \
  --query nodeResourceGroup -o tsv)"
az monitor activity-log list --resource-group "$NODE_RESOURCE_GROUP" \
  --offset 2h --status Failed --max-events 10 \
  --query '[].{time:eventTimestamp,operation:operationName.localizedValue,message:properties.statusMessage}' \
  -o json
```

In the course lab, public-IP creation repeatedly failed with
`SubscriptionNotRegisteredForFeature`, specifically naming
`Microsoft.Network/AllowBringYourOwnPublicIpAddress`. Registering that
feature unblocked public-IP creation. **Only use the following remediation
when your error names this feature**, with authorization to change
subscription-level registrations:

```bash
az feature register --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress
az feature show --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress \
  --query properties.state -o tsv
```

Wait until the feature reports `Registered`, then refresh the provider:

```bash
az provider register --namespace Microsoft.Network
```

Check whether the existing AKS operation resumes before considering a retry.
Feature registration alone does not prove the cluster or its nodes are ready;
registration can also require Microsoft approval. Do not automatically abort
or recreate an in-progress cluster.

## Alternative setup: Azure Developer CLI (`azd`)

Use this **instead of** the Bash provisioning commands above. Both `az` and
`azd` need your setup/admin sign-in. Use the environment name `default` so
the resource group matches the course commands:

```bash
az login
azd auth login
azd env new default
azd env set AZURE_LOCATION canadaeast
azd env set NODE_VM_SIZE Standard_D4als_v6
```

If needed, set unique names before provisioning:

```bash
azd env set REGISTRY_NAME "<your-unique-alphanumeric-registry-name>"
azd env set KEY_VAULT_NAME "<your-unique-key-vault-name>"
```

Run `azd up`, select your lab subscription, and accept the costs. Setup creates
the same two-node cluster, registry, vault, empty namespace, Gateway API
platform implementation, and Orders API image. It does **not** run the module
exercises. The preprovision hook aligns Azure CLI with the selected subscription.

`azd` settings belong to its environment; they do not export values into your
parent terminal. If you changed registry/vault names, export the same
`REGISTRY_NAME` and `KEY_VAULT_NAME` for Bash module scripts (or set the
corresponding `$env:` variables for PowerShell), and update the manifests as
described above. Do not switch to a differently named `azd` environment and
then run the course's hard-coded resource-group commands unchanged.

If infrastructure succeeded but a postprovision hook failed, resolve the
reported problem and run `azd hooks run postprovision`. Avoid reapplying the
infrastructure after Module 1: the template deliberately enables local
accounts for that module's starting state.

For Bash setup, if Azure deployment succeeded but the local provisioning
process ended before platform setup finished, resume without reapplying Bicep:

```bash
bash scripts/configure-platform.sh
bash scripts/build-images.sh
```

Run these as setup/admin with the same exported resource-name overrides.
The platform helper requires a `Succeeded` cluster, reconnects `kubectl`,
enables Gateway API if missing, creates the namespace, and waits for the
GatewayClass to be Accepted.

## 2. Verify the Module 1 starting state

As setup/admin, from the repository root:

```bash
az aks show -g rg-globomantics-aks -n aks-globomantics-prod \
  --query '{region:location,state:provisioningState,managedEntra:aadProfile.managed,azureRbac:aadProfile.enableAzureRbac,localAccountsDisabled:disableLocalAccounts}' \
  -o json
kubectl get nodes
kubectl get namespace orders
kubectl get pods,deployments,services -n orders
az ad group list --display-name grp-globomantics-orders-operators \
  --query '[].{name:displayName,id:id}' -o table
```

Expect `canadaeast`, `Succeeded`, both Entra/RBAC values `true`, and
`localAccountsDisabled: false`; two Ready nodes; an empty `orders` namespace;
and no operator group yet. The platform's `approuting-istio` GatewayClass must
also be Accepted. **The Orders API is not deployed until Module 4.**

## 3. Follow the module runbooks

Each runbook gives the demonstrated Bash commands, expected results,
identity switches, and optional bundled-script equivalents. Choose manual
steps **or** the corresponding bundled script; do not do both for the same
exercise. Run each module from its own folder.

| Module | Guide |
| --- | --- |
| 1 — Administrative access | [runbook](module-01-administrative-access/runbook.md) |
| 2 — Workload identity | [runbook](module-02-workload-identity/runbook.md) |
| 3 — Secured application path | [runbook](module-03-secured-application-path/runbook.md) |
| 4 — Deploy and verify | [runbook](module-04-deploying-verifying-protected-workload/runbook.md) |

Module 2 uses the public image `ghcr.io/mhadaily/orders-identity-test:1.0.1`.
Its source, Dockerfile and
[complete optional build/push instructions](apps/identity-test/README.md) are
included. Normal follow-along requires no GitHub account, Docker or access
to the author's registry credentials. Before starting Module 2, check public
access from this repository root:

```bash
bash scripts/check-identity-test-image.sh
```

The [Module 2 runbook](module-02-workload-identity/runbook.md) includes every
preparation command shown in the video and a `00-prepare-demo.sh` helper,
followed by the existing identity/configuration and verification scripts.
It also explains selecting a public image you build in your own GHCR
namespace. No `instructor/` scripts or recording-only VM are required.
Do not print Key Vault secret values, tokens, or credentials.

Modules 3 and 4 use the Orders API source in `apps/orders-api`, not the separate
identity-test image. The Module 3 manual path explains the image build, registry
permission-mode decision, kubelet grant, Gateway/Service/route and network
policy one action at a time; it leaves the Deployment unapplied. Its numbered
scripts are an alternative to those manual mutations.

Module 4 applies that same Deployment manifest and introduces its curl test
pod from `module-04-deploying-verifying-protected-workload/k8s/test/bypass-test.yaml`.
Follow the runbook's ready-state checks before the three HTTP requests, and
read the expected failing request's exit status immediately. These are
student lab steps; no instructor recording host or private recording helper
is part of this workflow.

## 4. Clean up after the whole course

For Bash setup, run from the repository root with the same overrides:

```bash
CONFIRM_CLEANUP=YES bash scripts/cleanup.sh
```

This deletes the lab resource group, attempts to purge the soft-deleted vault,
and removes the Entra operator group. Confirm deletion in Azure; vault purge
requires separate permission and can fail.

For `azd` setup, use `azd down` and review its deletion/purge prompts. The Entra
group created in Module 1 is outside the Bicep deployment; remove that group
separately once you no longer need it:

```bash
az ad group delete --group grp-globomantics-orders-operators
```

Do not clean up between modules; later modules reuse the earlier state.

## Verification status

As of 2026-10-18: Canada East / `Standard_D4als_v6` reported no subscription
SKU restrictions, and the two-node configuration passed ARM validation
before this repository-wide alignment. The aligned Bicep templates compile
locally; a subsequent ARM validation was blocked by an already-running
cluster creation, not completed. These are **preflight/local checks**, not
live end-to-end verification. See each module runbook for its verification
level. The Module 2 runbook records the subsequently verified public-image
pull and redacted secret read on 2026-10-20. Complete fresh provisioning,
routing, negative
requests, and cleanup still require a live lab run before relying on their
expected outputs.

Local checks run with Azure CLI 2.90.0, Bicep 0.46.1, PowerShell 7.6.6,
and `kubectl` client v1.36.1. These are validation-machine versions, not a
locked AKS server version. The setup regression checks exercise mocked
success/failure paths and do not contact Azure:

```bash
python3 -m unittest discover -s tests -v
shellcheck -S warning -e SC2034 scripts/*.sh
az bicep build --file infra/main.subscription.bicep --stdout
```

PowerShell-dependent tests are skipped when `pwsh` is unavailable. ShellCheck
SC2034 is excluded because `env.sh` defines values used by scripts sourcing it.

## Layout

```text
azure.yaml    Alternative azd setup hooks
infra/        Subscription and resource-group Bicep templates
scripts/      Shared setup, image build, connection, and cleanup helpers
apps/         Orders API and redacting identity-test image source
module-NN-*/  Module scripts, manifests, and step-by-step runbooks
tests/        Local setup and image-tool regression checks (no Azure provisioning)
```
