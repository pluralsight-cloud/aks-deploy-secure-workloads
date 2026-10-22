# Module 2 runbook — Granting and diagnosing workload identity

## What you will do

Let a pod read a Key Vault secret using Microsoft Entra Workload ID, without
embedding an Azure client secret or certificate in its pod specification.
The application secret remains in Key Vault; the test prints only a redacted
result.

You will meet three pieces, and it helps to name them up front:

- **Identity** — a user-assigned managed identity. Its `principalId` is used
  for Azure role assignments; its `clientId` goes on the ServiceAccount.
- **Trust** — a federated credential that says "tokens issued by this cluster
  for `system:serviceaccount:orders:orders-api-sa` may become this identity".
- **Permission** — the `Key Vault Secrets User` role on one vault.

## Prerequisites

- Use Bash 3.2+, Azure CLI, `kubectl`, `kubelogin`, curl and jq. The default
  public-image path needs neither Docker nor GitHub authentication. Docker
  with Buildx and GitHub package-write permission are needed only if you choose
  to rebuild and publish your own image.
- An existing AKS Standard cluster in the lab resource group, with
  Entra-backed authentication and an authorized setup user. The repository
  `README.md` supplies one way to provision it; the preparation commands below
  explain this demo's starting state without requiring a Bicep walkthrough.
- Complete the successful workload read in step 4 before the diagnostic
  exercise in step 5. That exercise changes trust and vault permission,
  not the administrative boundary tested in Module 1.
- `orders-api-sa-test.yaml` references the course image, which must be public:
  `ghcr.io/mhadaily/orders-identity-test:1.0.1`. To use an image you built from
  `../apps/identity-test`, set it before running scripts 02 and 03:

  ```bash
  export IDENTITY_TEST_IMAGE="<your-registry>/orders-identity-test:1.0.1"
  ```

  The [image source instructions](../apps/identity-test/README.md) provide
  step-by-step authentication, build/push, Public visibility and verification
  commands, plus a runnable publishing script for your own GHCR namespace.
  Private ACR image pulls
  are not authorized until Module 3. If following the manual pod commands
  below, edit the manifest's `image:` directly; `IDENTITY_TEST_IMAGE` is used
  only by the bundled scripts/helpers.

From the repository root:

```bash
cd module-02-workload-identity
```

**Setup/admin** means your existing Microsoft Entra setup user, not a new
account created by this module and not an AKS local `--admin` credential.
It needs resource-creation and role-assignment rights in the lab subscription,
plus Kubernetes administration rights on this cluster. Shared setup assigns
that user Azure Kubernetes Service RBAC Cluster Admin on the cluster; the
subscription prerequisites are in the repository `README.md`.

Shared setup (`scripts/provision.sh` → `infra/main.bicep` and
`scripts/configure-platform.sh`) created the cluster, enabled Workload ID and
OIDC, created the Azure RBAC vault and sample secret, and created `orders`.
It did **not** create `id-globomantics-orders`, its trust or vault role,
`orders-api-sa`, or the test pod. This module creates those.

Run Key Vault commands from a host that can reach your vault's data endpoint.
If your own lab uses a private endpoint, use an authorized host on that
network. An Azure login or an RBAC grant does not supply network access.
The author's recording VM is not a student prerequisite; do not disable
your vault's firewall to imitate that recording environment.

## Choose how to follow along

All paths below start from the downloaded **sample repository root**, the
folder containing `apps/`, `scripts/` and `module-02-workload-identity/`.
There is no required `instructor/` folder.

- **Command by command:** follow steps 1–4 below for Demo 2. They include the
  preparation shown briefly in the video. Step 5 is the later diagnostic demo.
- **Bundled scripts:** sign in as setup/admin, select your subscription and
  export the same lab-name overrides used during repository setup. Then run:

```bash
az login
az account set --subscription "<your-lab-subscription-name-or-id>"
bash scripts/check-identity-test-image.sh
cd module-02-workload-identity
bash 00-prepare-demo.sh
bash 01-configure-workload-identity.sh
bash 02-verify-workload-identity.sh
```

