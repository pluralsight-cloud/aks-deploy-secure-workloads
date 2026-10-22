# Module 1 — Restricting and verifying administrative access

These scripts build and prove a two-layer access boundary on the
`aks-globomantics-prod` cluster:

1. `01-configure-boundary.sh` disables local accounts, optionally rotates the
   cluster certificates, creates an operator group, and grants it only the
   Cluster User Role plus namespace-scoped RBAC Writer on `orders`.
2. `02-verify-local-admin-denied.sh` proves `az aks get-credentials --admin`
   no longer works.
3. `03-verify-operator-access.sh` checks allowed requests in `orders` and
   denied requests in `kube-system`, not every action everywhere.

Follow [runbook.md](runbook.md) for the demonstrated commands, prerequisites,
expected output, and identity switches. The scripts (and their `.ps1`
equivalents) are optional bundled alternatives. Certificate rotation is
show-only in the course and skipped by default; do not opt in while following
the normal lab sequence.
