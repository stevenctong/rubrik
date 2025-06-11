<#
.SYNOPSIS
This script will get all Rubrik VMs by a specified vSphere tag and export
the VMDK details to a CSV, with an option to exclude all VMDKs that aren't
the first discovered disk by Device Key.

.DESCRIPTION
This script will get all Rubrik VMs by a specified vSphere tag and export
the VMDK details to a CSV, with an option to exclude all VMDKs that aren't
the first discovered disk by Device Key.

The script will sort each VM's VMDKs by Device Key and exclude any VMDK that is
not the first VMDK in the list.

Typically the first VMDK will have a Device Key of 2000. If the script finds
that the first VMDK doesn't have a Device Key of 2000, it will highlight this
to console.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 6/10/25

Requirements:
- Rubrik Security Cloud PowerShell SDK: https://github.com/rubrikinc/rubrik-powershell-sdk

.EXAMPLE
./Get-Exclude-RubrikVMDKs.ps1
Runs the script and outputs the VMDK details to a CSV file.

.EXAMPLE
./Get-Exclude-RubrikVMDKs.ps1 -excludeVMDKs $true
Runs the script, outputs the original VMDK settings to a CSV file, and excludes
all VMDKs that isn't the lowest found Device Key on each VM.

#>


param (
  [CmdletBinding()]
  # Set to $true to exclude all VMDKs matching the tag
  [Parameter(Mandatory=$false)]
  [bool]$excludeVMDKs = $false
)

### Variables - BEGIN ###

$date = Get-Date

# Fill out Tag Name or both Category and Tag Name
# vSphereTagName = value of the vSphere tag
$vSphereTagName = ''
# vsphereTagCategory = vSphere tag category key, optional
$vsphereTagCategory = ''

# CSV file to export VMDK info before doing any exclusions
$csvOutputPre = "./rubrik_vmdks-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# CSV file to export VMDK info after doing exclusions
$csvOutputPost = "./rubrik_vmdks_post-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

### Variables - END ###

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
      vsphereTagPath {
        fid
        name
        objectType
      }
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
            deviceKey
            excludeFromSnapshots
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
  "first" = 100
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

$mutationExcludeVMDK = 'mutation ExcludeVMDKsMutation($input: [ExcludeVmDisksInput!]!) {
  excludeVmDisks(input: $input) {
    success
    __typename
  }
}'

$varExcludeVMDK = @{
  "input" = @(
    @{
      "virtualDiskFid" = ''
      "excludeFromSnapshots" = $true
    }
  )
}

### FUNCTIONS - BEGIN ###

$vSphereTagName = 'chris.lumnah@rubrik.com'
$vsphereTagCategory = ''

# The Get-Tagged-VMs Function gets all VMs and filters them by the tag
# Name and Category (optional) that is provided.
Function Get-Tagged-VMs()
{
  param (
    [string] $vsphereTagCategory = '',
    [string] $vSphereTagName = ''
  )
  Write-Host "Getting a list of all VMs"
  $vmList = @()
  $afterCursor = $null
  do {
    $varGetVMs.after = $afterCursor
    $vmInventory = (Invoke-RSC -gqlquery $queryGetVMs -var $varGetVMs)
    $vmList += $vmInventory.edges.node
    Write-Host "Found $($vmList.count) VMs so far..."
    $afterCursor = $vmInventory.pageInfo.endCursor
  } while ($vmInventory.pageInfo.hasNextPage)

  # Filter VMs by vSphere tag
  # If category is provided, first filter by category
  if ($vsphereTagCategory -ne '') {
    Write-Host "Filtering VMs by tag category: $vsphereTagCategory"
    $vmTagList = $vmList | Where-Object { $_.vsphereTagPath.Name -eq $vsphereTagCategory -and
      $_.vsphereTagPath.objectType -eq 'VSPHERE_TAG_CATEGORY' }
    Write-Host "$($vmTagList.count) VMs found with tag category: $vsphereTagCategory"
    # Filter VMs by tags
    Write-Host "Filtering VMs by tag name: $vSphereTagName"
    $vmTagList = $vmList | Where-Object { $_.vsphereTagPath.Name -eq $vSphereTagName -and
      $_.vsphereTagPath.ObjectType -eq 'VSPHERE_TAG' }
    Write-Host "$($vmTagList.count) VMs found with tag name: $vSphereTagName"
  } else {
    # Filter VMs by tags
    Write-Host "Filtering VMs by tag name: $vSphereTagName"
    $vmTagList = $vmList | Where-Object { $_.vsphereTagPath.Name -eq $vSphereTagName -and
      $_.vsphereTagPath.ObjectType -eq 'VSPHERE_TAG' }
    Write-Host "$($vmTagList.count) VMs found with tag name: $vSphereTagName"
  }
  return $vmTagList
} ## Function Get-Tagged-VMs()