`00` connects to the existing cluster, enables Workload ID/OIDC only if
needed, creates the namespace and ServiceAccount, and prepares the dedicated
RBAC vault and fake sample secret if missing. It does not create a cluster,
convert an existing non-RBAC vault or overwrite an existing secret.
It grants the setup user Secrets Officer on the lab vault; that is not the
pod's read permission. Creating a missing vault incurs Azure charges.
If a new role is not active or the vault is unreachable, it prints the error
and stops rather than treating the missing access as a missing secret.
Wait for propagation or fix connectivity, then rerun `00`.

`01` creates the managed identity, trust and read grant; `02` recreates the
test pod and retries the redacted read. Expect `RESULT: SUCCESS ... (value
redacted)` and four `AZURE_*` settings. Do not run a script and its manual
equivalent as separate exercises. Neither path needs GitHub login or Docker
unless you choose the optional custom-image build.

## Steps

### 1. Prepare and confirm the start state (setup/admin)

The video briefly recaps some already-completed preparation. Here are those
commands for your own lab. If repository setup already prepared the cluster
and vault, skip their creation/enablement commands and confirm the state
below. Run missing preparation once, with permission to change the cluster
and create billable resources. The namespace and ServiceAccount apply
commands are safe to repeat.

```bash
export RESOURCE_GROUP=rg-globomantics-aks
export CLUSTER_NAME=aks-globomantics-prod
export LOCATION=canadaeast
export NAMESPACE=orders
export IDENTITY_NAME=id-globomantics-orders
export FEDERATED_CREDENTIAL_NAME=fed-orders-api
export SERVICE_ACCOUNT_NAME=orders-api-sa
export KEY_VAULT_NAME="<your-unique-key-vault-name>"

az logout && az login
az account set --subscription "<your-lab-subscription-name-or-id>"
az account show --query user.name -o tsv
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" \
  --overwrite-existing
kubelogin convert-kubeconfig -l azurecli
```

In the browser, select your **setup user**, not the limited operator.
`azurecli` mode reuses that login, not local `--admin` credentials.

Replace the vault placeholder with the name you provisioned (the video uses
`kv-globomantics-orders`). Use your own resource names if you overrode other
setup defaults. Exports make these values available to the child scripts too.
If you change namespace, ServiceAccount or vault, update `metadata.namespace`,
`spec.serviceAccountName` and `KEY_VAULT_NAME` in `orders-api-sa-test.yaml`
before applying it; those manifest fields are not rewritten by the scripts.

**Cluster enablement — run only if not already enabled:**

```bash
az aks update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --enable-workload-identity \
  --enable-oidc-issuer
```

OIDC (OpenID Connect) publishes the issuer information used to verify cluster
tokens; Workload ID enables projected-token injection for labeled pods.
If enablement is needed, wait for the update to finish before continuing.
Do not rerun provisioning after Module 1: its template would re-enable local
accounts.

**Create the namespace and ServiceAccount:**

```bash
kubectl create namespace "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Preview the ServiceAccount definition before applying it:

```bash
kubectl create serviceaccount "$SERVICE_ACCOUNT_NAME" \
  --namespace "$NAMESPACE" --dry-run=client -o yaml
```

`--dry-run=client` produces a definition without creating the ServiceAccount.
`-o yaml` prints it in the terminal; it does not save a file. Inspect these
fields (other generated metadata may vary by `kubectl` version):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: orders-api-sa
  namespace: orders
```

Now apply that definition:

```bash
kubectl create serviceaccount "$SERVICE_ACCOUNT_NAME" \
  --namespace "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
```

The pipe (`|`) sends the generated YAML directly to `kubectl apply -f -`.
Here, `-f -` reads the definition from standard input, not a file on disk.
Expect `serviceaccount/orders-api-sa created` on the clean first run (or
`configured` / `unchanged` on a repeat). The ServiceAccount now exists but
has no managed-identity annotation yet.

**Vault and sample-secret preparation — skip when already prepared:**

Use a globally unique vault name. These commands are a manual alternative
for the prepared vault state, not an additional exercise after shared setup.
Do not change an unrelated vault's authorization model.

