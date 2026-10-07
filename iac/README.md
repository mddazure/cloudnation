# NovaBank infrastructure

This scaffold uses pinned [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/) where they support the required resource properties. It supports production primary, production disaster recovery, and development deployments.

The production primary and development PostgreSQL servers use the PostgreSQL AVM. The DR server uses the native `Microsoft.DBforPostgreSQL/flexibleServers` resource because AVM `0.16.1` currently omits the required `sourceServerResourceId` and `pointInTimeUTC` properties when `createMode` is `GeoRestore`. Log Analytics uses a native resource because the workspace AVM doesn't expose the required `DataActionsOnly` authorization mode.

| `environmentMode` | `deploymentMode` | Region | Resource group | PostgreSQL | App Service | Traffic Manager |
|---|---|---|---|---|---|---|
| `prod` | `primary` | West Europe | `novabank-prod` | `Standard_D4ads_v5`, same-zone HA, geo backup | `P0v3`, one instance, non-zone-redundant | Priority 1 |
| `prod` | `dr` | North Europe | `novabank-prod-dr` | Geo-restore from `novabank-prod/novabank-pg`, same-zone HA | `P0v3`, one instance, non-zone-redundant | Priority 2 |
| `dev` | Any value | West Europe | `novabank-dev` | `Standard_B1ms`, no HA or geo backup | `B1`, one instance | Not deployed |

Production uses the shared HTTP hostname `novabank.dedroog.net`, routed through `novabank-dedroog.trafficmanager.net`. Traffic Manager uses priority routing and probes `/api/healthcheck` over HTTP. Both production Web Apps have `httpsOnly` disabled and no TLS certificate binding. Development remains HTTPS-only on its default App Service hostname.

The production resilience settings use deployable fallbacks for the current subscription: PostgreSQL keeps geo-redundant backup and DR support with same-zone HA, while the P0v3 App Service plan uses one non-zone-redundant instance in each production region.

## Prerequisites

- Azure CLI with the Bicep CLI available.
- Subscription-scope deployment permission.
- The production primary PostgreSQL server must exist with healthy geo-redundant backups before a DR deployment.
- Globally unique availability of the selected Web App names.
- DNS control for `dedroog.net`.
- Microsoft Entra object IDs for the users, groups, or service principals that can query logs.
- `Microsoft.Authorization/roleAssignments/write` permission when deploying Log Analytics Data Reader assignments.

## Restrict access to logs

Each Log Analytics workspace uses these controls:

- `enableLogAccessUsingOnlyResourcePermissions: false` requires workspace permissions instead of granting access through monitored resources.
- `dataAuthorizationMode: true` enables Data Actions Only and prevents control-plane roles such as Owner, Contributor, Reader, and Log Analytics Reader from querying log data.
- `disableLocalAuth: true` disables shared-key authentication.
- Only principals assigned **Log Analytics Data Reader** can query logs.

Configure authorized principals in `main.prod.bicepparam`:

```bicep
param logAnalyticsDataReaders = [
  {
    principalId: '<entra-user-or-group-object-id>'
    principalType: 'Group'
  }
]
```

Supported principal types are `User`, `Group`, and `ServicePrincipal`. Prefer an Entra security group instead of assigning individual users. The same list is applied to the workspace deployed for each environment.

The role assignment uses the built-in **Log Analytics Data Reader** role:

```text
3b03c2da-16b3-4a49-8834-0f8130efdd3b
```

A subscription Owner doesn't receive data-plane log access automatically under `DataActionsOnly`. However, an Owner can change the workspace configuration or grant themselves a data-reader role. Use separate administrative identities, Microsoft Entra Privileged Identity Management, approval, and auditing if you must control that administrative path.

## Validate the template

```powershell
az bicep build --file .\iac\main.bicep
```

## Deploy production

The production deployment uses two phases. First deploy the Azure resources without the custom hostname binding. Then publish the DNS ownership records and enable the binding.

### 1. Set the PostgreSQL password

Set the PostgreSQL administrator password only in the process environment:

```powershell
$env:AZURE_POSTGRES_ADMIN_PASSWORD = '<secure-password>'
```

### 2. Deploy the primary environment

`main.prod.bicepparam` defaults `enableCustomDomainBinding` to `false`, so this deployment doesn't require the external DNS records.

```powershell
az deployment sub create `
  --name novabank-prod-primary `
  --location westeurope `
  --template-file .\iac\main.bicep `
  --parameters .\iac\main.prod.bicepparam
```

### 3. Deploy the DR environment

```powershell
az deployment sub create `
  --name novabank-prod-dr `
  --location northeurope `
  --template-file .\iac\main.bicep `
  --parameters .\iac\main.prod.bicepparam deploymentMode=dr
```

The Traffic Manager profile is created in `novabank-prod`. Its DR endpoint remains degraded until the North Europe Web App is available.

### 4. Retrieve the domain-verification IDs

Run:

```powershell
$primaryVerificationId = az webapp show `
  --resource-group novabank-prod `
  --name novabank `
  --query customDomainVerificationId `
  --output tsv

$drVerificationId = az webapp show `
  --resource-group novabank-prod-dr `
  --name novabank-dr `
  --query customDomainVerificationId `
  --output tsv

$primaryVerificationId
$drVerificationId
```

### 5. Configure DNS

Create these records in the `dedroog.net` DNS zone:

| Record name | Type | Value |
|---|---|---|
| `novabank` | CNAME | `novabank-dedroog.trafficmanager.net` |
| `asuid.novabank` | TXT | Value of `$primaryVerificationId` |

If `$drVerificationId` differs from `$primaryVerificationId`, add it as a second TXT value to the same `asuid.novabank` record set.

Confirm that public DNS returns the records:

```powershell
Resolve-DnsName novabank.dedroog.net -Type CNAME
Resolve-DnsName asuid.novabank.dedroog.net -Type TXT
```

Wait for DNS propagation before continuing. App Service rejects the hostname binding if it can't resolve the required TXT value.

### 6. Enable the custom hostname binding

Redeploy both environments with the binding enabled:

```powershell
az deployment sub create `
  --name novabank-prod-primary `
  --location westeurope `
  --template-file .\iac\main.bicep `
  --parameters .\iac\main.prod.bicepparam enableCustomDomainBinding=true

az deployment sub create `
  --name novabank-prod-dr `
  --location northeurope `
  --template-file .\iac\main.bicep `
  --parameters .\iac\main.prod.bicepparam deploymentMode=dr enableCustomDomainBinding=true
```

### 7. Test failover

Open:

```text
http://novabank.dedroog.net
```

Traffic Manager routes traffic to the West Europe app while it is healthy. Stop the primary Web App to test failover to North Europe, and allow time for health probes and DNS caches to update.

> **Warning:** This demo uses HTTP without TLS. Application traffic isn't encrypted.

## Deploy development

Set the PostgreSQL password as described earlier, then run:

```powershell
az deployment sub create `
  --name novabank-dev `
  --location westeurope `
  --template-file .\iac\main.bicep `
  --parameters .\iac\main.prod.bicepparam environmentMode=dev
```

`deploymentMode=dr` is ignored when `environmentMode=dev`. The PostgreSQL password is intentionally absent from source control.
