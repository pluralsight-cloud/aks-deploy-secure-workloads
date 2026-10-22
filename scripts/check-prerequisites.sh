#!/usr/bin/env bash
# Checks the tools and sign-in the labs need. Changes nothing.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

for tool in az kubectl kubelogin curl jq; do
  need "$tool"
done

az_version="$(az version --query '"azure-cli"' -o tsv)"
printf 'Azure CLI: %s (2.86.0 or later is required for Gateway API enablement)\n' "$az_version"
lowest="$(printf '%s\n%s\n' "2.86.0" "$az_version" | sort -V | head -n1)"
[[ "$lowest" == "2.86.0" ]] || die "Upgrade Azure CLI: run 'az upgrade'."

printf 'kubectl client: %s\n' "$(kubectl version --client -o yaml | awk '/gitVersion/ {print $2}')"

az account show >/dev/null 2>&1 || die "Not signed in. Run 'az login'."
printf 'Signed in as: %s\n' "$(az account show --query user.name -o tsv)"
printf 'Subscription: %s\n' "$(az account show --query name -o tsv)"

az provider show -n Microsoft.ContainerService --query registrationState -o tsv | grep -qx Registered ||
  printf '%s\n' "Tip: run 'az provider register -n Microsoft.ContainerService'."

printf '%s\n' "Prerequisites look good."