```bash
az keyvault create \
  --resource-group "$RESOURCE_GROUP" --name "$KEY_VAULT_NAME" \
  --location "$LOCATION" --enable-rbac-authorization true -o none
```

This creates the vault in Azure RBAC mode. Capture its full resource ID to
scope the upcoming role assignment:

```bash
KEY_VAULT_ID="$(az keyvault show --name "$KEY_VAULT_NAME" --query id -o tsv)"
```

Capture the signed-in setup user's Entra object ID, not the pod's identity:

```bash
SETUP_USER_ID="$(az ad signed-in-user show --query id -o tsv)"
```

Allow that user to write secrets in this vault:

```bash
az role assignment create \
  --assignee-object-id "$SETUP_USER_ID" --assignee-principal-type User \
  --role "Key Vault Secrets Officer" --scope "$KEY_VAULT_ID" -o none
```

After that role has propagated, store the explicitly fake teaching string.
This tests storing/reading a value, not a real database connection.
Resource-creation permission alone does not grant permission to write secrets.

```bash
az keyvault secret set \
  --vault-name "$KEY_VAULT_NAME" --name orders-db-connection-string \
  --value 'demo-only-not-a-real-connection-string' -o none
```

`-o none` suppresses the secret-bearing response, not errors. This setup-user
Secrets Officer role is separate from the workload's Secrets User role.
Never replace the visible dummy with a real credential: the command can
appear in shell history and recordings.

**Optional file alternative, not a second seeding step:**

Create a local folder:

```bash
mkdir -p "$HOME/aks-demo"
```

Create `orders-db-connection-string.txt` there with the same fake value:

```bash
printf '%s' 'demo-only-not-a-real-connection-string' \
  > "$HOME/aks-demo/orders-db-connection-string.txt"
```

Use its exact path instead of `--value`; Key Vault stores the file contents,
not the path:

```bash
az keyvault secret set \
  --vault-name "$KEY_VAULT_NAME" --name orders-db-connection-string \
  --file "$HOME/aks-demo/orders-db-connection-string.txt" -o none
```

This file is created by the preceding command, not supplied in the repository.
Only dummy data is suitable for this on-screen example. For real values,
protect the source file and exclude it from version control and capture;
`--file` does not secure local storage automatically.

**Confirm the prepared state:**

```bash
az account show --query user.name -o tsv
az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" \
  --query '{workloadIdentity:securityProfile.workloadIdentity.enabled,issuer:oidcIssuerProfile.issuerUrl}' \
  -o json
kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" --namespace "$NAMESPACE"
```

Expect the setup user's sign-in name, `workloadIdentity: true`, a non-empty
issuer URL, and `orders-api-sa` in `orders`. Stop if any check fails.

### 2. Create the identity and capture both IDs

```bash
az identity create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$IDENTITY_NAME" \
  --query '{clientId:clientId,principalId:principalId}' -o table

IDENTITY_CLIENT_ID="$(az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --query clientId -o tsv)"
IDENTITY_PRINCIPAL_ID="$(az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --query principalId -o tsv)"

ISSUER_URL="$(az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --query oidcIssuerProfile.issuerUrl -o tsv)"
echo "$ISSUER_URL"
```

Expect two different GUIDs and the cluster's HTTPS OIDC issuer URL.

### 3. Configure trust, vault permission, and the ServiceAccount

The federated credential names the ServiceAccount created during preparation.
It does not create a Kubernetes object. The namespace and name in its subject
must match that ServiceAccount. This step adds its managed-identity annotation.

```bash
az identity federated-credential create \
  --resource-group "$RESOURCE_GROUP" \
  --identity-name "$IDENTITY_NAME" \
  --name "$FEDERATED_CREDENTIAL_NAME" \
  --issuer "$ISSUER_URL" \
  --subject "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}" \
  --audiences api://AzureADTokenExchange

az keyvault show --name "$KEY_VAULT_NAME" --query properties.enableRbacAuthorization -o tsv
KEY_VAULT_ID="$(az keyvault show --name "$KEY_VAULT_NAME" --query id -o tsv)"

az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" \
  --scope "$KEY_VAULT_ID"

kubectl annotate serviceaccount "$SERVICE_ACCOUNT_NAME" \
  --namespace "$NAMESPACE" \
  "azure.workload.identity/client-id=$IDENTITY_CLIENT_ID" --overwrite
kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" \
  --namespace "$NAMESPACE" -o yaml
```

