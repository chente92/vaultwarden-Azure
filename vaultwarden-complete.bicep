// Complete Vaultwarden Deployment on Azure
// Deploys: VNET, PostgreSQL, Storage Account with Private Endpoint, Container Apps
// All resources are secured within VNET with no public endpoints

@description('Location for all resources')
param location string = 'swedencentral'

@description('VNET address space')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('PostgreSQL administrator username')
param postgresAdminUser string

@description('PostgreSQL administrator password')
@secure()
param postgresPassword string

@description('Admin token for Vaultwarden admin panel (optional, leave empty to disable)')
@secure()
param adminToken string = ''

@description('Allow signups initially (set to false after creating your account)')
param signupsAllowed bool = false

// ============================================================================
// STEP 1: VIRTUAL NETWORK
// ============================================================================

resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: 'vaultwarden-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'snet-postgres'
        properties: {
          addressPrefix: '10.0.1.0/24'
          delegations: [
            {
              name: 'PostgreSQLFlexibleServerDelegation'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
          serviceEndpoints: []
        }
      }
      {
        name: 'snet-containerapps'
        properties: {
          addressPrefix: '10.0.2.0/23'
          delegations: [
            {
              name: 'ContainerAppEnvironmentDelegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          serviceEndpoints: []
        }
      }
      {
        name: 'snet-storage-pe'
        properties: {
          addressPrefix: '10.0.4.0/28'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// ============================================================================
// STEP 2: POSTGRESQL FLEXIBLE SERVER
// ============================================================================

// Private DNS Zone for PostgreSQL
resource postgresPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.postgres.database.azure.com'
  location: 'global'
}

resource postgresPrivateDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: postgresPrivateDnsZone
  name: 'vnet-link-postgres'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// PostgreSQL Flexible Server
resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-03-01-preview' = {
  name: 'vaultwarden-psql-${uniqueString(resourceGroup().id)}'
  location: location
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: '17'
    administratorLogin: postgresAdminUser
    administratorLoginPassword: postgresPassword
    storage: {
      storageSizeGB: 32
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      delegatedSubnetResourceId: vnet.properties.subnets[0].id
      privateDnsZoneArmResourceId: postgresPrivateDnsZone.id
    }
  }
  dependsOn: [
    postgresPrivateDnsZoneVnetLink
  ]
}

// Create vaultwarden database
resource postgresDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-03-01-preview' = {
  parent: postgresServer
  name: 'vaultwarden'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// Configure firewall to allow VNET only
resource postgresFirewallVnet 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-03-01-preview' = {
  parent: postgresServer
  name: 'AllowVNET'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// ============================================================================
// STEP 3: STORAGE ACCOUNT WITH PRIVATE ENDPOINT
// ============================================================================

// Private DNS Zone for Storage Files
resource storagePrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.file.${environment().suffixes.storage}'
  location: 'global'
}

resource storagePrivateDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: storagePrivateDnsZone
  name: 'vnet-link-storage'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'stvault${uniqueString(resourceGroup().id)}'
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// File Service
resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

// Azure Files Share for Vaultwarden data
resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  parent: fileService
  name: 'vaultwarden-data'
  properties: {
    accessTier: 'TransactionOptimized'
    shareQuota: 100
    enabledProtocols: 'SMB'
  }
}

// Private Endpoint for Storage Account (Files)
resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: 'pe-storage-vaultwarden'
  location: location
  properties: {
    subnet: {
      id: vnet.properties.subnets[2].id
    }
    privateLinkServiceConnections: [
      {
        name: 'storage-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'file'
          ]
        }
      }
    ]
  }
}

// Private DNS Zone Group for Private Endpoint
resource storagePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  parent: storagePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config1'
        properties: {
          privateDnsZoneId: storagePrivateDnsZone.id
        }
      }
    ]
  }
  dependsOn: [
    storagePrivateDnsZoneVnetLink
  ]
}

// ============================================================================
// STEP 4: CONTAINER APPS ENVIRONMENT AND VAULTWARDEN
// ============================================================================

// Container Apps Environment
resource containerAppEnvironment 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: 'cae-vaultwarden'
  location: location
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: vnet.properties.subnets[1].id
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

// Storage configuration for Container Apps Environment
resource containerAppStorage 'Microsoft.App/managedEnvironments/storages@2023-05-01' = {
  parent: containerAppEnvironment
  name: 'vaultwarden-data'
  properties: {
    azureFile: {
      accountName: storageAccount.name
      accountKey: storageAccount.listKeys().keys[0].value
      shareName: fileShare.name
      accessMode: 'ReadWrite'
    }
  }
}

// Vaultwarden Container App
resource vaultwardenApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'vaultwarden'
  location: location
  properties: {
    environmentId: containerAppEnvironment.id
    workloadProfileName: 'Consumption'
    configuration: {
      ingress: {
        external: true
        targetPort: 80
        transport: 'http'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      secrets: concat([
        {
          name: 'db-url'
          value: 'postgresql://${postgresAdminUser}:${postgresPassword}@${postgresServer.properties.fullyQualifiedDomainName}:5432/${postgresDatabase.name}?sslmode=require'
        }
      ], !empty(adminToken) ? [
        {
          name: 'admin-token'
          value: adminToken
        }
      ] : [])
    }
    template: {
      containers: [
        {
          name: 'vaultwarden'
          image: 'vaultwarden/server:1.35.2'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: concat([
            {
              name: 'DATABASE_URL'
              secretRef: 'db-url'
            }
          ], !empty(adminToken) ? [
            {
              name: 'ADMIN_TOKEN'
              secretRef: 'admin-token'
            }
          ] : [], [
            {
              name: 'SIGNUPS_ALLOWED'
              value: string(signupsAllowed)
            }
            {
              name: 'DATA_FOLDER'
              value: '/data'
            }
            {
              name: 'DOMAIN'
              value: 'https://${vaultwardenApp.properties.configuration.ingress.fqdn}'
            }
            {
              name: 'WEBSOCKET_ENABLED'
              value: 'true'
            }
            {
              name: 'LOG_LEVEL'
              value: 'info'
            }
          ])
          volumeMounts: [
            {
              volumeName: 'data'
              mountPath: '/data'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
      volumes: [
        {
          name: 'data'
          storageName: containerAppStorage.name
          storageType: 'AzureFile'
        }
      ]
    }
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output vaultwardenUrl string = 'https://${vaultwardenApp.properties.configuration.ingress.fqdn}'
output vaultwardenFqdn string = vaultwardenApp.properties.configuration.ingress.fqdn
output postgresServerName string = postgresServer.name
output postgresServerFqdn string = postgresServer.properties.fullyQualifiedDomainName
output postgresDatabaseName string = postgresDatabase.name
output storageAccountName string = storageAccount.name
output vnetName string = vnet.name
output resourceGroupName string = resourceGroup().name

// Deployment Instructions:
// 1. Create resource group:
//    az group create --name vaultwarden-app --location swedencentral
//
// 2. Deploy this template:
//    az deployment group create --resource-group vaultwarden-app --template-file vaultwarden-complete.bicep --parameters postgresAdminUser='youradmin' postgresPassword='YourSecurePassword123!' signupsAllowed=true
//
// 3. After creating your account, disable signups:
//    az containerapp update --name vaultwarden --resource-group vaultwarden-app --set-env-vars "SIGNUPS_ALLOWED=false"
//
// Estimated monthly cost: ~$22-25
// - Container Apps (Consumption): ~$2/month
// - PostgreSQL B1ms: ~$12/month
// - Storage Account: ~$8/month
// - Networking: ~$2/month
