targetScope = 'resourceGroup'

@description('Azure region for all regional resources.')
param location string

@description('Effective deployment role after development overrides are applied.')
@allowed([
  'primary'
  'dr'
])
param deploymentMode string

@description('Environment tier.')
@allowed([
  'prod'
  'dev'
])
param environmentMode string

@description('Resource ID of the primary West Europe PostgreSQL Flexible Server.')
param primaryPostgresResourceId string

@description('Geo-restore point. Defaults to the current deployment time.')
param geoRestorePointInTime string = utcNow()

@description('PostgreSQL Flexible Server administrator password.')
@secure()
param postgresAdministratorPassword string

@description('Custom hostname shared by the production primary and DR Web Apps.')
param customDomainName string

@description('Bind the production custom hostname after its DNS ownership records have been configured.')
param enableCustomDomainBinding bool

@description('Tags applied to supported resources.')
param tags object

var isDev = environmentMode == 'dev'
var isDr = !isDev && deploymentMode == 'dr'
var nameSuffix = isDev ? '-dev' : (isDr ? '-dr' : '')
var virtualNetworkName = isDev ? 'dev' : (isDr ? 'prod-dr' : 'prod')
var postgresServerName = 'novabank-pg${nameSuffix}'
var postgresPrivateDnsZoneName = 'novabank${nameSuffix}.postgres.database.azure.com'
var appServicePlanName = 'asp-novabank${nameSuffix}'
var webAppName = 'novabank${nameSuffix}'
var logAnalyticsWorkspaceName = 'novabank${nameSuffix}-laws'
var postgresSkuName = isDev ? 'Standard_B1ms' : 'Standard_D4ads_v5'
var postgresTier = isDev ? 'Burstable' : 'GeneralPurpose'
var appServiceSkuName = isDev ? 'B1' : 'P0v3'

module logAnalyticsWorkspace 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'novabank-log-analytics'
  params: {
    name: logAnalyticsWorkspaceName
    location: location
    skuName: 'PerGB2018'
    dataRetention: 730
    forceCmkForQuery: false
    diagnosticSettings: [
      {
        name: 'send-all-supported-to-self'
        useThisWorkspace: true
      }
    ]
    tags: tags
  }
}

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'novabank-virtual-network'
  params: {
    name: virtualNetworkName
    location: location
    addressPrefixes: [
      '10.0.0.0/16'
    ]
    subnets: [
      {
        name: 'default'
        addressPrefix: '10.0.0.0/24'
      }
      {
        name: 'postgresql'
        addressPrefix: '10.0.1.0/24'
        delegation: 'Microsoft.DBforPostgreSQL/flexibleServers'
      }
      {
        name: 'appservice'
        addressPrefix: '10.0.2.0/24'
        delegation: 'Microsoft.Web/serverFarms'
      }
    ]
    tags: tags
  }
}

module postgresPrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'novabank-postgres-private-dns'
  params: {
    name: postgresPrivateDnsZoneName
    virtualNetworkLinks: [
      {
        name: 'link-${virtualNetworkName}'
        virtualNetworkResourceId: virtualNetwork.outputs.resourceId
        registrationEnabled: false
      }
    ]
    tags: tags
  }
}

module postgres 'br/public:avm/res/db-for-postgre-sql/flexible-server:0.16.1' = if (!isDr) {
  name: 'novabank-postgres'
  params: {
    name: postgresServerName
    location: location
    administratorLogin: 'AzureAdmin'
    administratorLoginPassword: postgresAdministratorPassword
    authConfig: {
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
    }
    skuName: postgresSkuName
    tier: postgresTier
    availabilityZone: isDev ? -1 : 1
    highAvailability: isDev ? 'Disabled' : 'SameZone'
    highAvailabilityZone: isDev ? -1 : 1
    backupRetentionDays: isDev ? 7 : 35
    geoRedundantBackup: isDev ? 'Disabled' : 'Enabled'
    storageSizeGB: isDev ? 32 : 128
    autoGrow: 'Enabled'
    version: '16'
    createMode: 'Default'
    delegatedSubnetResourceId: virtualNetwork.outputs.subnetResourceIds[1]
    privateDnsZoneArmResourceId: postgresPrivateDnsZone.outputs.resourceId
    publicNetworkAccess: 'Disabled'
    enableAdvancedThreatProtection: !isDev
    diagnosticSettings: [
      {
        name: 'send-all-supported'
        workspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
      }
    ]
    tags: tags
  }
}

