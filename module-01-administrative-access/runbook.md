# Module 1 runbook — Restricting and verifying administrative access

Follow these Bash commands to configure the access boundary, then test it as
a different person. The numbered scripts bundle the same actions; they are
an alternative, not a prerequisite to the manual steps.

## Prerequisites and start state

Complete the [repository setup](../README.md), using Canada East and two
`Standard_D4als_v6` nodes. Start with local accounts **enabled**, an empty
`orders` namespace, and no `grp-globomantics-orders-operators` group.

Use two different Entra accounts in the same tenant:

- **Setup/admin** creates resources, manages the group and membership, and
  assigns Azure roles. Subscription Owner alone does not grant directory
  administration permissions.
- **Operator** is a lab-only user without unrelated direct, group, inherited,
  or in-cluster grants. Otherwise the access test would prove the wrong grant.

From the repository root:

```bash
cd module-01-administrative-access
export OPERATOR_UPN="<your-lab-operator-sign-in-name>"
unset CONFIRM_ROTATE_CERTS
```

## Configure the boundary — setup/admin

### 1. Identify the accounts and confirm the authorizer

```bash
az account show --query user.name -o tsv
export OPERATOR_OBJECT_ID="$(az ad user show --id "$OPERATOR_UPN" --query id -o tsv)"
echo "$OPERATOR_OBJECT_ID"

az aks show \
  --resource-group rg-globomantics-aks \
  --name aks-globomantics-prod \
  --query aadProfile.enableAzureRbac \
  -o tsv
```

Expect the setup account, the operator's object ID, and `true`. Check the
operator's existing Azure assignments and transitive group memberships before
using it for the proof:

```bash
az role assignment list --assignee "$OPERATOR_OBJECT_ID" --all -o table
az ad user get-member-groups --id "$OPERATOR_OBJECT_ID"
```

Inspect those groups' assignments and any in-cluster bindings too; a direct
assignment list alone is not a complete inherited-access audit.

### 2. Disable local accounts and verify

```bash
az aks update \
  --resource-group rg-globomantics-aks \
  --name aks-globomantics-prod \
  --disable-local-accounts

az aks show \
  --resource-group rg-globomantics-aks \
  --name aks-globomantics-prod \
  --query disableLocalAccounts \
  -o tsv
```

Expect `true` after the update completes. New static admin credentials can no
longer be issued. **Previously issued admin kubeconfigs remain valid.**

### 3. Understand certificate revocation — do not execute in this lab flow

Certificate rotation revokes previously issued credentials. The course shows
this command but does not execute it:

```text
az aks rotate-certs --resource-group rg-globomantics-aks --name aks-globomantics-prod
```

Rotation recreates nodes/disks and can cause up to 30 minutes of downtime.
Only use it separately on a cluster you can disrupt, with an appropriate
maintenance plan. The bundled script also skips it unless you explicitly set
`CONFIRM_ROTATE_CERTS=YES` (PowerShell: `-ConfirmRotateCerts`).

### 4. Create the group and add only the operator

```bash
az ad group create \
  --display-name grp-globomantics-orders-operators \
  --mail-nickname grp-globomantics-orders-operators

OPERATOR_GROUP_ID="$(az ad group show \
  --group grp-globomantics-orders-operators \
  --query id -o tsv)"
echo "$OPERATOR_GROUP_ID"

az ad group member add \
  --group "$OPERATOR_GROUP_ID" \
  --member-id "$OPERATOR_OBJECT_ID"
az ad group member check \
  --group "$OPERATOR_GROUP_ID" \
  --member-id "$OPERATOR_OBJECT_ID" \
  --query value -o tsv
```

Expect group output, a group object ID, and membership `true`.

### 5. Grant kubeconfig retrieval and namespace-scoped Writer