Expect the exact federated subject
`system:serviceaccount:orders:orders-api-sa`, vault RBAC `true`, the
vault-scoped role assignment, and ServiceAccount YAML showing name
`orders-api-sa`, namespace `orders`, and the client-ID annotation. Stop if vault
RBAC is not `true`. Principal ID is for the grant; client ID is for the annotation.
Role assignments can take up to ten minutes to propagate.

### 4. Run the test pod and read its redacted result

#### Understand the program before applying its manifest

`orders-identity-test` is the container image of the Python program
`../apps/identity-test/identity_check.py`, included in this sample repository.
It is not the Orders API or an AKS-provided component. It isolates the
ServiceAccount's Azure access before adding the application's private registry
and routing setup.

Open the source and follow these operations in order:

1. `KEY_VAULT_NAME` selects the vault; `SECRET_NAME` defaults to
   `orders-db-connection-string`.
2. `WorkloadIdentityCredential()` uses the pod's injected identity settings.
3. `get_token("https://vault.azure.net/.default")` tests the token exchange.
   Its authentication error handler reports `TOKEN_EXCHANGE_FAILED`.
4. `SecretClient(...).get_secret(SECRET_NAME)` makes the actual secret read.
   Its HTTP error handler reports `KEY_VAULT_DENIED`; success prints a
   redacted `SUCCESS` line, not the value.
5. The final sleep loop keeps the pod available for `kubectl exec`. It does
   not repeat the read; recreate the pod to run a new check.

`../apps/identity-test/Dockerfile` installs the dependencies listed in
`requirements.txt`, copies that program, and starts it with
`CMD ["python", "identity_check.py"]`.

The image publisher builds and pushes that folder for `linux/amd64`, using
the `orders-identity-test:1.0.1` image tag. The GHCR package must be made public
separately. You consume the published image; you do not need to build it or
push to the author's registry namespace. If publishing your own alternative,
follow [the complete image build instructions](../apps/identity-test/README.md).
That page includes GitHub sign-in, the runnable build/push script for **your**
namespace, the separate Public visibility action and the exact verification
command. You never need permission to push into `mhadaily`.

#### Check image access before starting the pod

For the supplied image:

```bash
bash ../scripts/check-identity-test-image.sh
```

Expect `Anonymous manifest access passed: ghcr.io/mhadaily/orders-identity-test:1.0.1`.
This requests the registry token and manifest without your saved Docker login.
It proves the image is publicly accessible from this host, not yet that the
AKS node can pull it or that its ServiceAccount can read Key Vault.

If you followed the optional build instructions, select **your** published
image for scripts 02 and 03:

```bash
export IDENTITY_TEST_IMAGE="ghcr.io/<your-lowercase-ghcr-owner>/orders-identity-test:1.0.1"
bash ../scripts/check-identity-test-image.sh "$IDENTITY_TEST_IMAGE"
```

For the manual commands below, also replace the manifest's `image:` value
with that exact reference. An environment variable does not edit a YAML file.
Do not continue if the anonymous check fails; first resolve the tag,
visibility or registry connection using the troubleshooting section.

#### Apply the manifest and inspect the result

Inspect `orders-api-sa-test.yaml`, then run:

```bash
kubectl delete pod orders-api-sa-test --namespace "$NAMESPACE" --ignore-not-found
kubectl apply -f orders-api-sa-test.yaml
kubectl wait --namespace "$NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Running pod/orders-api-sa-test --timeout=180s
kubectl logs orders-api-sa-test --namespace "$NAMESPACE"
kubectl exec --namespace "$NAMESPACE" orders-api-sa-test -- env | grep '^AZURE_'
```

