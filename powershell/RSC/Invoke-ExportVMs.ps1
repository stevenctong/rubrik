# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will get a list of VMs and do a restore via Export.

.DESCRIPTION
This script will get a list of VMs and do a restore via Export.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 7/29/25

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath


.EXAMPLE
./Invoke-ExportVMs.ps1
Runs the script and outputs VM info to a CSV file

./Invoke-ExportVMs.ps1 -restore $true
Runs the script and initiates a restore via Export
#>

param (
  [CmdletBinding()]
  # Whether to initiate a restore or not
  [Parameter(Mandatory=$false)]
  [bool]$restore = $false
)

### Variables section - please fill out as needed

# File location of the RSC service account json
$serviceAccountPath = "./rubrik_sa.json"

$date = Get-Date
$utcDate = $date.ToUniversalTime()

$rhelLG = '61623916-fcda-5ad2-9c83-74d845dae418'
$rhelSM = '7b5a615e-2615-561d-9cb6-f8bf0a171f69'

# SMTP configuration if you want to send an email at the end of this script
# $emailTo = @('')
# $emailFrom = ''
# $SMTPServer = ''
# $SMTPPort = '25'
# $emailSubject = "Rubrik Object Capacity Summary - " + $date.ToString("yyyy-MM-dd HH:MM")

# Set to $true to send out email at the end of this script
# $sendEmail = $false

