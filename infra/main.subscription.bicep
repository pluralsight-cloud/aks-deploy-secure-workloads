targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

@description('AKS cluster name.')
param clusterName string = 'aks-globomantics-prod'

@description('Container registry name. Must be globally unique: 5-50 lowercase letters and numbers.')
param registryName string = 'acrglobomantics'

@description('Key Vault name. Must be globally unique: 3-24 letters, numbers, and hyphens.')
param keyVaultName string = 'kv-globomantics-orders'

@description('VM size for the system node pool.')
param nodeVmSize string = 'Standard_D4als_v6'

@description('Number of nodes in the system node pool.')
@minValue(2)
@maxValue(5)
param nodeCount int = 2

@description('Object ID of the setup/admin user. Receives Kubernetes cluster-admin through Azure RBAC.')
param adminPrincipalId string = ''

var defaultResourceGroupName = 'rg-globomantics-aks'

resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: !empty(environmentName) && environmentName != 'default' ? 'rg-${environmentName}' : defaultResourceGroupName
  location: location
}

module resources 'main.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location: location
    clusterName: clusterName
    registryName: registryName
    keyVaultName: keyVaultName
    nodeVmSize: nodeVmSize
    nodeCount: nodeCount
    adminPrincipalId: adminPrincipalId
  }
}

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_AKS_CLUSTER_NAME string = resources.outputs.clusterName
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.registryLoginServer
output AZURE_CONTAINER_REGISTRY_NAME string = registryName
output AZURE_KEY_VAULT_ENDPOINT string = resources.outputs.keyVaultUri
output AZURE_KEY_VAULT_NAME string = keyVaultName
output AZURE_OIDC_ISSUER_URL string = resources.outputs.oidcIssuerUrl
