# Module 2 — Granting and diagnosing workload identity

These scripts give the Orders API access to Azure Key Vault without a stored
Azure client credential, then show you how to tell two common failures apart.

Start with [runbook.md](runbook.md). It includes the preparation commands shown
in the video, what each command changes, expected output, retries and cleanup.
No instructor folder, recording VM or access to the author's Azure account is
required. Use your own disposable Azure lab and exported resource names.

## Follow along with the bundled Bash scripts

Complete the repository-root setup and sign in as your setup/admin user first.
From the **sample repository root** (the folder containing this README's parent
`scripts/` and `apps/` directories), run:

```bash
bash scripts/check-identity-test-image.sh
cd module-02-workload-identity
bash 00-prepare-demo.sh
bash 01-configure-workload-identity.sh
bash 02-verify-workload-identity.sh
```

The image check needs curl and jq, not Docker or a GitHub login.
`00-prepare-demo.sh` uses your existing cluster, enables Workload ID/OIDC if
needed, connects to it, and creates the namespace and ServiceAccount. It creates
the dedicated lab vault only if absent, requires Azure RBAC on an existing
vault, grants the setup user secret-management permission and seeds only a
missing sample secret with the fake teaching value. **It changes your lab and
can create a billable vault.** It never overwrites an existing secret. If a
new role has not propagated or the vault is unreachable, it fails explicitly;
resolve that error and rerun before continuing.

The remaining scripts correspond to the main demonstration:

1. `01-configure-workload-identity.sh` creates a user-assigned managed
   identity, a federated credential that trusts one Kubernetes ServiceAccount,
   a vault-scoped `Key Vault Secrets User` role assignment, and the annotated
   ServiceAccount.
2. `02-verify-workload-identity.sh` runs a small test pod
   (`orders-api-sa-test.yaml`) and shows it reading the secret through the
   injected token. The secret value is never printed.
3. `03-diagnose-and-restore.sh` breaks trust, then permission, reads each
   error, and restores both.

Expect `RESULT: SUCCESS ... (value redacted)` from script 02. Continue as the
same setup/admin user for script 03; it starts with the deliberate trust
failure rather than repeating administrative checks or the healthy read.
Do not run the destructive diagnostic against an identity
shared with a real application. Run manual steps **or** their bundled-script
equivalents, not both.

## Reproduce the image preparation

The course image is public; using it requires no GitHub account, Docker build
or registry credentials. To repeat the build and push shown in the video,
[follow the source image instructions](../apps/identity-test/README.md).
They include a runnable publishing script, your own GHCR namespace, sign-in,
Public visibility, anonymous verification and selecting your image in this lab.

`lib.sh` holds helpers shared by scripts 02 and 03. The test pod image is built
from `../apps/identity-test/identity_check.py`: a small Python program that
requests an Azure token, reads the named Key Vault secret, prints a redacted
result, and stays running for inspection. It is not the Orders API or an
AKS-provided image. Its Dockerfile packages that source; its public image
must be published separately from the Orders API image.
Follow [runbook.md](runbook.md) for the demonstrated
commands and account switches; the numbered scripts and `.ps1` equivalents
for 01–03 are optional bundled alternatives. The new preparation helper and
image tools use the course's demonstrated Bash shell. Remove the test pod at
the end, retaining the identity and ServiceAccount for later modules.