Function Get-VMDKs() {
  param (
    [array] $vmTagList = ''
  )
  # Build list of VMs and VMDK info
  $vmdkList = @()
  foreach ($vm in $vmTagList) {
    $vmdks = $vm.VsphereVirtualDisks.edges.node | Sort-Object -Property DeviceKey
    foreach ($vmDisk in $vmdks) {
      $vmDiskInfo = [PSCustomObject] @{
        "Name" = $vm.Name
        "Cluster" = $vm.Cluster.Name
        "ID" = $vm.Id
        "SLA" = $vm.EffectiveSlaDomain.Name
        "DeviceKey" = $vmDisk.DeviceKey
        "vmdkFile" = $vmDisk.FileName
        "vmdkSizeGiB" = [math]::Round($vmDisk.Size / 1073741824, 1)
        "ExcludeFromSnapshots" = $vmDisk.ExcludeFromSnapshots
        "Notes" = ""
      }
      $vmdkList += $vmDiskInfo
    }
  }
  return $vmdkList
} ## Get-VMDKs()

### FUNCTIONS - END ###


### RSC GQL Queries - END ###

Write-Host "Connecting to Rubrik Security Cloud"
Import-Module RubrikSecurityCloud
Connect-Rsc

$vmTagList = Get-Tagged-VMs -vSphereTagName $vSphereTagName -vsphereTagCategory $vsphereTagCategory
$vmdkList = Get-VMDKs -vmTagList $vmTagList

$vmdkList | Export-CSV -Path $csvOutputPre -NoTypeInformation
Write-Host "VMDK info output to: $csvOutputPre" -foregroundcolor green

if ($excludeVMDKs) {
  Write-Host ""
  Write-Host "Excluding VMDKs for matching VMs that aren't excluded yet"
  Write-Host "VMDKs will be sorted by Device Key"
  Write-Host "Any VMDK that is in the 2nd order or higher will be excluded"
  Write-Host ""
  foreach ($vm in $vmTagList) {
    $vmdks = $vm.VsphereVirtualDisks.edges.node | Sort-Object -Property DeviceKey
    $index = 0
    foreach ($vmDisk in $vmdks) {
      $varExcludeVMDK.input[0].virtualDiskFid = ''
      $vmdkSizeGiB = [math]::Round($vmDisk.Size / 1073741824, 1)
      if ($index -eq 0 -and $vmDisk.DeviceKey -ne 2000) {
        Write-Host "For VM: $($vm.Name), first disk found does not have Device Key of 2000" -foregroundcolor yellow
        Write-Host "Did not exclude the first disk: $($vmDisk.FileName), $vmdkSizeGiB GiB" -foregroundcolor yellow
      }
      if ($index -gt 0 -and $vmDisk.DeviceKey -ne 2000 -and
          $vmDisk.ExcludeFromSnapshots -eq $false) {
        Write-Host "VM: $($VM.Name), excluding VMDK: $($vmDisk.FileName), $vmdkSizeGiB GiB, Device Key: $($vmDisk.DeviceKey)"
        $varExcludeVMDK.input[0].virtualDiskFid = $vmDisk.Fid
        Invoke-RSC -gqlquery $mutationExcludeVMDK -var $varExcludeVMDK
      }
      $index +=1
    }
  }
  $vmTagList = Get-Tagged-VMs -vSphereTagName $vSphereTagName -vsphereTagCategory $vsphereTagCategory
  $vmdkList = Get-VMDKs -vmTagList $vmTagList
  $vmdkList | Export-CSV -Path $csvOutputPost -NoTypeInformation
  Write-Host "VMDK info output to: $csvOutputPost" -foregroundcolor green
}

$disconnect = Disconnect-RSC
