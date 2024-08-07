# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will try to assign a SLA to a SQL object.

.DESCRIPTION
This script will try to assign a SLA to a SQL object.

You can find the SLA ID by navigating to a SLA in RSC and looking at the URL.
Eg: https://customer.my.rubrik.com/sla/details/<sla_id_is_here>

You can pass in a SQL Host and it will discover all the instances under it.
If more than 1 instance is discovered, the script will error out.
Otherwise, if a single SQL instance is discovered, it will assign the SLA ID to it.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 8/5/24

For authentication, use a RSC Service Account:
** RSC Settings -> Users -> Service Account -> Create one and assign it an appropriate role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath


.EXAMPLE
./Assign-SQL-SLQ.ps1 -slaID <SLA ID> -sqlHost <SQL Host>
#>

### Variables section - please fill out as needed


param (
  [CmdletBinding()]
  # SLA ID to assign to SQL object
  [Parameter(Mandatory=$true)]
  [string]$slaID = '',
  # SQL Host to get instances to assign SLA to
  [Parameter(Mandatory=$true)]
  [string]$sqlHost = ''
)

# File location of the RSC service account json
$serviceAccountPath = "./rsc-service-account-rr.json"

$date = Get-Date
$utcDate = $date.ToUniversalTime()

### End Variables section

###### RUBRIK AUTHENTICATION - BEGIN ######
Write-Information -Message "Info: Attempting to read the Service Account file located at $serviceAccountPath"
try {
  $serviceAccountFile = Get-Content -Path "$serviceAccountPath" -ErrorAction Stop | ConvertFrom-Json
} catch {
  $errorMessage = $_.Exception | Out-String
  if($errorMessage.Contains('because it does not exist')) {
    throw "The Service Account JSON secret file was not found. Ensure the file is location at $serviceAccountPath."
  }
  throw $_.Exception
}

Write-Debug -Message "Determing if the Service Account file contains all required variables."
$missingServiceAccount = @()
if ($serviceAccountFile.client_id -eq $null -or $serviceAccountFile.client_secret -eq $null -or
      $serviceAccountFile.access_token_uri -eq $null) {
  throw "The Service Account JSON is missing one or more parameters."
}

$headers = @{
  'Content-Type' = 'application/json'
  'Accept' = 'application/json'
}

$payload = @{
  grant_type = "client_credentials"
  client_id = $serviceAccountFile.client_id
  client_secret = $serviceAccountFile.client_secret
}

Write-Verbose -Message "Connecting to the RSC GraphQL API using the Service Account JSON file."
$response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers

# Rubrik GraphQL API URLs
$rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")
$endpoint = $rubrikConnection.rubrikURL + "/api/graphql"
$logoutUrl = $rubrikConnection.rubrikURL + "/api/session"

$headers = @{
  'Content-Type'  = 'application/json'
  'Accept' = 'application/json'
  'Authorization' = $('Bearer ' + $response.access_token)
}

Write-Host "Successfully connected to: $rubrikURL"
###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# Assign a SLA to a SQL object
Function Assign-SQL-SLA {
  param (
    [CmdletBinding()]
    # SQL Object ID
    [Parameter(Mandatory=$true)]
    [string]$sqlID,
    # SLA ID
    [Parameter(Mandatory=$true)]
    [string]$slaID
  )
  $variables = @{
    "input" = @{
      "updateInfo" = @{
        "ids" = @(
          $sqlID
        )
        "shouldApplyToExistingSnapshots" = $false
        "shouldApplyToNonPolicySnapshots" = $false
        "mssqlSlaPatchProperties" = @{
          "configuredSlaDomainId" = $slaID
          "mssqlSlaRelatedProperties" = @{
            "copyOnly" = $false
            "hasLogConfigFromSla" = $true
            "hostLogRetention" = -1
          }
          "useConfiguredDefaultLogRetention" = $false
        }
      }
      "userNote" = ""
    }
  }
  $query = "mutation (`$input: AssignMssqlSlaDomainPropertiesAsyncInput!) {
    assignMssqlSlaDomainPropertiesAsync(input: `$input) {
      items {
        objectId
        __typename
      }
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $status = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $status
}  ### Function Assign-SQL-SLA


# Get a list of a SQL host and its descendents
Function Get-SQLHost {
  param (
    [CmdletBinding()]
    # Filter by a SQL hostname
    [Parameter(Mandatory=$false)]
    [string]$sqlHost
  )
  $variables = @{
    "first" = 100
    "filter" = @(
      @{
        "field" = "NAME"
        "texts" = @(
          $sqlHost
        )
      },
      @{
        "field" = "IS_RELIC"
        "texts" = @(
          "false"
        )
      },
      @{
        "field" = "IS_REPLICATED"
        "texts" = @(
          "false"
        )
      },
      @{
        "field" = "IS_ARCHIVED"
        "texts" = @(
          "false"
        )
      }
    )
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
  }
  $query = "query (`$first: Int!, `$after: String, `$filter: [Filter!], `$sortBy: HierarchySortByField, `$sortOrder: SortOrder) {
    mssqlTopLevelDescendants(
      after: `$after
      first: `$first
      filter: `$filter
      sortBy: `$sortBy
      sortOrder: `$sortOrder
      typeFilter: [PhysicalHost]
    ) {
      edges {
        cursor
        node {
          name
          id
          objectType
          primaryClusterLocation {
            name
            id
            clusterUuid
          }
   				... on PhysicalHost {
            descendantConnection {
              edges {
                node {
                  name
                  objectType
                  id
                  effectiveSlaDomain {
                    name
                    id
                  }
                }
              }
            }
          }
        }
      }
      pageInfo {
        startCursor
        endCursor
        hasNextPage
        hasPreviousPage
      }
    }
  }
"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $sqlList = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $sqlList.data.mssqlTopLevelDescendants.edges.node
}  ### Function Get-SQLHost

###### FUNCTIONS - END ######

# Get list of SQL hosts with any partial match of $sqlHost
$sqlHostList = Get-SQLHost -sqlHost $sqlHost

# Perform exact match of $sqlHost from that list
$sqlHostInfo = $sqlHostList | Where { $_.name -eq $sqlHost }

if ($sqlHostInfo.count -eq 0) {
  throw "No SQL host found with exact match: $sqlHost"
}

# $sqlHostInfo has all descendent (Instances & DBs) under it
$sqlHostDescendents = $($sqlHostInfo.descendantConnection.edges.node | Sort-Object -Property 'objectType', 'name')

Write-Host "Object descendents on SQL Host: $sqlHost"
$sqlHostDescendents | Format-Table

$sqlInstances = $sqlHostDescendents | Where { $_.objectType -match 'MssqlInstance' }

if ($sqlInstances.count -eq 0) {
  throw "No SQL instances found for: $sqlHost"
} elseif ($sqlInstances.count -ge 2) {
  throw "Multipe SQL instances found for: $sqlHost"
}

Write-Host "Found SQL instance: $($sqlInstances.name) ($($sqlInstances.id))"
Write-Host "Attempting to assign SLA: $slaID to SQL instance"

$slaStatus = Assign-SQL-SLA -sqlID $sqlInstances.id -slaID $slaID

# Log out of RSC session
$closeStatus = $(Invoke-RestMethod -Method DELETE -Uri $logoutUrl -Headers $headers -ContentType "application/json")