The first command removes only this disposable test pod if you are repeating
the exercise. It ensures the next apply starts a fresh check; it does not
delete the ServiceAccount, identity or secret. The Python test runs once,
so simply reapplying an unchanged existing pod would show its old result.

The pod label `azure.workload.identity/use: "true"` makes the workload
identity webhook inject four environment variables: `AZURE_CLIENT_ID`,
`AZURE_TENANT_ID`, `AZURE_AUTHORITY_HOST`, and `AZURE_FEDERATED_TOKEN_FILE`.
Expect `RESULT: SUCCESS ... (value redacted)` in the logs and those four
variables. `Running` alone does not prove the secret read succeeded. If a new
grant is still propagating, recreate the pod and retry; bundled script 02
automates that retry.

### 5. Diagnose and restore failures

Continue as the same setup/admin user from step 4. The successful secret
read is your starting state; there is no repeated operator-denial test or
healthy-read exercise here. If resuming in a new session, sign in as that
setup user and reconnect with `bash ../scripts/connect.sh` first.

**Brief Portal orientation before changing trust:** the user-assigned managed
identity was created in step 2 (`az identity create`), not by applying the
test pod. In Azure Portal, search for `id-globomantics-orders` (or your chosen
identity name) and open its **Overview**. Under **Settings → Federated
credentials**, locate `fed-orders-api` (or your chosen credential name) and
inspect the subject for your namespace and ServiceAccount. With the course
names, it is `system:serviceaccount:orders:orders-api-sa`.
This is the trust configured in step 3. Do not create or save anything;
return to the terminal to make the deliberate change below.
See the [official Portal instructions](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity).

Capture the IDs used by the plain Azure CLI commands below:

```bash
az account show --query user.name -o tsv
source ../scripts/env.sh
IDENTITY_NAME="${IDENTITY_NAME:-id-globomantics-orders}"
FEDERATED_CREDENTIAL_NAME="${FEDERATED_CREDENTIAL_NAME:-fed-orders-api}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-orders-api-sa}"
IDENTITY_PRINCIPAL_ID="$(az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --query principalId -o tsv)"
ISSUER_URL="$(az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --query oidcIssuerProfile.issuerUrl -o tsv)"
KEY_VAULT_ID="$(az keyvault show --name "$KEY_VAULT_NAME" --query id -o tsv)"
```

If you have not established a working read in this lab, run
`bash ./02-verify-workload-identity.sh` first and resolve any failures.
Otherwise start directly by changing only trust:

```bash
az identity federated-credential delete \
  --resource-group "$RESOURCE_GROUP" --identity-name "$IDENTITY_NAME" \
  --name "$FEDERATED_CREDENTIAL_NAME" --yes
az identity federated-credential create \
  --resource-group "$RESOURCE_GROUP" --identity-name "$IDENTITY_NAME" \
  --name "$FEDERATED_CREDENTIAL_NAME" --issuer "$ISSUER_URL" \
  --subject "system:serviceaccount:${NAMESPACE}:nonexistent-sa" \
  --audiences api://AzureADTokenExchange
sleep 15
```

The short pause gives the changed federated credential time to propagate; it
does not prove it has propagated. Now run a new check explicitly:

```bash
kubectl delete pod orders-api-sa-test --namespace "$NAMESPACE" --ignore-not-found
kubectl apply -f orders-api-sa-test.yaml
kubectl wait --namespace "$NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Running pod/orders-api-sa-test --timeout=180s
kubectl logs orders-api-sa-test --namespace "$NAMESPACE" --follow
```

Delete only the disposable test pod, reapply the same manifest, wait for its
container to run, then follow the output. This is necessary because the test
checks access once per pod start. **Press Ctrl+C after the result and its
detail appear** to stop following logs; the pod remains running.

Expect `RESULT: TOKEN_EXCHANGE_FAILED` and a detail identifying the mismatched
federated identity (the course expects `AADSTS70021`). The pod did not obtain
an Azure token; this is not yet a Key Vault permission failure.
If the result still shows the prior success, stop following, wait 15 seconds
and repeat the four pod commands, not the Azure change.

