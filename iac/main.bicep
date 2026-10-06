targetScope = 'subscription'

@description('Deployment role. Production supports primary and DR; development always behaves as primary.')
@allowed([
  'primary'
  'dr'
])
param deploymentMode string = 'primary'

@description('Environment tier. Development uses low-cost SKUs and does not deploy Azure Front Door.')
@allowed([
  'prod'
  'dev'
])
param environmentMode string = 'prod'

@description('PostgreSQL Flexible Server administrator password. Not used during a DR geo-restore.')
@secure()
param postgresAdministratorPassword string

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
    tags: tags
  }
  dependsOn: [
    resourceGroupDeployment
  ]
}

@description('Effective deployment mode after development overrides are applied.')
output effectiveDeploymentMode string = effectiveDeploymentMode

@description('Resource group used by the deployment.')
output resourceGroupName string = resourceGroupName

@description('Azure region used by the deployment.')
output location string = location

@description('Azure Front Door endpoint hostname. Empty for development.')
output frontDoorEndpointHostName string = workload.outputs.frontDoorEndpointHostName

@description('Web App default hostname.')
output webAppDefaultHostName string = workload.outputs.webAppDefaultHostName

@description('PostgreSQL Flexible Server fully qualified domain name.')
output postgresFullyQualifiedDomainName string = workload.outputs.postgresFullyQualifiedDomainName
