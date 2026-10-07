targetScope = 'subscription'

@description('Deployment role. Production supports primary and DR; development always behaves as primary.')
@allowed([
  'primary'
  'dr'
])
param deploymentMode string = 'primary'

@description('Environment tier. Development uses low-cost SKUs.')
@allowed([
  'prod'
  'dev'
])
param environmentMode string = 'prod'

@description('PostgreSQL Flexible Server administrator password. Not used during a DR geo-restore.')
@secure()
param postgresAdministratorPassword string

@description('Custom hostname shared by the production primary and DR Web Apps.')
param customDomainName string = 'novabank.dedroog.net'

@description('Globally unique relative DNS name for the production Traffic Manager profile.')
param trafficManagerRelativeDnsName string = 'novabank-dedroog'

@description('Bind the production custom hostname after its DNS ownership records have been configured.')
param enableCustomDomainBinding bool = false

type logAnalyticsDataReaderType = {
  @description('Microsoft Entra object ID of the authorized principal.')
  principalId: string

  @description('Type of Microsoft Entra principal.')
  principalType: 'User' | 'Group' | 'ServicePrincipal'
}

@description('Principals granted the Log Analytics Data Reader role on the deployed workspace.')
param logAnalyticsDataReaders logAnalyticsDataReaderType[] = []

var effectiveDeploymentMode = environmentMode == 'dev' ? 'primary' : deploymentMode
var location = effectiveDeploymentMode == 'dr' ? 'northeurope' : 'westeurope'
var resourceGroupName = environmentMode == 'dev'
  ? 'novabank-dev'
  : (effectiveDeploymentMode == 'dr' ? 'novabank-prod-dr' : 'novabank-prod')
var primaryPostgresResourceId = resourceId(
  subscription().subscriptionId,
  'novabank-prod',
  'Microsoft.DBforPostgreSQL/flexibleServers',
  'novabank-pg'
)
var tags = {
  environment: environmentMode
  deploymentMode: effectiveDeploymentMode
  workload: 'novabank'
}

module resourceGroupDeployment 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'novabank-${environmentMode}-${effectiveDeploymentMode}-resource-group'
  params: {
    name: resourceGroupName
    location: location
    tags: tags
  }
}

module workload './modules/workload.bicep' = {
  name: 'novabank-${environmentMode}-${effectiveDeploymentMode}-workload'
  scope: resourceGroup(resourceGroupName)
  params: {
    location: location
    deploymentMode: effectiveDeploymentMode
    environmentMode: environmentMode
    primaryPostgresResourceId: primaryPostgresResourceId
    postgresAdministratorPassword: postgresAdministratorPassword
    customDomainName: customDomainName
    enableCustomDomainBinding: enableCustomDomainBinding
    logAnalyticsDataReaders: logAnalyticsDataReaders
    tags: tags
  }
  dependsOn: [
    resourceGroupDeployment
  ]
}

module trafficManager 'br/public:avm/res/network/trafficmanagerprofile:0.4.0' = if (environmentMode == 'prod') {
  name: 'novabank-traffic-manager'
  scope: resourceGroup('novabank-prod')
  params: {
    name: 'tm-novabank'
    relativeName: trafficManagerRelativeDnsName
    trafficRoutingMethod: 'Priority'
    ttl: 30
    monitorConfig: {
      intervalInSeconds: 30
      path: '/api/healthcheck'
      port: 80
      protocol: 'HTTP'
      timeoutInSeconds: 10
      toleratedNumberOfFailures: 3
    }
    endpoints: [
      {
        name: 'novabank-primary'
        type: 'Microsoft.Network/trafficManagerProfiles/externalEndpoints'
        properties: {
          endpointLocation: 'West Europe'
          endpointStatus: 'Enabled'
          priority: 1
          target: 'novabank.azurewebsites.net'
        }
      }
      {
        name: 'novabank-dr'
        type: 'Microsoft.Network/trafficManagerProfiles/externalEndpoints'
        properties: {
          endpointLocation: 'North Europe'
          endpointStatus: 'Enabled'
          priority: 2
          target: 'novabank-dr.azurewebsites.net'
        }
      }
    ]
    diagnosticSettings: [
      {
        name: 'send-all-supported'
        workspaceResourceId: resourceId(
          subscription().subscriptionId,
          'novabank-prod',
          'Microsoft.OperationalInsights/workspaces',
          'novabank-laws'
        )
      }
    ]
    tags: {
      environment: 'prod'
      workload: 'novabank'
      role: 'global-routing'
    }
  }
  dependsOn: [
    resourceGroupDeployment
    workload
  ]
}

@description('Effective deployment mode after development overrides are applied.')
output effectiveDeploymentMode string = effectiveDeploymentMode

@description('Resource group used by the deployment.')
output resourceGroupName string = resourceGroupName

@description('Azure region used by the deployment.')
output location string = location

@description('Web App default hostname.')
output webAppDefaultHostName string = workload.outputs.webAppDefaultHostName

@description('PostgreSQL Flexible Server fully qualified domain name.')
output postgresFullyQualifiedDomainName string = workload.outputs.postgresFullyQualifiedDomainName

@description('Production Traffic Manager hostname. Empty for development.')
output trafficManagerHostName string = environmentMode == 'prod'
  ? '${trafficManagerRelativeDnsName}.trafficmanager.net'
  : ''

@description('Custom application hostname. Empty for development.')
output customApplicationHostName string = environmentMode == 'prod' ? customDomainName : ''

@description('Value required in the asuid TXT record before binding the custom hostname.')
output customDomainVerificationId string = workload.outputs.customDomainVerificationId