resource postgresDr 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = if (isDr) {
  name: postgresServerName
  location: location
  sku: {
    name: postgresSkuName
    tier: postgresTier
  }
  properties: {
    authConfig: {
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
    }
    availabilityZone: '1'
    backup: {
      backupRetentionDays: 35
      geoRedundantBackup: 'Disabled'
    }
    createMode: 'GeoRestore'
    highAvailability: {
      mode: 'SameZone'
      standbyAvailabilityZone: '1'
    }
    network: {
      delegatedSubnetResourceId: virtualNetwork.outputs.subnetResourceIds[1]
      privateDnsZoneArmResourceId: postgresPrivateDnsZone.outputs.resourceId
      publicNetworkAccess: 'Disabled'
    }
    pointInTimeUTC: geoRestorePointInTime
    sourceServerResourceId: primaryPostgresResourceId
    storage: {
      autoGrow: 'Enabled'
      storageSizeGB: 128
    }
    version: '16'
  }
  tags: tags
}

resource postgresDrDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (isDr) {
  name: 'send-all-supported'
  scope: postgresDr
  properties: {
    workspaceId: logAnalyticsWorkspace.outputs.resourceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

module appServicePlan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: 'novabank-app-service-plan'
  params: {
    name: appServicePlanName
    location: location
    skuName: appServiceSkuName
    skuCapacity: 1
    kind: 'linux'
    reserved: true
    zoneRedundant: false
    diagnosticSettings: [
      {
        name: 'send-all-supported'
        workspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
      }
    ]
    tags: tags
  }
}

module webApp 'br/public:avm/res/web/site:0.24.0' = {
  name: 'novabank-web-app'
  params: {
    name: webAppName
    location: location
    kind: 'app,linux,container'
    serverFarmResourceId: appServicePlan.outputs.resourceId
    httpsOnly: isDev
    clientAffinityEnabled: false
    clientAffinityProxyEnabled: false
    managedIdentities: {
      systemAssigned: true
    }
    virtualNetworkSubnetResourceId: virtualNetwork.outputs.subnetResourceIds[2]
    hostNameBindings: isDev || !enableCustomDomainBinding
      ? []
      : [
          {
            name: customDomainName
          }
        ]
    siteConfig: {
      alwaysOn: true
      ftpsState: 'Disabled'
      linuxFxVersion: 'DOCKER|madedroo/yadaapi:1.1'
      minTlsVersion: '1.2'
      http20Enabled: true
      vnetRouteAllEnabled: true
    }
    outboundVnetRouting: {
      allTraffic: true
    }
    publicNetworkAccess: 'Enabled'
    basicPublishingCredentialsPolicies: [
      {
        name: 'ftp'
        allow: false
      }
      {
        name: 'scm'
        allow: false
      }
    ]
    diagnosticSettings: [
      {
        name: 'send-all-supported'
        workspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
      }
    ]
    tags: tags
  }
}

resource deployedWebApp 'Microsoft.Web/sites@2024-11-01' existing = {
  name: webAppName
}

resource webAppSettings 'Microsoft.Web/sites/config@2024-11-01' = {
  name: 'appsettings'
  parent: deployedWebApp
  properties: {
    SQL_ENGINE: 'postgres'
    SQL_SERVER_FQDN: '${postgresServerName}.postgres.database.azure.com'
    SQL_SERVER_PASSWORD: postgresAdministratorPassword
    SQL_SERVER_USERNAME: 'AzureAdmin'
  }
  dependsOn: [
    webApp
  ]
}

@description('Web App default hostname.')
output webAppDefaultHostName string = webApp.outputs.defaultHostname

@description('PostgreSQL Flexible Server fully qualified domain name.')
output postgresFullyQualifiedDomainName string = isDr
  ? (postgresDr.?properties.?fullyQualifiedDomainName ?? '')
  : (postgres.?outputs.?fqdn ?? '')

@description('Value required in the asuid TXT record before binding the custom hostname.')
output customDomainVerificationId string = webApp.outputs.?customDomainVerificationId ?? ''
