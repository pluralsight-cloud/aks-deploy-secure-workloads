# Module 4 — Deploying and verifying a protected workload

Follow [runbook.md](runbook.md) from this folder. It is self-contained: exact
prerequisites, manual commands, expected output, retries and cleanup. It:

1. Checks the start state, then applies the Module 3 Deployment
   (`../module-03-secured-application-path/k8s/base/deployment.yaml`) and
   confirms ready replicas and EndpointSlice entries.
2. Creates a `bypass-test` pod in `default` from `k8s/test/bypass-test.yaml`,
   a client inside the cluster but outside the `orders` namespace.
3. Sends a correct-host request through the Gateway (expect 200), a wrong-host
   request (expect 404) and a direct in-cluster request that bypasses the
   Gateway (expect HTTP 000 with a curl failure, consistent with the policy).

The manual commands are the demonstrated path. The optional scripts
(`01-prestage-bypass-test`, `02-deploy-and-confirm-steady-state`,
`03-verify-protected-path`, with `.ps1` equivalents) do the same work as an
alternative; do not run them after the same manual step. Override the
Deployment path with `DEPLOYMENT_MANIFEST` when using a script.

**Status:** syntax-checked only; the live end-to-end run is pending. See the
runbook's verification status.
