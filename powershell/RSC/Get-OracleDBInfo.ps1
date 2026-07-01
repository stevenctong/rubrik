# https://www.rubrik.com/api
<#
.SYNOPSIS
Gets all Oracle database information from RSC including the associated
Host or RAC, individual hostnames, and SLA assignments.

.DESCRIPTION
This script queries RSC for all Oracle databases and their associated
Oracle Hosts and RACs. For each database, it identifies the parent
Host or RAC, and for RACs, lists each individual node hostname.

The output is a flattened CSV where each row represents a database-to-hostname
mapping. A database on a RAC with 3 nodes will produce 3 rows.

Columns include:
- Database name and unique name
- Parent Host/RAC name and type
- Individual hostname and IP addresses
- SLA domain assigned at both the DB and Host/RAC level
- Cluster name, OS type, connection status, Data Guard info

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 7/1/26
Updated: 7/1/26

The script requires communication to RSC via outbound HTTPS (TCP 443).

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath

.PARAMETER serviceAccountPath
File path to the RSC Service Account JSON file.

.EXAMPLE
./Get-OracleDBInfo.ps1
Runs the script using the default service account path ./rsc-gaia.json

.EXAMPLE
./Get-OracleDBInfo.ps1 -serviceAccountPath ./rsc-service-account.json
Runs the script with a custom service account path

#>

### VARIABLES - BEGIN ###

param (
  [CmdletBinding()]
  # File location of the RSC service account json
  [Parameter(Mandatory=$false)]
  [string]$serviceAccountPath = "./rsc-gaia.json"
)

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# CSV output prefix - filename and timestamp will be auto-appended
$csvOutputPrefix = "./rubrik_oracle_db_info"

# CSV output file
$csvOutput = "$($csvOutputPrefix)-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

### VARIABLES - END ###

if ([string]::IsNullOrEmpty($serviceAccountPath)) {
  Write-Host ""
  Write-Host "Usage: ./Get-OracleDBInfo.ps1 [-serviceAccountPath <path>]" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "  -serviceAccountPath  Path to RSC Service Account JSON (default: ./rsc-gaia.json)" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "Output: CSV file with Oracle DB to hostname mapping" -ForegroundColor Cyan
  Write-Host ""
  return
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
  Write-Error "PowerShell version is: $($PSVersionTable.PSVersion)"
  Write-Error "Please use PowerShell version 7+"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls12, [Net.SecurityProtocolType]::Ssl3
  [Net.ServicePointManager]::SecurityProtocol = "Tls, Tls11, Tls12, Ssl3"
}

###### RUBRIK AUTHENTICATION - BEGIN ######
Write-Information -Message "Info: Attempting to read the Service Account file located at $serviceAccountPath"
try {
  $serviceAccountFile = Get-Content -Path "$serviceAccountPath" -ErrorAction Stop | ConvertFrom-Json
}
catch {
  $errorMessage = $_.Exception | Out-String
  if($errorMessage.Contains('because it does not exist')) {
    throw "The Service Account JSON secret file was not found. Ensure the file is location at $serviceAccountPath."
  }
  throw $_.Exception
}

$payload = @{
  grant_type = "client_credentials";
  client_id = $serviceAccountFile.client_id;
  client_secret = $serviceAccountFile.client_secret
}

Write-Debug -Message "Determing if the Service Account file contains all required variables."
$missingServiceAccount = @()
if ($null -eq $serviceAccountFile.client_id) {
  $missingServiceAccount += "'client_id'"
}

if ($null -eq $serviceAccountFile.client_secret) {
  $missingServiceAccount += "'client_secret'"
}

if ($null -eq $serviceAccountFile.access_token_uri) {
  $missingServiceAccount += "'access_token_uri'"
}

if ($missingServiceAccount.count -gt 0){
  throw "The Service Account JSON secret file is missing the required paramaters: $missingServiceAccount"
}

$headers = @{
  'Content-Type' = 'application/json';
  'Accept' = 'application/json';
}

Write-Verbose -Message "Connecting to the RSC GraphQL API using the Service Account JSON file."
try {
  $response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers -ErrorAction Stop
} catch {
  throw "RSC authentication failed: $($_.Exception.Message)"
}

if ($null -eq $response.access_token) {
  throw "RSC returned a response but no access token was included."
}

$rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")
$global:rubrikConnection = @{
  accessToken = $response.access_token;
  rubrikURL = $rubrikURL
}

# Rubrik GraphQL API URL
$endpoint = $rubrikConnection.rubrikURL + "/api/graphql"

$headers = @{
  'Content-Type'  = 'application/json';
  'Accept' = 'application/json';
  'Authorization' = $('Bearer ' + $rubrikConnection.accessToken);
}

Write-Host "Successfully connected to: $rubrikURL."
###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# Get Oracle Hosts and RACs
Function Get-OracleHostsAndRacs {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$false)]
    [string]$afterCursor = ''
  )
  $variables = @{
    "first" = 1000
    "filter" = @(
      @{
        "field" = "IS_RELIC"
        "texts" = @("false")
      },
      @{
        "field" = "IS_REPLICATED"
        "texts" = @("false")
      }
    )
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
    "isMultitenancyEnabled" = $true
    "descendantConnectionFilter" = @(
      @{
        "field" = "IS_RELIC"
        "texts" = @("false")
      }
    )
  }
  if ($afterCursor -ne '') {
    $variables.after = $afterCursor
  }
  $query = @{
    "query" = 'query OracleHostHierarchyHostListQuery($first: Int!, $after: String, $filter: [Filter!], $sortBy: HierarchySortByField, $sortOrder: SortOrder, $isMultitenancyEnabled: Boolean = false, $descendantConnectionFilter: [Filter!]) {
  oracleTopLevelDescendants(after: $after, first: $first, filter: $filter, sortBy: $sortBy, sortOrder: $sortOrder, typeFilter: [OracleHost, OracleRac]) {
    edges {
      cursor
      node {
        id
        name
        objectType
        effectiveSlaDomain {
          id
          name
          ... on GlobalSlaReply {
            isRetentionLockedSla
          }
          ... on ClusterSlaDomain {
            fid
            cluster {
              id
              name
            }
          }
        }
        cluster {
          id
          name
          version
          status
        }
        ... on OracleHost {
          databaseDescendantConnection: descendantConnection(filter: $descendantConnectionFilter, typeFilter: [OracleDatabase]) {
            count
          }
          connectionStatus {
            connectivity
          }
          host {
            id
            name
            ipAddresses
            osType
            osName
          }
        }
        ... on OracleRac {
          nodes {
            status
            nodeName
            hostFid
            host {
              name
              osName
              osType
              ipAddresses
            }
          }
          nodeOrder {
            nodeName
            order
          }
          databaseDescendantConnection: descendantConnection(typeFilter: [OracleDatabase], filter: $descendantConnectionFilter) {
            count
          }
          connectionStatus {
            connectivity
          }
        }
        allOrgs @include(if: $isMultitenancyEnabled) {
          fullName
        }
      }
    }
    pageInfo {
      startCursor
      endCursor
      hasPreviousPage
      hasNextPage
    }
  }
}'
    "variables" = $variables
  }
  $result = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($query | ConvertTo-JSON -Depth 100) -Headers $headers
  return $result.data.oracleTopLevelDescendants
}

# Get Oracle Databases
Function Get-OracleDatabases {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$false)]
    [string]$afterCursor = ''
  )
  $variables = @{
    "first" = 1000
    "filter" = @(
      @{
        "field" = "IS_RELIC"
        "texts" = @("false")
      },
      @{
        "field" = "IS_REPLICATED"
        "texts" = @("false")
      }
    )
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
    "isMultitenancyEnabled" = $true
  }
  if ($afterCursor -ne '') {
    $variables.after = $afterCursor
  }
  $query = @{
    "query" = 'query OracleDatabasesListQuery($first: Int!, $after: String, $filter: [Filter!], $sortBy: HierarchySortByField, $sortOrder: SortOrder, $isMultitenancyEnabled: Boolean = false) {
  oracleDatabases(after: $after, first: $first, filter: $filter, sortBy: $sortBy, sortOrder: $sortOrder) {
    edges {
      cursor
      node {
        id
        name
        dbUniqueName
        objectType
        dataGuardType
        dataGuardGroup {
          id
          dbUniqueName
        }
        dbRole
        isRelic
        numInstances
        numChannels
        numTablespaces
        logBackupFrequency
        logRetentionHours
        hostLogRetentionHours
        slaAssignment
        osType
        osNames
        effectiveSlaDomain {
          id
          name
          ... on GlobalSlaReply {
            isRetentionLockedSla
          }
          ... on ClusterSlaDomain {
            fid
            cluster {
              id
              name
            }
          }
        }
        logicalPath {
          name
          objectType
        }
        physicalPath {
          name
          objectType
        }
        cluster {
          id
          name
          version
          status
        }
        allOrgs @include(if: $isMultitenancyEnabled) {
          fullName
        }
      }
    }
    pageInfo {
      startCursor
      endCursor
      hasPreviousPage
      hasNextPage
    }
  }
}'
    "variables" = $variables
  }
  $result = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($query | ConvertTo-JSON -Depth 100) -Headers $headers
  return $result.data.oracleDatabases
}

