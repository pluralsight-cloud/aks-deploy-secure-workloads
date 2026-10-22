# identity-test image (Module 2)

A tiny Python app that uses Workload Identity to read the `orders-db-connection-string`
secret from Key Vault and logs `RESULT: SUCCESS` with the value **redacted**.

Source: `identity_check.py`, `Dockerfile`, `requirements.txt` (all in this folder).

## Normal follow-along: nothing to do

The course uses a prebuilt public image, already referenced in
`module-02-workload-identity/orders-api-sa-test.yaml`:

```
ghcr.io/mhadaily/orders-identity-test:1.0.1
```

You need **no Docker, no GitHub login and no publishing**. Optionally confirm the image
is anonymously pullable (read-only; needs `curl` and `jq`). From the repo root:

```bash
bash scripts/check-identity-test-image.sh
```

Pass an exact image to check another one: `bash scripts/check-identity-test-image.sh ghcr.io/<owner>/orders-identity-test:1.0.1`.
Precedence: argument, then `IDENTITY_TEST_IMAGE`, then the manifest's `image:`.

If the check (or a pod) fails with 401, 403 or "manifest unknown/404", that is an
**image-pull** problem (private package, wrong name, missing tag). It is not a Workload
Identity failure, so do not change Azure roles or federated credentials for it. Do not
disable TLS verification either.

## Optional: build and publish your own copy

Requirements: Docker with Buildx, network access to Docker Hub (base image), PyPI
(dependencies) and `ghcr.io`, and a GitHub account (or org) where you may write packages.

1. Authenticate separately (the script never logs in). Replace `<owner>` with your
   lowercase GitHub user or org:

   ```bash
   gh auth refresh -h github.com -s write:packages
   gh auth token | docker login ghcr.io --username <owner> --password-stdin
   ```

2. Build and push `linux/amd64` with the same `1.0.1` tag. From the repo root:

   ```bash
   bash apps/identity-test/build-and-push.sh <owner>
   ```

   (From `module-02-workload-identity/`: `bash ../apps/identity-test/build-and-push.sh <owner>`.)
   The owner is required; the script refuses to run without it.

3. Set the package visibility to **Public** yourself in GitHub (Packages >
   `orders-identity-test` > Package settings > Change visibility). Pushing does not make
   it public, and the cluster pulls anonymously.

4. Preflight with the exact image from step 2:

   ```bash
   bash scripts/check-identity-test-image.sh ghcr.io/<owner>/orders-identity-test:1.0.1
   ```

5. Use it. Either:
   - `export IDENTITY_TEST_IMAGE=ghcr.io/<owner>/orders-identity-test:1.0.1` before running
     the bundled `module-02-workload-identity` scripts `02` and `03` (and the shared
     helpers they use). Script `01` does not use the image. The variable only affects
     those scripts; or
   - if you `kubectl apply` the manifest by hand, edit `image:` in
     `module-02-workload-identity/orders-api-sa-test.yaml` first. Exporting the variable
     does not change a manual apply.

Other registries (for example ACR) are out of scope for this module.