### End Variables section

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
if ($serviceAccountFile.client_id -eq $null) {
  $missingServiceAccount += "'client_id'"
}
if ($serviceAccountFile.client_secret -eq $null) {
  $missingServiceAccount += "'client_secret'"
}
if ($serviceAccountFile.access_token_uri -eq $null) {
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
$response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers

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

##### FUNCTIONS - BEGIN #####

# Get Cluster list
Function Get-ClusterList {
  param (
    [CmdletBinding()]
    # Page info after cursor
    [Parameter(Mandatory=$false)]
    [string]$clusterUUID = ''
  )
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
}  ### Function ClusterList

# Get VM list
Function Get-VMList {
  param (
    [CmdletBinding()]
    # Page info after cursor
    [Parameter(Mandatory=$false)]
    [string]$afterCursor = '',
    # Whether to get Relics or Active VMs
    [Parameter(Mandatory=$false)]
    [string]$relics = $false
  )
  $variables = @{
    "first" = 1000
    "filter" = @(
      @{
        "field" = "IS_RELIC"
        "texts" = @(
          "$relics"
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
  if ($afterCursor -ne '') {
    $variables.after = $afterCursor
  }
  $query = "query (`$first: Int!, `$after: String, `$filter: [Filter!]!, `$sortBy: HierarchySortByField, `$sortOrder: SortOrder) {
    vSphereVmNewConnection(filter: `$filter, first: `$first, after: `$after, sortBy: `$sortBy, sortOrder: `$sortOrder) {
      edges {
        cursor
        node {
          id
          name
          objectType
          cluster {
            id
            name
            version
            status
          }
          isRelic
          primaryClusterLocation {
            id
            name
          }
          logicalPath {
            fid
            name
            objectType
          }
          physicalPath {
            fid
            name
            objectType
          }
          newestSnapshot {
           id
           date
           resourceSpec
           cdmWorkloadSnapshot {
             subObjs {
               subObj {
                 vmwareVmSubObj {
                   currentDatastoreId
                   deviceKey
                   virtualDiskId
                   filename
                   fileSizeInBytes
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
        __typename
      }
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $vmList = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers).data.vSphereVmNewConnection
  return $vmList
}  ### Function VMList

# Get vCenter list
Function Get-vCenterList {
  $variables = @{
    "typeFilter" = @(
      "VSphereDatacenter"
    )
    "filter" = @(
      @{
        "field" = "NAME"
        "texts" = @(
          ""
        )
      }
    )
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
  }
  $query = 'query ($filter: [Filter!], $typeFilter: [HierarchyObjectTypeEnum!], $sortBy: HierarchySortByField, $sortOrder: SortOrder) {
    vSphereVCenterConnection(filter: $filter) {
      edges {
        node {
          name
          id
          vcenterId
          primaryClusterLocation {
            name
            id
          }
          objectType
          descendantConnection(
            typeFilter: $typeFilter
            sortBy: $sortBy
            sortOrder: $sortOrder
          ) {
            edges {
              node {
                id
                name
                objectType
              }
            }
          }
        }
      }
    }
  }'
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.vSphereVCenterConnection.edges.node
}  ### Function vCenterList

# Get vCenter Data Center / Compute Cluster list
Function Get-VMComputeCluster {
  param (
    [CmdletBinding()]
    # Pass in vCenter Data Center ID
    [Parameter(Mandatory=$false)]
    [string]$vCenterDataCenterID = ''
  )
  $variables = @{
    "fid" = $vCenterDataCenterID
    "keywordFilter" = ""
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
    "first" = 100
  }
  $query = 'query ($fid: UUID!, $keywordFilter: String!, $first: Int, $after: String, $sortBy: HierarchySortByField, $sortOrder: SortOrder) {
    vSphereDatacenter(fid: $fid) {
      id
      name
      objectType
      cdmId
      primaryClusterLocation {
        name
        id
      }
      descendantConnection(
        typeFilter: [VSphereComputeCluster, VSphereHost]
        first: $first
        after: $after
        filter: {field: NAME, texts: [$keywordFilter]}
        sortBy: $sortBy
        sortOrder: $sortOrder
      ) {
        edges {
          node {
            id
            name
            objectType

          }
          cursor
        }
        pageInfo {
          startCursor
          endCursor
          hasPreviousPage
          hasNextPage
        }
      }
    }
  }'
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.vSphereDatacenter.descendantConnection.edges.node
}  ### Function Get-VMComputeCluster

# Get VMware datastores for a Compute Cluster
Function Get-VMDataStores {
  param (
    [CmdletBinding()]
    # Pass in a Compute Cluster ID
    [Parameter(Mandatory=$false)]
    [string]$computeClusterID = ''
  )
  $variables = @{
    "clusterId" = $computeClusterID
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
    "first" = 200
  }
  $query = 'query ComputeClusterDatastoresQuery($clusterId: UUID!, $first: Int!, $after: String, $filter: [Filter!], $sortBy: HierarchySortByField, $sortOrder: SortOrder) {
  hierarchyObjectRecoveryTarget(fid: $clusterId) {
    id
    ... on VsphereComputeCluster {
      recoveryTargetDescendantConnection(
        first: $first
        after: $after
        filter: $filter
        sortBy: $sortBy
        sortOrder: $sortOrder
        typeFilter: [VSphereDatastore, VSPHERE_DATASTORE_CLUSTER]
      ) {
        edges {
          cursor
          node {
            ... on HierarchyObject {
              id
              name
              objectType
              __typename
              ... on VsphereDatastore {
                capacity
                isLocal
                freeSpace
                datastoreType
                __typename
              }
              ... on VsphereDatastoreCluster {
                capacity
                freeSpace
                isSdrsEnabled
                descendantConnection(first: 1) {
                  nodes {
                    ... on VsphereDatastore {
                      datastoreType
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
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
      __typename
    }
    __typename
  }
}'
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.hierarchyObjectRecoveryTarget.recoveryTargetDescendantConnection.edges.node
}  ### Function Get-VMDataStores

# Get VM Networks for a Compute Cluster
Function Get-VMNetworks {
  param (
    [CmdletBinding()]
    # Pass in VM Compute Cluster ID
    [Parameter(Mandatory=$false)]
    [string]$computeClusterID = ''
  )
  $variables = @{
    "fid" = $computeClusterID
  }
  $query = 'query ($fid: UUID!) {
    vSphereComputeCluster(fid: $fid) {
      id
      name
      cluster {
        name
        id
      }
      physicalPath {
        fid
        name
      }
      descendantConnection(typeFilter: [VSphereNetwork]) {
        edges {
          node {
            ... on VsphereNetwork {
              id
              name
              moid
            }
          }
        }
      }
    }
  }'
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result.data.vSphereComputeCluster
}  ### Function Get-VMNetworks

# Recover VM via Export (clone)
Function Export-VM {
  param (
    [CmdletBinding()]
    # Pass in VM Detail object
    [Parameter(Mandatory=$false)]
    [PSCustomObject]$vm = ''
  )
  $diskList = @()
  $defaultStorageId = 0
  foreach ($disk in $vm.datastores) {
    $diskDetail = @{
      "deviceKey" = $disk.deviceKey
      "storageLocationId" = $disk.currentDatastoreId
    }
    if ($defaultStorageId -eq 0 -or $($disk.deviceKey) -eq 2000) {
      $defaultStorageId = $disk.currentDatastoreId
    }
    $diskList += $diskDetail
  }
  $vNicList = @()
  foreach ($vnic in $vm.networkInterfaces) {
    $vNicDetail = @{
      "networkDeviceInfo" = @{
        "key" = $vnic.key
        "name" = $vnic.deviceLabel
      }
      "backingNetworkInfo" = @{
        "moid" = $vnic.vNetID
        "name" = $vnic.vNetName
      }
    }
    $vNicList += $vNicDetail
  }
  $restoreName = $vm.name + "_" + $vm.NewestSnapshotString
  if ($vm.name -match 'r-lg') {
    $folderID = '61623916-fcda-5ad2-9c83-74d845dae418'
  } else {
    $folderID = '7b5a615e-2615-561d-9cb6-f8bf0a171f69'
  }
  $variables = @{
    "input" = @{
      "id" = $vm.id
      "config" = @{
        "clusterId" = $vm.ComputeClusterID
        "diskDeviceKeyToStorageId" = $diskList
        "mountExportSnapshotJobCommonOptionsV2" = @{
          "keepMacAddresses" = $false
          "powerOn" = $false
          "removeNetworkDevices" = $false
          "vmName" = $restoreName
        }
        "requiredRecoveryParameters" = @{
          "snapshotId" = $vm.NewestSnapshotID
        }
        "resourcePoolId" = $null
        "shouldRecoverTags" = $true
        "shouldUseHotAddProxy" = $false
        "storageLocationId" = $defaultStorageId
        "vNicBindings" = $vNicList
        "shouldConvertToTemplate" = $false
        "folderId" = $folderId
      }
    }
  }
  $query = 'mutation VSphereVmExportSnapshotV3Mutation($input: VsphereVmExportSnapshotV3Input!) {
    vsphereVmExportSnapshotV3(input: $input) {
      id
      __typename
    }
  }'
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result
}  ### Function Export-VM


##### FUNCTIONS - END #####

Write-Host "Getting VMware VMs..."
$vmList = @()
$afterCursor = ''
do {
  $vmInventory = Get-VMList -afterCursor $afterCursor -relics 'true'
  $vmList += $vmInventory.edges.node
  $afterCursor = $vmInventory.pageInfo.endCursor
} while ($vmInventory.pageInfo.hasNextPage)
$vmList = $vmList | Where { $_.Name -match 'r-sm' -or $_.Name -match 'r-l' }
$vmList = $vmList | Where { $_.Name -notmatch '_' }
Write-Host "Found $($vmList.count) VMs"
Write-Host ""

# Get list of unique Cluster IDs in VM list
$uniqueClusterIDs = @()
$uniqueClusterIDs = $vmlist | ForEach-Object { $_.Cluster.ID } | Sort-Object -Unique

Write-Host "Getting vCenters..."
$vCenterList = Get-vCenterList
Write-Host "Found the following vCenters:"
foreach ($vc in $vCenterList) {
  Write-Host "$($vc.name) for $($vc.primaryClusterLocation.name)"
}
Write-Host ""

Write-Host "Getting compute cluster info..."
# Stores list of VMware compute clusters
$computeClusters = @()

# Loop through each vCenter to the Data Center level
foreach ($vc in $vCenterList) {
  # Check if there are Data Centers under the vCenter
  if ($vc.descendantConnection.edges.node.count -gt 0) {
    # Loop through each Data Center to get the Compute Cluster
    foreach ($dc in $vc.descendantConnection.edges.node) {
      if ($dc.objectType -eq 'VSphereDatacenter') {
        $computeCluster = Get-VMComputeCluster -vCenterDataCenterID $dc.id
        foreach ($item in $computeCluster) {
          if ($item.objectType -eq 'VSphereComputeCluster') {
            $computeClusterItem = [PSCustomObject]@{
              "Cluster" = $vc.primaryClusterLocation.name
              "ClusterID" = $vc.primaryClusterLocation.id
              "vCenterName" = $vc.name
              "vCenterID" = $vc.id
              "vCenterCDMID" = $vc.vcenterId
              "vCenterPrimaryClusterLocation" = $vc.primaryClusterLocation
              "vCenterObjectType" = $vc.objectType
              "vCenterDescedentConnection" = $vc.descendantConnection
              "dataCenterName" = $vc.descendantConnection.edges.node.name
              "dataCenterID" = $vc.descendantConnection.edges.node.id
              "dataCenterObjectType" = $vc.descendantConnection.edges.node.objectType
              "computeClusterName" = $item.name
              "computeclusterID" = $item.id
              "computeClusterObjectType" = $item.objectType
            }
            $computeClusters += $computeClusterItem
          }
        }
      }
    }
  }
}
Write-Host "Found the following compute clusters:"
$uniqueCC = $computeClusters.computeclusterName | Sort-Object -Unique
$uniqueCC
Write-Host ""

Write-Host "Getting storage datastore info..."
$datastoreList = @()
foreach ($ccID in $($computeClusters.computeclusterID)) {
  $datastores = Get-vmDataStores -computeClusterID $ccID
  $vSphereDatastores = $datastores | Where { $_.objectType -eq 'VSphereDatastore' }
  foreach ($ds in $vSphereDatastores) {
    $ds | Add-Member -MemberType NoteProperty -Name "ComputeClusterID" -Value $ccID
  }
  $datastoreList += $vSphereDatastores
}
Write-Host "Found the following datastores:"
$uniqueDS = $datastoreList.name | Sort-Object -Unique
$uniqueDS
Write-Host ""

Write-Host "Getting VNET info..."
$vnetList = @()
foreach ($ccID in $($computeClusters.computeclusterID)) {
  $vnets = Get-VMNetworks -computeClusterID $ccID
  $vnetDetails = $vnets.descendantConnection.edges.node
  foreach ($v in $vnetDetails) {
    $v | Add-Member -MemberType NoteProperty -Name "ComputeClusterID" -Value $ccID
  }
  $vnetList += $vnetDetails
}
Write-Host "Found the following VNETs:"
$uniqueVnet = $vnetList.name | Sort-Object -Unique
$uniqueVnet
Write-Host ""


Write-Host "Building detailed info for each VM..."
# Contains list of VMs with all human readable and UIDs
$vmListDetail = @()

# Builds a list of VMs with their source details
foreach ($vm in $vmList) {
  foreach ($ds in $vm.newestsnapshot.cdmWorkloadSnapshot.subObjs.subobj.vmwareVmSubObj) {
    $dsDetail = $datastoreList | Where { $_.id -eq $ds.currentDatastoreId }
    # $dsCluster = $dsDetail.physicalPath | Where { $_.objectType -eq 'VSPHERE_DATASTORE_CLUSTER' }
    $ds | Add-Member -MemberType NoteProperty -Name "datastoreName" -Value $dsdetail.name -force
    # $ds | Add-Member -MemberType NoteProperty -Name "datastoreCluster" -Value $dsCluster.name -force
    # $ds | Add-Member -MemberType NoteProperty -Name "datastoreClusterID" -Value $dsCluster.fid -force
  }
  $computeCluster = $vm.physicalPath | Where { $_.objectType -eq 'VSphereComputeCluster' }
  $vnets = $vnetList | Where { $_.ComputeClusterID -eq $computeCluster.fid}
  $resourceSpec = $vm.newestSnapshot.resourceSpec | ConvertFrom-Json | ConvertFrom-Json
  # Go through each NIC and add the VNET name
  foreach ($nic in $resourceSpec.NetworkInterfaces) {
    $vnetName = $vnets | Where { $_.moid -eq $resourceSpec.networkinterfaces.networkMoidOpt }
    $resourceSpec.networkinterfaces | Add-Member -MemberType NoteProperty -Name "vNetName" -Value $vnetName.name
    $resourceSpec.networkinterfaces | Add-Member -MemberType NoteProperty -Name "vNetID" -Value $vnetName.id
  }
  $vmDetail = [PSCustomObject] @{
    "Name" = $vm.name
    "ID" = $vm.id
    "Cluster" = $vm.primaryClusterLocation.name
    "ClusterID" = $vm.primaryClusterLocation.id
    "ComputeCluster" = $computeCluster.name
    "ComputeClusterID" = $computeCluster.fid
    "NewestSnapshot" = $vm.newestSnapshot.date
    "NewestSnapshotID" = $vm.newestSnapshot.id
    "NewestSnapshotString" = $vm.newestsnapshot.date.ToString("MM_dd HH:mm")
    "Datastores" = $vm.newestsnapshot.cdmWorkloadSnapshot.subObjs.subobj.vmwareVmSubObj
    "NetworkInterfaces" = $resourceSpec.NetworkInterfaces
    "Folder" = $vm.logicalPath[0].name
    "FolderID" = $vm.logicalPath[0].fid
  }
  $vmListDetail += $vmDetail
}

Write-Host "Exporting details to: vmlist.csv"
$vmListDetail | Export-CSV -Path './vmlist.csv' -NoTypeInformation

if ($restore) {
  $vmListDetail = $vmListDetail | sort-object { Get-Random }
  $total = $vmListDetail.count
  $count = 1
  Write-Host "Initiating restores via Export for $total VMs..." -foregroundcolor green
  foreach ($vm in $vmListDetail) {
    Write-Host "[$count / $total] Initiating restore for: $($vm.name), recovery time: $($vm.newestsnapshotstring)"
    $result = Export-VM -vm $vm
    $result.data
    $count += 1
  }
}
