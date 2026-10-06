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

@description('Tags applied to supported resources.')
param tags object

var isDev = environmentMode == 'dev'
var isDr = !isDev && deploymentMode == 'dr'
var deployFrontDoor = !isDev
var nameSuffix = isDev ? '-dev' : (isDr ? '-dr' : '')
var virtualNetworkName = isDev ? 'dev' : (isDr ? 'prod-dr' : 'prod')
var postgresServerName = 'novabank-pg${nameSuffix}'
var postgresPrivateDnsZoneName = 'novabank${nameSuffix}.postgres.database.azure.com'
var appServicePlanName = 'asp-novabank${nameSuffix}'
var webAppName = 'novabank${nameSuffix}'
var logAnalyticsWorkspaceName = 'novabank${nameSuffix}-laws'
var frontDoorProfileName = 'afd-novabank${nameSuffix}'
var frontDoorEndpointName = 'novabank${nameSuffix}'
var frontDoorOriginGroupName = 'novabank${nameSuffix}-origins'
var webAppHostName = '${webAppName}.azurewebsites.net'
var postgresSkuName = isDev ? 'Standard_B1ms' : 'Standard_D4ads_v5'
var postgresTier = isDev ? 'Burstable' : 'GeneralPurpose'
var appServiceSkuName = isDev ? 'B1' : 'P0v4'

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
    highAvailability: isDev ? 'Disabled' : 'ZoneRedundant'
    highAvailabilityZone: isDev ? -1 : 2
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
      mode: 'ZoneRedundant'
      standbyAvailabilityZone: '2'
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
    skuCapacity: isDev ? 1 : 3
    kind: 'linux'
    reserved: true
    zoneRedundant: !isDev
    diagnosticSettings: [
      {
        name: 'send-all-supported'
        workspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
      }
    ]
    tags: tags
  }
}

module frontDoor 'br/public:avm/res/cdn/profile:0.20.0' = if (deployFrontDoor) {
  name: 'novabank-front-door'
  params: {
    name: frontDoorProfileName
    location: 'global'
    sku: 'Standard_AzureFrontDoor'
    originGroups: [
      {
        name: frontDoorOriginGroupName
        healthProbeSettings: {
          probeIntervalInSeconds: 100
          probePath: '/'
          probeProtocol: 'Https'
          probeRequestType: 'HEAD'
        }
        loadBalancingSettings: {
          additionalLatencyInMilliseconds: 50
          sampleSize: 4
          successfulSamplesRequired: 3
        }
        sessionAffinityState: 'Disabled'
        origins: [
          {
            name: 'novabank-webapp'
            hostName: webAppHostName
            originHostHeader: webAppHostName
            enabledState: 'Enabled'
            enforceCertificateNameCheck: true
            httpPort: 80
            httpsPort: 443
            priority: 1
            weight: 1000
          }
        ]
      }
    ]
    afdEndpoints: [
      {
        name: frontDoorEndpointName
        enabledState: 'Enabled'
        autoGeneratedDomainNameLabelScope: 'ResourceGroupReuse'
        routes: [
          {
            name: 'default'
            enabledState: 'Enabled'
            forwardingProtocol: 'HttpsOnly'
            httpsRedirect: 'Enabled'
            linkToDefaultDomain: 'Enabled'
            originGroupName: frontDoorOriginGroupName
            patternsToMatch: [
              '/*'
            ]
            supportedProtocols: [
              'Http'
              'Https'
            ]
          }
        ]
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

resource deployedFrontDoorProfile 'Microsoft.Cdn/profiles@2025-06-01' existing = if (deployFrontDoor) {
  name: frontDoorProfileName
}

module webApp 'br/public:avm/res/web/site:0.24.0' = {
  name: 'novabank-web-app'
  params: {
    name: webAppName
    location: location
    kind: 'app,linux,container'
    serverFarmResourceId: appServicePlan.outputs.resourceId
    httpsOnly: true
    clientAffinityEnabled: false
    clientAffinityProxyEnabled: false
    managedIdentities: {
      systemAssigned: true
    }
    virtualNetworkSubnetResourceId: virtualNetwork.outputs.subnetResourceIds[2]
    siteConfig: {
      alwaysOn: true
      ftpsState: 'Disabled'
      linuxFxVersion: 'DOCKER|erjosito/yadaapi:1.0'
      minTlsVersion: '1.2'
      http20Enabled: true
      vnetRouteAllEnabled: true
      ipSecurityRestrictions: deployFrontDoor
        ? [
            {
              action: 'Allow'
              description: 'Allow only this Azure Front Door profile.'
              headers: {
                'x-azure-fdid': [
                  deployedFrontDoorProfile.?properties.?frontDoorId ?? ''
                ]
              }
              ipAddress: 'AzureFrontDoor.Backend'
              name: 'Allow-Azure-Front-Door'
              priority: 100
              tag: 'ServiceTag'
            }
          ]
        : []
      ipSecurityRestrictionsDefaultAction: deployFrontDoor ? 'Deny' : 'Allow'
      scmIpSecurityRestrictionsUseMain: deployFrontDoor
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
  dependsOn: [
    frontDoor
  ]
}

@description('Azure Front Door endpoint hostname. Empty for development.')
output frontDoorEndpointHostName string = frontDoor.?outputs.?frontDoorEndpointHostNames[0] ?? ''

@description('Web App default hostname.')
output webAppDefaultHostName string = webApp.outputs.defaultHostname

@description('PostgreSQL Flexible Server fully qualified domain name.')
output postgresFullyQualifiedDomainName string = isDr
  ? (postgresDr.?properties.?fullyQualifiedDomainName ?? '')
  : (postgres.?outputs.?fqdn ?? '')
