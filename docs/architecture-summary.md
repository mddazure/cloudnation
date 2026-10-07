# Novabank

Novabank intends to move their IT estate from an onpremise data center to public cloud. As a first step, to evaluate both the public cloud as a hosting platform and Cloudnation as a cloud partner, they have asked Cloudnation to migrate a web API. 

This repository contains the architecture, design and proof-of-concept deployment of this API application.

## Current situation - Discover
The application curently consists of a web API application on a single VM and a PostgreSQL database, in Novabank's onpremise data center. 

Novabank operates under financial services industry regulations, and one of the constraints imposed is that data must reside within the EU. This constraint is implicitly met today through the physical location of the data center.

There is an  expectation with regards to availability of the API, but the current implementation has not been designed for or evaluated against an explicit availability target.

There is no separate implementation for development and testing, this takes place on the same environment that production runs on. 

Application and database logs are available, but are kept locally on the  VMs only.

## Requirements discovery - Discover
For the migration to public cloud, requirements are stated explicitly:
- *Data residency within the EU* - Whereas this requirement is met implicitly today, in public cloud this requires explicit selection of cloud regions, and cloud services that guarantee data is not moved elsewehere.
- *Availability* - A target of 99.90% is set explicitly.
- *Disaster recovery* - Currently there is no mitigation against failure of the entire onpremise data center. With the migration to public cloud, Novabank wants to explicitly consider measures to recover from a data center failure. They state a Recovery Point Objective (RPO) target of 1 hour and a Recovery Time Objective (RTO) of 4 hours.
- *Auditability* - Application and infrastructure logs are to be kept  centrally (away from the VMs that run the application and database), retained for more than 12 months and access to the logs must be restricted.

## Target architecture - Define & Design
### Cloud platform
The public cloud platform for this proof of concept will be Azure, driven by skills available in the project team. Deployment to Azure meets the stated requirements, as is demonstrated here, but other clouds may be equally suitable and can be evaluated at a later stage.
### Service selection
The architecture follows Microsoft's Cloud Adoption Framework (CAF) principles by preferring managed platform services over infrastructure services, if  they satisfy the functional and non-functional requirements.

The API application is implemented as a container running on a Web App, and the database runs on PostgreSQL Flexible Server. 

 Azure App Service and Azure Database for PostgreSQL Flexible Server reduce operational overhead, improve security posture, and provide built-in high availability features compared to self-managed virtual machine deployments. This aligns with CAF modernization guidance and Azure's recommendation to use managed platform services to allow teams to focus on application delivery rather than infrastructure management.
### Solution design
The Primary Azure region this deployment is West Europe, with Disaster Recovery in North Europe.

#### Primary
The Web App and the database connect privately through a VNET. The PostgreSQL Flexible Server is VNET injected, meaning that it has no public (internet facing) endpoint and can only be reached from within the VNET.  

The Web App uses VNET integration for outbound connectivity through the VNET to the database.

Both the Web App and the PostgreSQL Flexible Server are deployed in zonal redundant mode, giving each an availability target of 99.99% per Microsoft's [Service Level Agreement for 
Microsoft Online Services](https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services?lang=1+). 

The expected availability of the entire API service, consisting of the Web App and the PostgreSQL database, is 0.9999 *0.9999 = 0.9998 or 99.98%, exceeding the target of 99.90%. A High Availability configuration, consisting of multiple load balanced paths in the same region, is not required to meet the availability target.

![image](/docs/novabank-primary.png)

#### Disaster recovery
PostgreSQL Flexible Server is configured for Geo-Redundant backup redundancy. This means that the database is stored in Geo Redundant Storage (GRS). The database is copied to North Europe which is the paired region to West Europe - the copy is asynchronous with a typical lag of minutes, so well within the RPO requirement of 1 hour.

The DR environment is only deployed through code when the primary has failed, there are no are no permanently deployed components. Deployment takes approximately 10 minutes, well within the RTO requirement of 4 hours.

