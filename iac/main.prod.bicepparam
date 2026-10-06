using './main.bicep'

param deploymentMode = 'primary'
param environmentMode = 'prod'
param postgresAdministratorPassword = readEnvironmentVariable('AZURE_POSTGRES_ADMIN_PASSWORD')
