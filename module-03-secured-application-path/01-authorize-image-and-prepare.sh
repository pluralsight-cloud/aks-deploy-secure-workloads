#!/usr/bin/env bash
set -Eeuo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-globomantics-aks}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-globomantics-prod}"
REGISTRY_NAME="${REGISTRY_NAME:-acrglobomantics}"
REPOSITORY="${REPOSITORY:-orders-api}"
IMAGE_TAG="${IMAGE_TAG:-1.0.0}"

command -v az >/dev/null || {
  printf '%s\n' "Azure CLI (az) is required." >&2
  exit 1
}

printf 'Signed-in setup identity: '
az account show --query user.name -o tsv

tag="$(az acr repository show-tags \
  --name "$REGISTRY_NAME" \
  --repository "$REPOSITORY" \
  --query "[?@=='$IMAGE_TAG'] | [0]" \
  -o tsv)"
if [[ "$tag" != "$IMAGE_TAG" ]]; then
  printf 'Expected image tag %s in %s/%s; got: %s\n' \
    "$IMAGE_TAG" "$REGISTRY_NAME" "$REPOSITORY" "${tag:-<none>}" >&2
  exit 1
fi
printf 'Image tag confirmed: %s.azurecr.io/%s:%s\n' \
  "$REGISTRY_NAME" "$REPOSITORY" "$IMAGE_TAG"

role_assignment_mode="$(az acr show \
  --name "$REGISTRY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query roleAssignmentMode \
  -o tsv)"
printf 'Registry permission model: %s\n' "$role_assignment_mode"
normalized_role_assignment_mode="$(printf '%s' "$role_assignment_mode" |
  tr '[:upper:]' '[:lower:]')"

kubelet_object_id="$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query identityProfile.kubeletidentity.objectId \
  -o tsv)"
if [[ -z "$kubelet_object_id" ]]; then
  printf '%s\n' "Could not resolve the AKS kubelet identity object ID." >&2
  exit 1
fi
printf 'Kubelet identity objectId: %s\n' "$kubelet_object_id"

case "$normalized_role_assignment_mode" in
  # Match ABAC first: `rbac-abac` also matches the generic `*rbac*` branch.
  *abac*)
    registry_id="$(az acr show \
      --name "$REGISTRY_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --query id \
      -o tsv)"
    existing_assignment="$(az role assignment list \
      --assignee-object-id "$kubelet_object_id" \
      --scope "$registry_id" \
      --role "Container Registry Repository Reader" \
      --query "[].id | [0]" \
      -o tsv)"
    if [[ -z "$existing_assignment" ]]; then
      az role assignment create \
        --assignee-object-id "$kubelet_object_id" \
        --assignee-principal-type ServicePrincipal \
        --role "Container Registry Repository Reader" \
        --scope "$registry_id"
    else
      printf '%s\n' "Container Registry Repository Reader assignment already exists."
    fi
    ;;
  rbac|*rbac*|legacy*registry*permissions)
    az aks update \
      --resource-group "$RESOURCE_GROUP" \
      --name "$CLUSTER_NAME" \
      --attach-acr "$REGISTRY_NAME"
    ;;
  *)
    printf 'Unsupported registry permission model: %s\n' \
      "$role_assignment_mode" >&2
    exit 1
    ;;
esac

printf '%s\n' "Registry authorization is prepared."
printf '%s\n' "The Deployment manifest is intentionally not applied in Module 3."
