<#
.SYNOPSIS
This script outputs all VMware VMDK info for VMs with at least one backup to a CSV.

.DESCRIPTION
This script outputs all VMware VMDK info for VMs with at least one backup to a CSV.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 5/21/25

Requirements:
- Rubrik Security Cloud PowerShell SDK: https://github.com/rubrikinc/rubrik-powershell-sdk

.EXAMPLE
./Get-RubrikVMDKList.ps1
Runs the script and outputs the results to a CSV

#>

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

### Variables for RSC APIs - BEGIN ###

$date = Get-Date

# CSV file info
$vmCSV = "./rubrik_vm_list-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

### Variables for RSC APIs - END ###

Import-Module RubrikSecurityCloud

# Connect to RSC using RSC PowerShell SDK
Connect-Rsc

Write-Host "Getting a list of all VMs"
$vmList = @()
$afterCursor = ''
do {
  if ($afterCursor -ne '') {
    $varGetVMs.after = $afterCursor
  }
  $vmInventory = (Invoke-RSC -gqlquery $queryGetVMs -var $varGetVMs)
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

$vmOutput | Export-CSV -Path $vmCSV -NoTypeInformation
Write-Host "VMDK info output to: $vmCSV" -foregroundcolor green

Disconnect-RSC