Restore trust and confirm success **before** removing permission:

```bash
az identity federated-credential delete \
  --resource-group "$RESOURCE_GROUP" --identity-name "$IDENTITY_NAME" \
  --name "$FEDERATED_CREDENTIAL_NAME" --yes
az identity federated-credential create \
  --resource-group "$RESOURCE_GROUP" --identity-name "$IDENTITY_NAME" \
  --name "$FEDERATED_CREDENTIAL_NAME" --issuer "$ISSUER_URL" \
  --subject "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}" \
  --audiences api://AzureADTokenExchange
sleep 15
kubectl delete pod orders-api-sa-test --namespace "$NAMESPACE" --ignore-not-found
kubectl apply -f orders-api-sa-test.yaml
kubectl wait --namespace "$NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Running pod/orders-api-sa-test --timeout=180s
kubectl logs orders-api-sa-test --namespace "$NAMESPACE" --follow
```

Expect `RESULT: SUCCESS ... (value redacted)`. Press Ctrl+C. Do not remove the
role until the restored trust has produced that successful read.

Now change only permission:

```bash
az role assignment delete \
  --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
  --role "Key Vault Secrets User" --scope "$KEY_VAULT_ID"
kubectl delete pod orders-api-sa-test --namespace "$NAMESPACE" --ignore-not-found
kubectl apply -f orders-api-sa-test.yaml
kubectl wait --namespace "$NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Running pod/orders-api-sa-test --timeout=180s
kubectl logs orders-api-sa-test --namespace "$NAMESPACE" --follow
```

Expect `RESULT: KEY_VAULT_DENIED` with HTTP 403 after removal takes effect.
Press Ctrl+C. If the previous success remains, wait 30 seconds and repeat only
the four pod commands. Finally restore permission:

```bash
az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" --scope "$KEY_VAULT_ID"
kubectl delete pod orders-api-sa-test --namespace "$NAMESPACE" --ignore-not-found
kubectl apply -f orders-api-sa-test.yaml
kubectl wait --namespace "$NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Running pod/orders-api-sa-test --timeout=180s
kubectl logs orders-api-sa-test --namespace "$NAMESPACE" --follow
```

Expect `RESULT: SUCCESS ... (value redacted)`, then press Ctrl+C. If the grant
is still propagating, wait 30 seconds and repeat only the four pod commands.
Creation can take up to ten minutes to propagate; no exact deletion delay is
guaranteed. These pauses are retry intervals, not proof that Azure has applied
a change. If the expected result does not appear after repeated checks, stop
and inspect the credential, role/scope and actual error rather than continuing
with an unproven state. A pod pull/startup failure is not a workload-token
failure. Restore the correct trust and role before moving on.

## Bundled alternatives

Use `bash ./00-prepare-demo.sh` instead of the preparation operations in step
1 after signing in, selecting your subscription and exporting your lab names.
It reconnects `kubectl` for that user and prepares only this demo's lab state.
After preparation, use `bash ./01-configure-workload-identity.sh` instead
of manual steps 2–3. It also creates or updates the ServiceAccount, so it
works whether step 1's ServiceAccount already exists or not.
Instead of step 4, run `bash ./02-verify-workload-identity.sh`. Continue as
setup/admin with a known-good read; script
`03-diagnose-and-restore.sh` bundles the diagnostic arc and retry loops from
`lib.sh`. Those helpers are optional automation; the demonstrated manual
commands above do not require sourcing them. Do not run a bundled
script and its manual equivalent as separate exercises.

PowerShell users can use the corresponding `.ps1` files as setup/admin.
If changing accounts for another exercise, use
`kubelogin convert-kubeconfig -l azurecli` after fetching credentials.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `TOKEN_EXCHANGE_FAILED` after configuring trust | Subject, issuer, or audience mismatch; wait a minute, then check `az identity federated-credential list` |
| `KEY_VAULT_DENIED` after granting read access | Role assignment still propagating (wait a few minutes); also check vault network access |
| Pod stuck `ImagePullBackOff` | Inspect the pod's Events for the registry error; see the image-pull checks below |
| Pod missing `AZURE_*` variables | The pod lacks the `azure.workload.identity/use` label or the ServiceAccount has no `client-id` annotation |

