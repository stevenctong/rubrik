# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will try to add a host to a cluster.

.DESCRIPTION
This script will try to add a host to a cluster.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 8/13/24

For authentication, use a RSC Service Account:
** RSC Settings -> Users -> Service Account -> Create one and assign it an appropriate role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath


.EXAMPLE
./Add-Host -cluster <cluster name> -host <hostname_or_ip>.ps1
Runs script to try to add host to a Rubrik cluster using cluster name.

./Add-Host -clusterid <cluster ID> -host <hostname_or_ip>.ps1
Runs script to try to add host to a Rubrik cluster using cluster ID.
#>

### Variables section - please fill out as needed


param (
  [CmdletBinding()]
  # Cluster name to add host to
  [Parameter(Mandatory=$false)]
  [string]$cluster = '',
  # Cluster ID to add host to
  [Parameter(Mandatory=$false)]
  [string]$clusterID = '',
  # Hostname or IP address to add in Rubrik
  [Parameter(Mandatory=$true)]
  [string]$hostname = ''
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
$endpoint = $rubrikURL + "/api/graphql"
$logoutUrl = $rubrikURL + "/api/session"

$headers = @{
  'Content-Type'  = 'application/json'
  'Accept' = 'application/json'
  'Authorization' = $('Bearer ' + $response.access_token)
}

Write-Host "Successfully connected to: $rubrikURL"
###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# Add Host to Rubrik Cluster
Function Add-Host {
  param (
    [CmdletBinding()]
    # Rubrik Cluster ID
    [Parameter(Mandatory=$true)]
    [string]$clusterID,
    # Hostname or IP address
    [Parameter(Mandatory=$true)]
    [string]$hostname
  )
  $variables = @{
    "clusterUuid" = $clusterID
    "hosts" = @(
      @{
        "hostname" = $hostname
      }
    )
    "isBulkRegisterHostAsyncApiEnabled" = $false
  }
  $query = "mutation (`$clusterUuid: String!, `$hosts: [HostRegisterInput!]!, `$isBulkRegisterHostAsyncApiEnabled: Boolean!) {
    bulkRegisterHost(input: {clusterUuid: `$clusterUuid, hosts: `$hosts}) @`skip(if: `$isBulkRegisterHostAsyncApiEnabled) {
      data {
        hostSummary {
          id
          hostname
        }
        hostDomainId
        hostDomainName
      }
    }
    bulkRegisterHostAsync(input: {clusterUuid: `$clusterUuid, hosts: `$hosts}) @`include(if: `$isBulkRegisterHostAsyncApiEnabled) {
      output {
        items {
          agentId
          hostDomainId
          hostDomainName
          hostSummary {
            hostname
          }
        }
      }
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $addHostStatus = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $addHostStatus
}  ### Function Add-Host


# Get list of Rubrik clusters
Function Get-RubrikClusters {
  $variables = @{
    "sortBy" = "ClusterName"
    "sortOrder" = "ASC"
    "filter" = @{
      "id" = @()
      "name" = @(
        ""
      )
      "type" = @()
      "systemStatus" = @()
      "productType" = @(
        "CDM"
      )
    }
    "first" = 50
  }
  $query = "query AllClusterListTableQuery(`$first: Int, `$after: String, `$filter: ClusterFilterInput, `$sortBy: ClusterSortByEnum, `$sortOrder: SortOrder) {
    allClusterConnection(
      filter: `$filter
      sortBy: `$sortBy
      sortOrder: `$sortOrder
      first: `$first
      after: `$after
    ) {
      edges {
        cursor
        node {
          id
          name
          pauseStatus
          geoLocation {
            address
          }
          status
          systemStatus
          clusterNodeConnection {
            count
            nodes {
              id
              status
              ipAddress
            }
          }
          lastConnectionTime
          state {
            connectedState
            clusterRemovalState
          }
          version
          productType
          type
          metric {
            usedCapacity
            availableCapacity
            totalCapacity
          }
        }
      }
      pageInfo {
        startCursor
        endCursor
        hasNextPage
        hasPreviousPage
      }
      count
    }
  }
"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $clusterList = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $clusterList.data.allClusterConnection.edges.node
}  ### Function RubrikClusters

###### FUNCTIONS - END ######

if ($cluster -eq '' -and $clusterID -eq '') {
  Write-Error "Provide either cluster name (-cluster <name>) or cluster ID (-clusterID <cluster UUID)"
}

if ($clustername -ne '') {
  Write-Host "Looking up cluster: $cluster"
  $clusters = Get-RubrikClusters
  $clusterID = $($clusters | Where { $_.name -eq $cluster }).id
  if ($clusterID -eq '') {
    Write-Error "Cannot find cluster with name: $cluster"
  } else {
    Write-Host "Found cluster: $cluster ($clusterID)"
  }
}

Write-Host "Attempting to add host: $hostname to cluster $clusterID"
$result = Add-Host -clusterID $clusterID -hostname $hostname

if ($result.errors -ne '') {
  Write-Error "Error attempting host add: $($result.errors.message)"
} else {
  Write-Host "Added host successfully: $result"
}

# Log out of RSC session
$closeStatus = $(Invoke-RestMethod -Method DELETE -Uri $logoutUrl -Headers $headers -ContentType "application/json")
