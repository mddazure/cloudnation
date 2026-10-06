# NovaBank infrastructure

This scaffold uses pinned [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/) and supports production primary, production disaster recovery, and development deployments.

The production primary and development PostgreSQL servers use the PostgreSQL AVM. The DR server uses the native `Microsoft.DBforPostgreSQL/flexibleServers` resource because AVM `0.16.1` currently omits the required `sourceServerResourceId` and `pointInTimeUTC` properties when `createMode` is `GeoRestore`.

| `environmentMode` | `deploymentMode` | Region | Resource group | PostgreSQL | App Service | Front Door |
|---|---|---|---|---|---|---|
| `prod` | `primary` | West Europe | `novabank-prod` | `Standard_D4ads_v5`, zone HA, geo backup | `P0v4`, three instances, zone redundant | Standard |
| `prod` | `dr` | North Europe | `novabank-prod-dr` | Geo-restore from `novabank-prod/novabank-pg` | `P0v4`, three instances, zone redundant | Standard |
| `dev` | Any value | West Europe | `novabank-dev` | `Standard_B1ms`, no HA or geo backup | `B1`, one instance | Not deployed |

Production Web Apps allow only the `AzureFrontDoor.Backend` service tag when `X-Azure-FDID` matches the Front Door profile deployed by the same template. Development remains directly accessible over HTTPS.

## Prerequisites

- Azure CLI with the Bicep CLI available.
- Subscription-scope deployment permission.
- The production primary PostgreSQL server must exist with healthy geo-redundant backups before a DR deployment.
- Globally unique availability of the selected Web App and Front Door endpoint names.

## Validate

```powershell
az bicep build --file .\iac\main.bicep
```

## Deploy

Set the PostgreSQL administrator password only in the process environment:

```powershell
$env:AZURE_POSTGRES_ADMIN_PASSWORD = '<secure-password>'
```

Production primary:

```powershell
az deployment sub create `
  --name novabank-prod-primary `
  --location westeurope `
  --template-file .\iac\main.bicep `
  --parameters .\iac\main.prod.bicepparam
```

Production DR:

```powershell
az deployment sub create `
  --name novabank-prod-dr `
  --location northeurope `
  --template-file .\iac\main.bicep `
  --parameters .\iac\main.prod.bicepparam deploymentMode=dr
```

Development:

```powershell
az deployment sub create `
  --name novabank-dev `
  --location westeurope `
  --template-file .\iac\main.bicep `
  --parameters .\iac\main.prod.bicepparam environmentMode=dev
```

`deploymentMode=dr` is ignored when `environmentMode=dev`. The PostgreSQL password is intentionally absent from source control.
