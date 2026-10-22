# Module 3 — Configuring the secured application path

This folder prepares everything the Orders API needs without deploying it.
Follow [runbook.md](runbook.md) from this folder: it is self-contained and gives
the exact prerequisites, values, manual commands, expected output, retries and
scoped undo. In order, it covers:

1. Authorizing the cluster's kubelet identity to pull
   `acrglobomantics.azurecr.io/orders-api:1.0.0` (built from `../apps/orders-api`).
2. Creating the `orders-ingress` namespace, then the Gateway, the internal
   Service and the host-matched HTTPRoute, and reading the route's status.
3. Reading how the Cilium policy engine was configured and applying a policy
   that allows only the `orders-ingress` namespace to reach the Orders API pods
   on TCP 8080.

`k8s/base/` holds the Deployment, Service, Gateway, HTTPRoute and NetworkPolicy
manifests. The Deployment is only read here; the next module applies it.

**Choose one path.** The manual commands in the runbook are the demonstrated
path. The optional numbered scripts (`01-authorize-image-and-prepare`,
`02-configure-gateway-path`, `03-apply-network-boundary`, with `.ps1`
equivalents) perform the same actions as an alternative; do not run both for the
same exercise. No `instructor/` files or recording environment are needed.

**Status:** commands have been syntax-checked, but the manual path has not yet
been executed end to end on a live cluster. See the runbook's verification
status.
