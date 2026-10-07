using './main.bicep'

param deploymentMode = 'primary'
param environmentMode = 'prod'
param postgresAdministratorPassword = readEnvironmentVariable('AZURE_POSTGRES_ADMIN_PASSWORD')
param customDomainName = 'novabank.dedroog.net'
param trafficManagerRelativeDnsName = 'novabank-dedroog'
param enableCustomDomainBinding = false
param logAnalyticsDataReaders = [
  {
    principalId: '645e648c-4133-4f06-aa85-3e0284dcf037'
    principalType: 'Group'
  }
]