```bash
AKS_ID="$(az aks show \
  --resource-group rg-globomantics-aks \
  --name aks-globomantics-prod \
  --query id -o tsv)"

az role assignment create \
  --assignee-object-id "$OPERATOR_GROUP_ID" \
  --assignee-principal-type Group \
  --role "Azure Kubernetes Service Cluster User Role" \
  --scope "$AKS_ID"

az role assignment create \
  --assignee-object-id "$OPERATOR_GROUP_ID" \
  --assignee-principal-type Group \
  --role "Azure Kubernetes Service RBAC Writer" \
  --scope "$AKS_ID/namespaces/orders"

az role assignment list --assignee "$OPERATOR_GROUP_ID" --scope "$AKS_ID" -o table
az role assignment list --assignee "$OPERATOR_GROUP_ID" --scope "$AKS_ID/namespaces/orders" -o table
```

Expect Cluster User Role at cluster scope and RBAC Writer at the `orders`
namespace scope. The first permits kubeconfig retrieval, not Kubernetes API
actions. Writer includes powerful actions such as access to Secrets; use only
trusted deployers. Allow up to five minutes for new role assignments to apply.

## Verify allowed and denied access

### 6. Test static credential retrieval — still setup/admin

```bash
az account show --query user.name -o tsv
az aks get-credentials \
  --resource-group rg-globomantics-aks \
  --name aks-globomantics-prod \
  --admin
```

This command is **expected to fail**, with:

```text
Getting static credential isn't allowed because this cluster is set to disable local accounts.
```

Do not hide an unrelated authentication/network failure as a successful denial.

### 7. Switch to the operator and replace the kubeconfig

```bash
az logout
az login
az account show --query user.name -o tsv

az aks get-credentials \
  --resource-group rg-globomantics-aks \
  --name aks-globomantics-prod \
  --overwrite-existing
kubelogin convert-kubeconfig -l azurecli
```

Choose the operator account during login and confirm its name. `azurecli`
mode makes `kubectl` reuse that account, rather than an old admin login.

### 8. Check the boundary

Run each command interactively; the intended denials return nonzero exit codes:

```bash
kubectl get pods --namespace orders
kubectl get pods --namespace kube-system
kubectl auth can-i create deployments --namespace orders
kubectl auth can-i create deployments --namespace kube-system
```

Expect an empty `orders` result without an error; `Forbidden` for `kube-system`;
then `yes` and `no`. These prove these specific requests, not every action in
every namespace, and not revocation of previously issued static credentials.

### 9. Return to setup/admin before Module 2

```bash
az logout
az login
az account show --query user.name -o tsv
bash ../scripts/connect.sh
```

## Bundled alternatives

Instead of configuration steps 1–5, export `OPERATOR_OBJECT_ID` and run
`bash ./01-configure-boundary.sh`. Keep certificate rotation unset. Script
`02-verify-local-admin-denied.sh` automates step 6; after signing in as the
operator, `03-verify-operator-access.sh` automates steps 7–8.

PowerShell users can run the corresponding `.ps1` files in the same order.
Set `$env:OPERATOR_OBJECT_ID` first, leave `CONFIRM_ROTATE_CERTS` unset, switch
accounts explicitly, and do not pass `-ConfirmRotateCerts`.

## Troubleshooting and cleanup

| Symptom | Check |
| --- | --- |
| Operator is Forbidden in `orders` | Group membership, role scopes, then propagation |
| Operator can access `kube-system` | Extra inherited/direct grants or stale admin kubeconfig |
| `x509` after an intentional rotation | Fetch fresh credentials and convert with `kubelogin` |
| `--admin` succeeds | Local accounts are still enabled |

Later modules reuse the group and grants. Do not undo them between modules.
Use [repository cleanup](../README.md#4-clean-up-after-the-whole-course) after
the whole course.

## Verification status

2026-10-18 — **static/syntax** checks only for this module; expected outputs
above are not observed live results. Live account switches, propagation,
allowed/denied requests, and cleanup remain pending. Sources:
[local accounts](https://learn.microsoft.com/azure/aks/local-accounts),
[certificate rotation](https://learn.microsoft.com/azure/aks/rotate-certificates),
and [Azure RBAC](https://learn.microsoft.com/azure/aks/manage-azure-rbac).
