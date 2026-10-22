// Globomantics lab environment for "Deploy Secure Workloads on AKS".
//
// Creates the starting point every module builds on:
//   - an AKS Standard cluster with Microsoft Entra ID, Azure RBAC for
//     Kubernetes authorization, the OIDC issuer, Workload ID, and Cilium
//     network policy enforcement
//   - an Azure Container Registry
//   - a Key Vault that uses the Azure RBAC permission model, holding the
//     secret the Orders API reads
//
// Local accounts are intentionally left enabled. Module 1 disables them.
// The identity, role assignments, and Kubernetes objects are created by the
// module scripts, not here.

targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('AKS cluster name.')
param clusterName string = 'aks-globomantics-prod'

@description('Container registry name. Must be globally unique: 5-50 lowercase letters and numbers.')
param registryName string = 'acrglobomantics'

@description('Key Vault name. Must be globally unique: 3-24 letters, numbers, and hyphens.')
param keyVaultName string = 'kv-globomantics-orders'

@description('Name of the secret the Orders API reads.')
param secretName string = 'orders-db-connection-string'

@description('Placeholder secret value. A random value is generated and never printed.')
@secure()
param secretValue string = newGuid()

@description('VM size for the system node pool.')
param nodeVmSize string = 'Standard_D4als_v6'

@description('Number of nodes in the system node pool.')
@minValue(2)
@maxValue(5)
param nodeCount int = 2

@description('Kubernetes version. Leave empty to use the AKS default for the region.')
param kubernetesVersion string = ''

@description('Object ID of the setup/admin user. Receives Kubernetes cluster-admin through Azure RBAC.')
param adminPrincipalId string

// Built-in role: Azure Kubernetes Service RBAC Cluster Admin
var aksRbacClusterAdminRoleId = 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b'

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: registryName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    adminUserEnabled: false
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    // Required: the Key Vault Secrets User role assignment in Module 2 only
    // takes effect when the vault uses the Azure RBAC permission model.
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

resource ordersSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: secretName
  properties: {
    value: secretValue
  }
}

resource cluster 'Microsoft.ContainerService/managedClusters@2025-05-01' = {
  name: clusterName
  location: location
  sku: {
    name: 'Base'
    tier: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: clusterName
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    enableRBAC: true
    // Local accounts stay enabled here; Module 1 turns them off.
    disableLocalAccounts: false
    aadProfile: {
      managed: true
      enableAzureRBAC: true
      tenantID: tenant().tenantId
    }
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'
      networkPolicy: 'cilium'
      loadBalancerSku: 'standard'
    }
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
      }
    ]
  }
}

// Lets the setup/admin user run kubectl once Azure RBAC for Kubernetes is on.
resource adminClusterAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: cluster
  name: guid(cluster.id, adminPrincipalId, aksRbacClusterAdminRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aksRbacClusterAdminRoleId)
    principalId: adminPrincipalId
    principalType: 'User'
  }
}

output clusterName string = cluster.name
output registryLoginServer string = registry.properties.loginServer
output keyVaultUri string = keyVault.properties.vaultUri
output oidcIssuerUrl string = cluster.properties.oidcIssuerProfile.issuerURL