### Image-pull checks before investigating identity

```bash
kubectl get pod orders-api-sa-test -n "$NAMESPACE" \
  -o jsonpath='{.spec.containers[0].image}{"\n"}'
kubectl describe pod orders-api-sa-test -n "$NAMESPACE"
```

Read the **Events** section. `failed to fetch anonymous token` with GHCR
`401 Unauthorized` or `403 Forbidden` means the registry is denying anonymous
pull access. It
does not identify whether the package is private or unpublished. A missing
tag may instead report `manifest unknown`; a timeout suggests connectivity.
None of these proves a ServiceAccount, federation, or Key Vault problem:
the test container has not started.

The supplied image must be published and anonymously pullable. Environment
setup builds `orders-api`, not `orders-identity-test`. If this public sample
image is unavailable, its publisher must publish the tag and make the GHCR
package public; otherwise follow [the student build/push instructions](../apps/identity-test/README.md)
to publish a public image you control. Run
`bash ../scripts/check-identity-test-image.sh` (or pass your own image as its
argument) before retrying. For manual `kubectl apply`, update the manifest's `image:`
directly. Exporting `IDENTITY_TEST_IMAGE` only affects the bundled scripts.

The manifest in this checkout is
`repo/module-02-workload-identity/orders-api-sa-test.yaml` from the course
root (or `module-02-workload-identity/orders-api-sa-test.yaml` from the sample
repository root). Confirm the image in the file you actually applied;
there is no `repo/module02` directory in this checkout.

After registry access is fixed, let the kubelet retry the pull. To retry
immediately, explicitly recreate **only this disposable test pod**:

```bash
kubectl delete pod orders-api-sa-test -n "$NAMESPACE" --ignore-not-found
kubectl apply -f orders-api-sa-test.yaml
```

Run those commands from `module-02-workload-identity`, then repeat step 4.
Do not add broad Azure permissions or an image-pull secret to work around
the course image's missing public availability.

## Cleanup

Later modules reuse the identity, role assignment, and ServiceAccount. Remove
only the test pod now, before starting Module 3, matching its clean baseline:

```bash
kubectl delete pod orders-api-sa-test -n "$NAMESPACE" --ignore-not-found
```

`scripts/cleanup.sh` at the repository root removes everything.

## Verification status

2026-10-20 — The public default image was built from the supplied source,
published and checked anonymously. On the course cluster, a freshly created
test pod pulled digest
`sha256:4b0e421cab662154d4333f4e3ce2ec7a3d9f6690d998649a9895c0382d6f71e2`,
logged the redacted `RESULT: SUCCESS` and had all four injected `AZURE_*`
settings. This is **live-end-to-end evidence for the test-pod read**, not a
fresh run of the preparation or full diagnostic scripts. The new preparation
helper and image tools have separate local/mock checks; they do not claim
fresh Azure provisioning or a student-account publication test.

2026-10-18 — **static/syntax** checks only for this module. Identity reads,
exact diagnostic text, propagation times, and restoration have not been
live-verified here; the outputs above are expectations. Sources:
[Workload ID deployment](https://learn.microsoft.com/azure/aks/workload-identity-deploy-cluster),
[Workload ID overview](https://learn.microsoft.com/azure/aks/workload-identity-overview),
and [Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide).

2026-10-20 — CLI preparation walkthrough added; Bash syntax checked without
executing cloud commands. Vault creation, the setup-user Secrets Officer
grant, and file-based secret seeding remain **not live-run by this edit**.
Sources: [Key Vault CLI quickstart](https://learn.microsoft.com/azure/key-vault/secrets/quick-create-cli),
[file-based secret input](https://learn.microsoft.com/azure/key-vault/secrets/multiline-secrets),
and [suppressing CLI output](https://learn.microsoft.com/cli/azure/format-output-azure-cli#none-output-format).