###### FUNCTIONS - END ######

# Get all Oracle Hosts and RACs with pagination
Write-Host "Getting all Oracle Hosts and RACs..."
$oracleHostList = @()
$afterCursor = ''
do {
  $hostResult = Get-OracleHostsAndRacs -afterCursor $afterCursor
  $oracleHostList += $hostResult.edges.node
  $afterCursor = $hostResult.pageInfo.endCursor
} while ($hostResult.pageInfo.hasNextPage)
Write-Host "Found $($oracleHostList.count) Oracle Hosts/RACs."

# Build a lookup table: host/RAC name -> node details
$hostRacLookup = @{}
foreach ($hostRac in $oracleHostList) {
  $hostRacLookup[$hostRac.name] = $hostRac
}

# Get all Oracle Databases with pagination
Write-Host "Getting all Oracle Databases..."
$oracleDBList = @()
$afterCursor = ''
do {
  $dbResult = Get-OracleDatabases -afterCursor $afterCursor
  $oracleDBList += $dbResult.edges.node
  $afterCursor = $dbResult.pageInfo.endCursor
} while ($dbResult.pageInfo.hasNextPage)
Write-Host "Found $($oracleDBList.count) Oracle Databases."

# Build the output list - one row per DB-to-hostname mapping
$outputList = @()

