<#
.SYNOPSIS
This script will download a VMware VMDK from a specific recovery point.

.DESCRIPTION
This script will download a VMware VMDK from a specific recovery point.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 5/21/25

Requirements:
- Rubrik Security Cloud PowerShell SDK: https://github.com/rubrikinc/rubrik-powershell-sdk

.EXAMPLE
./Download-RubrikVMDK -.ps1
abc

#>

param (
  [CmdletBinding()]
  # VM ID
  [Parameter(Mandatory=$false)]
  [string]$vmID = '',
  # Snapshot ID
  [Parameter(Mandatory=$false)]
  [string]$snapshotID = '',
  # VMDK Filename
  [Parameter(Mandatory=$false)]
  [string]$vmdkFileName = ''
)

$vmID = '8cf7a1ce-ba6c-5dd6-ab2a-edcc142dda35'
$snapshotID = '8564b6a9-54ad-53df-954e-fd479b25c32b'
$vmdkFileName = '[rp-vmware-fc-05] tmp-pf-ad01/tmp-pf-ad01_1.vmdk'

### RSC GQL Queries - BEGIN ###

$mutationDownloadVMDK = 'mutation VsphereDownloadVirtualMachineFilesMutation($input: DownloadVsphereVirtualMachineFilesInput!) {
  downloadVsphereVirtualMachineFiles(input: $input) {
    id
    error {
      message
      __typename
    }
    status
    __typename
  }
}'

$varDownloadVMDK = @{
  "input" = @{
    "config" = @{
      "fileNamesToDownload" = @(
        "$vmdkFileName"
      )
      "vmId" = $vmID
    }
    "id" = $snapshotID
  }
}

$queryGetEvent = 'query EventSeriesListQuery($after: String, $filters: ActivitySeriesFilter, $first: Int, $sortBy: ActivitySeriesSortField, $sortOrder: SortOrder) {
  activitySeriesConnection(after: $after, first: $first, filters: $filters, sortBy: $sortBy, sortOrder: $sortOrder) {
    edges {
      cursor
      node {
        ...EventSeriesFragment
        cluster {
          id
          name
          timezone
          __typename
        }
        activityConnection(first: 50) {
          nodes {
            id
            message
            __typename
          }
          __typename
        }
        __typename
      }
      __typename
    }
    pageInfo {
      endCursor
      hasNextPage
      hasPreviousPage
      __typename
    }
    __typename
  }
}
fragment EventSeriesFragment on ActivitySeries {
  id
  fid
  activitySeriesId
  lastUpdated
  lastActivityType
  lastActivityStatus
  objectId
  objectName
  objectType
  severity
  progress
  isCancelable
  isPolarisEventSeries
  location
  effectiveThroughput
  dataTransferred
  logicalSize
  organizations {
    id
    name
    __typename
  }
  clusterUuid
  clusterName
  __typename
}'

$varGetEvent = @{
  "filters" = @{
    "objectType" = $null
    "lastActivityStatus" = $null
    "lastActivityType" = $null
    "severity" = $null
    "clusterId" = $null
    "lastUpdatedTimeGt" = $null
    "orgIds" = $null
    "userIds" = $null
    "objectName" = $null
    "objectFid" = $null
  }
  "first" = 25
}

### RSC GQL Queries - END ###

### Variables for RSC APIs - BEGIN ###

$date = Get-Date

### Variables for RSC APIs - END ###

Import-Module RubrikSecurityCloud

# Connect to RSC using RSC PowerShell SDK
Connect-Rsc

Write-Host "Download Mutation JSON:"
$varDownloadVMDK | ConvertTo-Json -depth 100

Write-Host ""
Write-Host "Triggering preparation of VMDK files on Rubrik to download"
Invoke-RSC -gqlquery $mutationDownloadVMDK -var $varDownloadVMDK

$varGetEvent.filters.lastActivityType = @('RECOVERY')
$varGetEvent.filters.objectFid = @("$vmID")

Write-Host "Waiting for 15 seconds then checking events..."
Start-Sleep -Seconds 15
Write-Host "Getting the most recent recovery events for the VM..."
$events = (Invoke-RSC -gqlquery $queryGetEvent -var $varGetEvent).edges.node

Write-Host "Checking events for the file download"
$num = 0
$foundEvent = $false
foreach ($e in $events) {
  $mes = $e.activityConnection.nodes[-1].message
  if ($mes.contains($vmdkFileName)) {
    Write-Host "match"
    $foundEvent = $true
  } else {
    $num++
  }
}

if ($foundEvent -eq $false) {
  Write-Error "No recovery event found for: $vmdkFileName, exiting..."
  exit
}

$recoveryEvent = $events[$num]
$eventID = $recoveryEvent.id
Write-Host "Recovery event found for $($recoveryEvent.objectName)"
Write-Host "UTC last updated time: $($recoveryEvent.LastUpdated)"
Write-Host "Current status: $($recoveryEvent.LastActivityStatus)"
while ($recoveryEvent.LastActivityStatus -ne 'SUCCESS') {
  Write-Host "Waiting 30 seconds before checking event again..."
  $events = (Invoke-RSC -gqlquery $queryGetEvent -var $varGetEvent).edges.node
  $recoveryEvent = $events | Where-Object { $_.id -eq $eventID}
}

Write-Host "Event messages:"
Write-Host ""

$recoveryEvent.ActivityConnection.nodes.message

# To contain the download links for each file
$fileList = @()
foreach ($a in $recoveryEvent.ActivityConnection.nodes) {
  if ($a.message -match 'Successfully prepared the Virtual Machine file content for these files: List\((.*?)\)') {
    # $matches[1] contains everything between "List(*)"
    $contentBetweenList = $matches[1]
    Write-Host "Extracted content: $contentBetweenList"
  } else {
    Write-Host "No match found."
  }
}

Disconnect-RSC