Traffic Manager is used to steer user traffic to the active instance of the application. TM polls the fqdn's of both the primary and dr instances and directs users to the live (primary- or dr-) instance automatically. This avoids the need for DNS manipulation in a disaster situation.

![image](/docs/novabank-dr.png)

#### Development
A separate deployment for a Development environment is available - this uses lower grade and cheaper service SKU's and does not include Traffic Manager. 

The Development environment is completely separate from production.

#### Logging
Resource Logs are written to Log Analytics Workspaces (one per environment - primary, dr, dev). This is set in Diagnostic Settings for each resoource.

Activity Logs (Azure platform logs) are kept by the platform for 90 days by default. For longer retention and querying with KQP, these are exported to a Log Analytics Workspace through Diagnostic setting at the Subscription level.

Log Analytics Wokspaces are configured to only permit access to the logs by members of a specific Entra ID Security Group which has the `logAnalyticsDataReaders` RBAC role assigned. 

#### Security considerations
Lack of a public endpoint helps secure the database, but should not be relied on as the only security measure. Access from the web application to the database should be authenticated through Entra authentication, although this is currently not part of the proof of concept implementation.

#### Requirements matrix

| Requirement | Met through | Comments |
|-------------|-----------------|----------|
| Data residency in EU | Deploy to region pair West Europe (primary) and North Europe (dr) | PostgreSQL Geo Redundant backup retains data in paired regions|
| Availability: 99.90% | Target architecture: 99.98% |HA configuration not required|
| Disaster Recovery RPO < 1 hr, RTO <4 hrs | Target architecture achieves RTO and RPO of minutes | Use of TM avoids DNS complexities in a disaster situation|
| Auditability | All logs written to Log Analytics Workspaces with retention of 2 years and access to logs restricted through Entra Group | Restricted to members of an Entra Security Group with the `logAnalyticsDataReaders` RBAC role 

## Proof of concept - Develop, Deploy
The entire solution is deployable as code, through bicep templates contained in the [iac](/iac/) folder. The code leverages Azure Verified Modules where possible. A separate [README.md](/iac/README.md) document describes the implementation.

The web API application for this proof of concept is the API component of the [YADA demo application](/https://github.com/microsoft/YADA/tree/main). The API application is containerized and installed during deployment of the Web App. The deployment also sets the Web Apps environment variables.

Traffic Manager is deployed with a custom domain name set to the `customDomainName` parameter in the bicep parameters file. This custom domain is also set on the primary and dr Web Apps. Instructions on how to verify the custom domain name are included in README.md.

To avoid complexities with certificates for the custom domain, the primary and dr Web Apps are set to permit non-TLS (http://) connections for this proof of concept. A production deployment should be configured to permit only secured connections, requiring a certificate for the custom domain to be installed on the Web Apps.

The dev deployment ommits Traffic Manager and is reachable on the Web Apps direct fqdn.

NB: The current implementation deploys the Web App and PostgreSQL server in non-zonal (same-zone) redundant mode, because of quota restrictions on the current subscription.

## Demonstration
The endpoints offered by the API are documented [here](https://github.com/microsoft/YADA/tree/main/api).

The API application can query the PostgreSQL server for version information and the ip address of the calling client.

Version query:

`http://novabank.dedroog.net/api/sqlsrcip`

```
{
  "sql_output": "10.0.2.254"
}
```

IP address query
`http://novabank.dedroog.net/api/sqlversion`
```
{
  "sql_output": "PostgreSQL 16.15 on x86_64-pc-linux-gnu, compiled by gcc (GCC) 13.2.0, 64-bit"
}
```

The API can also create a new table in the database, to log the client ip addresses and time stamps of client calls:

`http://novabank.dedroog.net//api/sqlsrcipinit`

```
{
  "table_created": "srciplog"
}
```
`https://novabank.dedroog.net//api/sqlsrciplog`
```
{
  "srciplog": {
    "ip": "10.0.2.254",
    "timestamp": "2026-10-07 11:24:09.491750"
  }
}
```
This demonstrates that the API can reach the database server and can read and write from / to the database.

