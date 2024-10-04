# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will gather stats on Rubrik and output it to a CSV.

.DESCRIPTION
This script will gather stats on Rubrik and output it to a CSV.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 10/1/24

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath


.EXAMPLE
./Get-RubrikStats.ps1
Runs the script to gather Rubrik stats and output to  CSV.
#>

### Variables section - please fill out as needed

# param (
#   [CmdletBinding()]
#
#   # List of clusters to register RBS on
#   [Parameter(Mandatory=$false)]
#   [array]$clusters = @('vault-r-melbourne', 'vault-r-madison')
# )

# List of Cluster IDs to gather snapshot stats for
$clusterID = '2988c49d-4040-4982-a77f-63c3c6c24c14'
$clusterName = 'HDC2-RBRK-PRD'

# File location of the RSC service account json
$serviceAccountPath = "./rsc-service-account-quorum.json"

$date = Get-Date
$dateString = $date.ToString("yyyy-MM-ddTHH:mm:ss")

# CSV file info
$csvOutput = "./rubrik_daily_stats.csv"

# Define the capacity metric conversions
$GB = 1000000000
$GiB = 1073741824
$TB = 1000000000000
$TiB = 1099511627776

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


# Get VM list and snapshots for each VM
Function Get-VMSnapshots {
  param (
    [CmdletBinding()]
    # Cluster ID
    [Parameter(Mandatory=$false)]
    [string]$clusterID = '',
    # Page info after cursor
    [Parameter(Mandatory=$false)]
    [string]$afterCursor = ''
  )
  $variables = @{
    "first" = 500
    "filter" = @(
      @{
        "field" = "IS_RELIC"
        "texts" = @(
          "false"
        )
      }
      @{
        "field" = "IS_REPLICATED"
        "texts" = @(
          "false"
        )
      }
      @{
        "field" = "IS_ACTIVE"
        "texts" = @(
          "true"
        )
      }
      @{
        "field" = "NAME"
        "texts" = @(
          ""
        )
      }
      @{
        "field" = "CLUSTER_ID"
        "texts" = @(
          "$clusterID"
        )
      }
      @{
        "field" = "IS_ACTIVE_AMONG_DUPLICATED_OBJECTS"
        "texts" = @(
          "false"
        )
      }
    )
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
  }
  if ($afterCursor -ne '') {
    $variables.after = $afterCursor
  }
  $query = "query (`$first: Int!, `$after: String, `$filter: [Filter!]!, `$sortBy: HierarchySortByField, `$sortOrder: SortOrder) {
    vSphereVmNewConnection(
      filter: `$filter
      first: `$first
      after: `$after
      sortBy: `$sortBy
      sortOrder: `$sortOrder
    ) {
      edges {
        cursor
        node {
          id
          cdmId
          name
          objectType
          blueprintName
          blueprintId
          newestSnapshot {
            id
          }
          snapshotConnection {
            edges {
              node {
                id
                date
                cdmId
                cluster {
                  name
                  id
                }
                snappableId
              }
            }
          }
          ... on CdmHierarchyObject {
            replicatedObjectCount
            cluster {
              id
              name
              version
              status
              __typename
            }
          }
          ... on HierarchyObject {
            id
            effectiveSlaDomain {
              id
              name
              ... on GlobalSlaReply {
                isRetentionLockedSla
                retentionLockMode
                __typename
              }
              ... on ClusterSlaDomain {
                fid
                cluster {
                  id
                  name
                  __typename
                }
                isRetentionLockedSla
                retentionLockMode
                __typename
              }
              __typename
              ... on GlobalSlaReply {
                description
                __typename
              }
            }
            __typename
          }
          ... on HierarchyObject {
            effectiveSlaSourceObject {
              fid
              name
              objectType
              __typename
            }
            slaAssignment
            __typename
          }
          isRelic
          templateType
          primaryClusterLocation {
            id
            name
            __typename
          }
          slaPauseStatus
          snapshotDistribution {
            id
            totalCount
            __typename
          }
          vmwareToolsInstalled
          agentStatus {
            agentStatus
            __typename
          }
        }
        __typename
      }
      pageInfo {
        startCursor
        endCursor
        hasNextPage
        hasPreviousPage
        __typename
      }
      count
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.vSphereVmNewConnection
}  ### Function Get-VMSnapshots


# Get cluster stats
Function Get-ClusterStats {
  param (
    [CmdletBinding()]
    # Cluster ID
    [Parameter(Mandatory=$false)]
    [string]$clusterID = ''
  )
  $variables = @{
    "id" = $clusterID
  }
  $query = "query ClusterMetricQuery(`$id: UUID!) {
    cluster(clusterUuid: `$id) {
      id
      metric {
        ingestedSnapshotStorage
        usedCapacity
        liveMountCapacity
        miscellaneousCapacity
        physicalSnapshotStorage
        snapshotCapacity
        totalCapacity
        availableCapacity
        pendingSnapshotCapacity
        cdpCapacity
        physicalArchivalStorage
        averageDailyGrowth
        lastUpdateTime
        __typename
      }
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.cluster.metric
}  ### Function Get-ClusterStats

# Get RCV stats
Function Get-RCVStats {
  $query = "query RcsEntitlementQuery {
    rcsEntitlement: rcvAccountEntitlement {
      archiveEntitlement {
        capacity
        __typename
      }
      backupEntitlement {
        capacity
        __typename
      }
      entitlements {
        entitlement {
          bundle
          capacity
          tier
          redundancy
          __typename
        }
        usedCapacity
        __typename
      }
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.rcsEntitlement
}  ### Function Get-RCVStats


###### FUNCTIONS - END ######


Write-Host "Getting VMs and their snapshots..."

$vms = Get-VMSnapshots -clusterId $clusterID
$vmList = $vms.edges.node
Write-Host "Found $($vmList.count) VMs..."
while ($vms.pageInfo.hasNextPage -eq $true) {
  $vms = Get-VMSnapshots -clusterId $clusterID -afterCursor $vms.pageInfo.endCursor
  $vmList += $vms.edges.node
  Write-Host "Found $($vmList.count) VMs..."
}
$vmCount = $vmList.count
Write-Host "Found $($vmCount) VMs"

$clusterStats = Get-ClusterStats -clusterID $clusterID
$rcvStats = Get-RCVStats

$clusterUsedCapacityTB = [math]::Round($clusterStats.usedCapacity / $TB, 2)
$clusterFreeCapacityTB = [math]::Round($clusterStats.availableCapacity / $TB, 2)
$clusterTotalCapacityTB = [math]::Round($clusterStats.totalCapacity / $TB, 2)
$clusterPctUsed = [math]::Round($clusterUsedCapacityTB / $clusterTotalCapacityTB * 100, 2)

foreach ($tier in $rcvstats.entitlements) {
  if ($tier.entitlement.tier -eq 'BACKUP') {
    $rcvBackupTotalCapacityTB = $tier.entitlement.capacity
    $rcvBackupUsedCapacityTB = [math]::Round($tier.usedCapacity, 2)
    $rcvBackupFreeCapacity = $rcvBackupTotalCapacityTB - $rcvBackupUsedCapacityTB
    $rcvBackupPctUsed = [math]::Round($rcvBackupUsedCapacityTB / $rcvBackupTotalCapacityTB * 100, 2)
  }
  if ($tier.entitlement.tier -eq 'ARCHIVE') {
    $rcvArchiveTotalCapacityTB = $tier.entitlement.capacity
    $rcvArchiveUsedCapacityTB = [math]::Round($tier.usedCapacity, 2)
    $rcvArchiveFreeCapacity = $rcvArchiveTotalCapacityTB - $rcvArchiveUsedCapacityTB
    $rcvArchivePctUsed = [math]::Round($rcvArchiveUsedCapacityTB / $rcvArchiveTotalCapacityTB * 100, 2)
  }
}

$statsTable = [PSCustomObject] @{
  "Date" = $dateString
  "Cluster" = $clusterName
  "Cluster Used TB" = $clusterUsedCapacityTB
  "Cluster Free TB" = $clusterFreeCapacityTB
  "Cluster Total TB" = $clusterTotalCapacityTB
  "Cluster Used Pct" = $clusterPctUsed
  "RCV Backup Tier Used TB" = $rcvBackupUsedCapacityTB
  "RCV Backup Tier Free TB" = $rcvBackupFreeCapacity
  "RCV Backup Tier Total TB" = $rcvBackupTotalCapacityTB
  "RCV Backup Tier Used Pct" = $rcvBackupPctUsed
  "RCV Archive Tier Used TB" = $rcvArchiveUsedCapacityTB
  "RCV Archive Tier Free TB" = $rcvArchiveFreeCapacity
  "RCV Archive Tier Total TB" = $rcvArchiveTotalCapacityTB
  "RCV Archive Tier Used Pct" = $rcvArchivePctUsed
}

$statsTable | Format-Table

# Log out of RSC session
# $closeStatus = $(Invoke-RestMethod -Method DELETE -Uri $logoutUrl -Headers $headers -ContentType "application/json")

$statsTable | Export-CSV -Path $csvOutput -NoTypeInformation -Append
Write-Host "CSV output to: $csvOutput" -foregroundcolor green
