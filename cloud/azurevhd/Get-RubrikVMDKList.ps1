<#
.SYNOPSIS
This script outputs all VMware VMDK info for VMs with at least one backup to a CSV.

.DESCRIPTION
This script outputs all VMware VMDK info for VMs with at least one backup to a CSV.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 5/21/25
Updated: 7/15/26

Requires PowerShell 7+.

.PARAMETER serviceAccountPath
File path to the RSC Service Account JSON file.

.EXAMPLE
./Get-RubrikVMDKList.ps1 -serviceAccountPath './rsc-service-account.json'
Runs the script and outputs the results to a CSV

#>

param (
  [CmdletBinding()]
  # File path to the RSC Service Account JSON
  [Parameter(Mandatory=$false)]
  [string]$serviceAccountPath = ''
)

### VARIABLES - BEGIN ###

# Testing variables
# $serviceAccountPath = './rsc-service-account.json'

$date = Get-Date

# CSV file info
$outCsvFile = "./rubrik_vm_list-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

### VARIABLES - END ###

if ([string]::IsNullOrEmpty($serviceAccountPath)) {
  Write-Host ""
  Write-Host "Usage: ./Get-RubrikVMDKList.ps1" -ForegroundColor Cyan
  Write-Host "  -serviceAccountPath <path to RSC service account JSON>"
  Write-Host ""
  exit
}

### RSC GQL Queries - BEGIN ###

$queryGetVMs = 'query VSphereVMsListQuery($first: Int!, $after: String, $filter: [Filter!]!, $sortBy: HierarchySortByField, $sortOrder: SortOrder) {
vSphereVmNewConnection(
  filter: $filter
  first: $first
  after: $after
  sortBy: $sortBy
  sortOrder: $sortOrder
) {
  edges {
    cursor
    node {
      id
      snapshotConnection {
        edges {
          node {
            id
            date
            archivalLocations {
              id
              name
            }
          }
        }
      }
      snapshotConsistencyMandate
      snapshotConsistencySource
      ... on HierarchyObject {
        id
        name
        objectType
        __typename
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
        __typename
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
        ... on CdmHierarchyObject {
          pendingSla {
            id
            name
            ... on ClusterSlaDomain {
              fid
              cluster {
                id
                name
                __typename
              }
              __typename
            }
            __typename
          }
          __typename
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
      ... on HierarchyObject {
        allOrgs {
          fullName
          __typename
        }
        __typename
      }
      isRelic
      templateType
      primaryClusterLocation {
        id
        name
        __typename
      }
      logicalPath {
        fid
        name
        objectType
        __typename
      }
      physicalPath {
        fid
        name
        objectType
        __typename
      }
      slaPauseStatus
      snapshotDistribution {
        id
        totalCount
        __typename
      }
      reportWorkload {
        id
        archiveStorage
        physicalBytes
        __typename
      }
      vmwareToolsInstalled
      agentStatus {
        agentStatus
        __typename
      }
      vsphereVirtualDisks {
        edges {
          node {
            fid
            datastoreFid
            fileName
            size
            __typename
          }
          __typename
        }
        __typename
      }
      __typename
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
}'

$varGetVMs = @{
  "first" = 1000
  "filter" = @(
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
      "field" = "IS_ACTIVE"
      "texts" = @(
        "true"
      )
    },
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

### RSC GQL Queries - END ###

###### RUBRIK AUTHENTICATION - BEGIN ######

if ($PSVersionTable.PSVersion.Major -lt 7) {
  throw "PowerShell 7+ is required. Current version: $($PSVersionTable.PSVersion)"
}

Write-Host "Reading Service Account file: $serviceAccountPath"
try {
  $serviceAccountFile = Get-Content -Path "$serviceAccountPath" -ErrorAction Stop | ConvertFrom-Json
} catch {
  throw "Failed to read Service Account JSON at '$serviceAccountPath': $($_.Exception.Message)"
}

$missingFields = @()
if ($null -eq $serviceAccountFile.client_id) { $missingFields += 'client_id' }
if ($null -eq $serviceAccountFile.client_secret) { $missingFields += 'client_secret' }
if ($null -eq $serviceAccountFile.access_token_uri) { $missingFields += 'access_token_uri' }

if ($missingFields.Count -gt 0) {
  throw "Service Account JSON is missing required fields: $($missingFields -join ', ')"
}

$payload = @{
  grant_type    = "client_credentials"
  client_id     = $serviceAccountFile.client_id
  client_secret = $serviceAccountFile.client_secret
}

try {
  $response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri `
    -Body ($payload | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop
} catch {
  throw "RSC authentication failed: $($_.Exception.Message)"
}

if ($null -eq $response.access_token) {
  throw "RSC returned a response but no access token was included."
}

$rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")

$global:rubrikConnection = @{
  accessToken = $response.access_token
  bearer = "Bearer $($response.access_token)"
  rubrikURL   = $rubrikURL
}

$endpoint = $rubrikURL + "/api/graphql"

$headers = @{
  'Content-Type'  = 'application/json'
  'Accept'        = 'application/json'
  'Authorization' = "Bearer $($response.access_token)"
}

Write-Host "Connected to RSC: $rubrikURL" -ForegroundColor Green

###### RUBRIK AUTHENTICATION - END ######

Write-Host "Getting a list of all VMs"
$vmList = @()
$afterCursor = ''
do {
  if ($afterCursor -ne '') {
    $varGetVMs.after = $afterCursor
  }
  $body = @{
    query = $queryGetVMs
    variables = $varGetVMs
  } | ConvertTo-Json -Depth 100
  $vmInventory = (Invoke-RestMethod -Method POST -Uri $endpoint -Body $body -Headers $headers).data.vSphereVmNewConnection
  $vmList += $vmInventory.edges.node
  $afterCursor = $vmInventory.pageInfo.endCursor
} while ($vmInventory.pageInfo.hasNextPage)

# Filter VMs by those that have at least one backup
$vmList = $vmList | Where-Object { $_.SnapshotConnection.edges.node -ne $null }
$vmCount = $vmList.count
Write-Host "Found $vmCount VMs that have at least backup" -foregroundcolor green

# Use this if you want to filter by only objects with a SLA assigned to it
# $vmList = $vmList | Where-Object { $_.effectiveSlaDomain.name -ne 'UNPROTECTED' -and
#   $_.effectiveSlaDomain.name -ne 'DO_NOT_PROTECT' }

$vmOutput = @()
foreach ($vm in $vmList) {
  foreach ($vmDisk in $vm.VsphereVirtualDisks.edges.node) {
    $vmDiskInfo = [PSCustomObject] @{
      "Name" = $vm.Name
      "Cluster" = $vm.Cluster.Name
      "ID" = $vm.Id
      "SLA" = $vm.EffectiveSlaDomain.Name
      "Convert" = ""
      "vmdkFile" = $vmDisk.FileName
      "vmdkSizeGiB" = [math]::Round($vmDisk.Size / 1073741824, 1)
      "LatestBackupDate" = $vm.snapshotconnection.edges.node[-1].Date
      "LatestBackupID" = $vm.snapshotconnection.edges.node[-1].Id
      "OldestBackupDate" = $vm.snapshotconnection.edges.node[0].Date
      "OldestBackupID" = $vm.snapshotconnection.edges.node[0].Id
      "Notes" = ""
    }
    $vmOutput += $vmDiskInfo
  }
}

$vmOutput | Export-CSV -Path $outCsvFile -NoTypeInformation
Write-Host "VMDK info output to: $outCsvFile" -foregroundcolor green