foreach ($db in $oracleDBList) {
  # Get the parent Host or RAC name from physicalPath
  $parentName = ''
  $parentType = ''
  foreach ($pathEntry in $db.physicalPath) {
    if ($pathEntry.objectType -eq 'OracleHost' -or $pathEntry.objectType -eq 'OracleRac') {
      $parentName = $pathEntry.name
      $parentType = $pathEntry.objectType
      break
    }
  }

  # RAC Name is the parent name only when it's a RAC
  $racName = if ($parentType -eq 'OracleRac') { $parentName } else { '' }

  # Rubrik cluster name
  $clusterName = if ($db.cluster.name) { $db.cluster.name } else { '' }

  # Look up the parent host/RAC in the lookup table
  $parentObj = $hostRacLookup[$parentName]

  # Common fields for this DB
  $dbSLA = if ($db.effectiveSlaDomain.name) { $db.effectiveSlaDomain.name } else { 'Unprotected' }
  $dbSLAAssignment = $db.slaAssignment
  $parentSLA = if ($parentObj -and $parentObj.effectiveSlaDomain.name) { $parentObj.effectiveSlaDomain.name } else { '' }
  $connectivity = if ($parentObj -and $parentObj.connectionStatus) { $parentObj.connectionStatus.connectivity } else { '' }
  $organizations = if ($db.allOrgs) { ($db.allOrgs.fullName -join ', ') } else { '' }
  $dbOSType = $db.osType
  $dbOSNames = if ($db.osNames) { ($db.osNames -join ', ') } else { '' }

  if ($parentType -eq 'OracleRac' -and $parentObj -and $parentObj.nodes) {
    # RAC: one row per node
    foreach ($node in $parentObj.nodes) {
      $hostIPs = if ($node.host.ipAddresses) { ($node.host.ipAddresses -join ', ') } else { '' }
      $outputList += [PSCustomObject]@{
        'Database Name' = $db.name
        'DB Unique Name' = $db.dbUniqueName
        'DB SLA Domain' = $dbSLA
        'DB SLA Assignment' = $dbSLAAssignment
        'RAC Name' = $racName
        'Rubrik Cluster' = $clusterName
        'Parent Name' = $parentName
        'Parent Type' = $parentType
        'Parent SLA Domain' = $parentSLA
        'Hostname' = $node.host.name
        'Node Name' = $node.nodeName
        'Node Status' = $node.status
        'IP Addresses' = $hostIPs
        'OS Type' = if ($node.host.osType) { $node.host.osType } else { $dbOSType }
        'OS Name' = if ($node.host.osName) { $node.host.osName } else { $dbOSNames }
        'Connectivity' = $connectivity
        'Data Guard Type' = $db.dataGuardType
        'DB Role' = $db.dbRole
        'Num Instances' = $db.numInstances
        'Num Tablespaces' = $db.numTablespaces
        'Num Channels' = $db.numChannels
        'Log Backup Frequency (sec)' = $db.logBackupFrequency
        'Log Retention (hrs)' = $db.logRetentionHours
        'Host Log Retention (hrs)' = $db.hostLogRetentionHours
        'Organizations' = $organizations
        'DB ID' = $db.id
      }
    }
  } elseif ($parentType -eq 'OracleHost' -and $parentObj) {
    # Single host: one row
    $hostIPs = if ($parentObj.host.ipAddresses) { ($parentObj.host.ipAddresses -join ', ') } else { '' }
    $outputList += [PSCustomObject]@{
      'Database Name' = $db.name
      'DB Unique Name' = $db.dbUniqueName
      'DB SLA Domain' = $dbSLA
      'DB SLA Assignment' = $dbSLAAssignment
      'Parent Name' = $parentName
      'Parent Type' = $parentType
      'Parent SLA Domain' = $parentSLA
      'Hostname' = $parentObj.host.name
      'Node Name' = ''
      'Node Status' = ''
      'IP Addresses' = $hostIPs
      'OS Type' = if ($parentObj.host.osType) { $parentObj.host.osType } else { $dbOSType }
      'OS Name' = if ($parentObj.host.osName) { $parentObj.host.osName } else { $dbOSNames }
      'Connectivity' = $connectivity
      'Data Guard Type' = $db.dataGuardType
      'DB Role' = $db.dbRole
      'Num Instances' = $db.numInstances
      'Num Tablespaces' = $db.numTablespaces
      'Num Channels' = $db.numChannels
      'Log Backup Frequency (sec)' = $db.logBackupFrequency
      'Log Retention (hrs)' = $db.logRetentionHours
      'Host Log Retention (hrs)' = $db.hostLogRetentionHours
      'Rubrik Cluster' = $clusterName
      'Organizations' = $organizations
      'DB ID' = $db.id
    }
  } else {
    # Parent not found in lookup - still output the DB info
    $outputList += [PSCustomObject]@{
      'Database Name' = $db.name
      'DB Unique Name' = $db.dbUniqueName
      'DB SLA Domain' = $dbSLA
      'DB SLA Assignment' = $dbSLAAssignment
      'Parent Name' = $parentName
      'Parent Type' = $parentType
      'Parent SLA Domain' = $parentSLA
      'Hostname' = ''
      'Node Name' = ''
      'Node Status' = ''
      'IP Addresses' = ''
      'OS Type' = $dbOSType
      'OS Name' = $dbOSNames
      'Connectivity' = ''
      'Data Guard Type' = $db.dataGuardType
      'DB Role' = $db.dbRole
      'Num Instances' = $db.numInstances
      'Num Tablespaces' = $db.numTablespaces
      'Num Channels' = $db.numChannels
      'Log Backup Frequency (sec)' = $db.logBackupFrequency
      'Log Retention (hrs)' = $db.logRetentionHours
      'Host Log Retention (hrs)' = $db.hostLogRetentionHours
      'Rubrik Cluster' = $clusterName
      'Organizations' = $organizations
      'DB ID' = $db.id
    }
  }
}

# Export to CSV
if ($outputList.count -gt 0) {
  $outputList | Export-Csv -Path $csvOutput -NoTypeInformation
  Write-Host ""
  Write-Host "Total DB-to-hostname rows: $($outputList.count)" -ForegroundColor Green
  Write-Host "CSV output to: $csvOutput" -ForegroundColor Green
} else {
  Write-Host "No Oracle databases found." -ForegroundColor Yellow
}
