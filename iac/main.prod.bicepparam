using './main.bicep'

param deploymentMode = 'primary'
param environmentMode = 'prod'
param postgresAdministratorPassword = readEnvironmentVariable('AZURE_POSTGRES_ADMIN_PASSWORD')
param customDomainName = 'novabank.dedroog.net'
param trafficManagerRelativeDnsName = 'novabank-dedroog'
param enableCustomDomainBinding = false
