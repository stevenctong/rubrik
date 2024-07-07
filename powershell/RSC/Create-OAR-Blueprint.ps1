# https://www.rubrik.com/api
<#
.SYNOPSIS
This script has functions to help create an OAR blueprint.

.DESCRIPTION
This script has functions to help create an OAR blueprint.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 7/4/24

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only reporting role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath


.EXAMPLE
./Create-OAR-Blueprint.ps1
#>

param (
  [CmdletBinding()]
  # Source Rubrik cluster for the blueprint
  [Parameter(Mandatory=$false)]
  [string]$sourceClusterName = 'vault-r-london',
  # Target Rubrik cluster for the blueprint
  [Parameter(Mandatory=$false)]
  [string]$targetClusterName = 'vault-r-madison'
)

### Variables section - please fill out as needed

# File location of the RSC service account json
$serviceAccountPath = "./rsc-service-account-rr.json"

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# Provide a list of source VMs to add to a blueprint
$sourceVMList = @( 'rp-sql19sl-01', 'rp-sql19sl-02')

# Whether or not to try to first match the target compute cluster to the source
# Compute Cluster name.
# The logic for mapping the Compute Clusters is within the code block.
$computeClusterMatch = $true

# Compute Cluster to use if VM name has SQL or ORA in it
$computeSQLMatch = 'perf-cluster-PaloAlto'
$computeORAMatch = 'perf-cluster-PaloAlto'

# Default Compute Cluster to use if no match or no mapping
$computeClusterDefault = 'perf-cluster-PaloAlto'

# Whether or not to try to first match the target Datastore Cluster to the source
# Datastore Cluster.
# $datastoreClusterMatch = $false
# The mapping for the datastore clusters
$datastoreClustersMapping = @{
  "QCPESXORA-ZA-A-DATA01-ZB-PV01" = "QCDRESXORA-A-DATA01-PV"
  "QCPESXORA-ZA-A-DATA02-ZB-PV01" = "QCDRESXORA-A-DATA02-PV"
  "rp-dsc-fc-01" = "rp-dsc-fc-01"
}
# Default Compute Cluster to use if no match or no mapping
$datastoreClusterDefault = 'rp-dsc-fc-01'

# Whether or not to try to first match the target VNET to the source VNET name.
# $vnetMatch = $true

# Whether save the report CSV for each run or not
$saveCSV = $true
# Location to save the RSC report CSVs
$csvFileName = "./csvReports/rubrik_objectcapacity_csv-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

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
    [string]$afterCursor = ''
  )
  $variables = @{
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
  $query = "query (`$filter: [Filter!], `$typeFilter: [HierarchyObjectTypeEnum!], `$sortBy: HierarchySortByField, `$sortOrder: SortOrder) {
    vSphereVCenterConnection(filter: `$filter) {
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
            typeFilter: `$typeFilter
            sortBy: `$sortBy
            sortOrder: `$sortOrder
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
  }
"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $vCenterList = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $vCenterList.data.vSphereVCenterConnection.edges.node
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
  $query = "query (`$fid: UUID!, `$keywordFilter: String!, `$first: Int, `$after: String, `$sortBy: HierarchySortByField, `$sortOrder: SortOrder) {
    vSphereDatacenter(fid: `$fid) {
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
        first: `$first
        after: `$after
        filter: {field: NAME, texts: [`$keywordFilter]}
        sortBy: `$sortBy
        sortOrder: `$sortOrder
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
  }
"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $vCenterDataCenterList = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $vCenterDataCenterList.data.vSphereDatacenter.descendantConnection.edges.node
}  ### Function Get-VMComputeCluster

# Get VMware Datastore Clusters for a Rubrik cluster
Function Get-VMDataStores {
  param (
    [CmdletBinding()]
    # Pass in Rubrik Cluster ID
    [Parameter(Mandatory=$false)]
    [string]$rubrikClusterID = ''
  )
  $variables = @{
    "filter" = @(
      @{
        "field" = "CLUSTER_ID"
        "texts" = @(
          $rubrikClusterID
        )
      }
    )
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
  }
  $query = "query (`$sortBy: HierarchySortByField, `$sortOrder: SortOrder, `$filter: [Filter!]) {
    vSphereDatastoreClusters(
      sortBy: `$sortBy
      sortOrder: `$sortOrder
      filter: `$filter
    ) {
      edges {
        node {
          id
          name
          objectType
          isSdrsEnabled
          freeSpace
          capacity
          __typename
          descendantConnection {
            edges {
              node {
                id
                name
                objectType
                physicalPath {
                  fid
                  name
                  objectType
                }
              }
            }
          }
        }
      }
      pageInfo {
        endCursor
        startCursor
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
  $vmDataStores = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $vmDataStores.data.vSphereDatastoreClusters.edges.node
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
  $query = "query (`$fid: UUID!) {
    vSphereComputeCluster(fid: `$fid) {
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
  }
"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $vmNetworks = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $vmNetworks.data.vSphereComputeCluster
}  ### Function Get-VMNetworks

Write-Host "Getting Rubrik clusters..."
$clusterList = Get-ClusterList

$sourceClusterID = $($clusterList | Where { $_.name -eq $sourceClusterName }).id
$targetClusterID = $($clusterList | Where { $_.name -eq $targetClusterName }).id

# Put in an array for easy access / comparison
$clusters = [PSCustomObject] @{
  "sourceClusterName" = $sourceClusterName
  "sourceClusterID" = $sourceClusterID
  "targetClusterName" = $targetClusterName
  "targetClusterID" = $targetClusterID
}

Write-Host "Getting VMware VMs..."
$vmList = @()
$afterCursor = ''
do {
  $vmInventory = Get-VMList -afterCursor $afterCursor
  $vmList += $vmInventory.edges.node
  $afterCursor = $vmInventory.pageInfo.endCursor
} while ($vmInventory.pageInfo.hasNextPage)
Write-Host "Found $($vmList.count) VMs"

$sourceClusterVMList = $vmList | Where { $_.cluster.name -eq $sourceClusterName }
$sourceVMs = $sourceClusterVMList | Where { $sourceVMList -contains $_.name }
Write-Host "Found $($sourceVMs.count) VMs after filtering by cluster $sourceClusterName and source VM list"
Write-Host ""

Write-Host "Getting vCenters..."
$vCenterList = Get-vCenterList
$sourcevCenters = $vcenterList | Where { $_.primaryClusterLocation.name -eq $sourceClusterName }
$targetvCenters = $vcenterList | Where { $_.primaryClusterLocation.name -eq $targetClusterName }
Write-Host "Found the following source vCenters:"
$sourcevCenters.name
Write-Host "Found the following target vCenters:"
$targetvCenters.name
Write-Host ""

Write-Host "Getting source compute clusters..."
# Stores list of VMware compute clusters
$sourceComputeClusters = @()

# Loop through each vCenter to the Data Center level
foreach ($vc in $sourcevCenters) {
  # Check if there are Data Centers under the vCenter
  if ($vc.descendantConnection.edges.node.count -gt 0) {
    # Loop through each Data Center to get the Compute Cluster
    foreach ($dc in $vc.descendantConnection.edges.node) {
      if ($dc.objectType -eq 'VSphereDatacenter') {
        $computeCluster = Get-VMComputeCluster -vCenterDataCenterID $dc.id
        foreach ($item in $computeCluster) {
          if ($item.objectType -eq 'VSphereComputeCluster') {
            $computeClusterItem = [PSCustomObject]@{
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
            $sourceComputeClusters += $computeClusterItem
          }
        }
      }
    }
  }
}
Write-Host "Found the following target compute clusters:"
$sourceComputeClusters.computeClusterName
Write-Host ""

Write-Host "Getting target compute clusters..."
# Stores list of VMware compute clusters
$targetComputeClusters = @()

# Loop through each vCenter to the Data Center level
foreach ($vc in $targetvCenters) {
  # Check if there are Data Centers under the vCenter
  if ($vc.descendantConnection.edges.node.count -gt 0) {
    # Loop through each Data Center to get the Compute Cluster
    foreach ($dc in $vc.descendantConnection.edges.node) {
      if ($dc.objectType -eq 'VSphereDatacenter') {
        $computeCluster = Get-VMComputeCluster -vCenterDataCenterID $dc.id
        foreach ($item in $computeCluster) {
          if ($item.objectType -eq 'VSphereComputeCluster') {
            $computeClusterItem = [PSCustomObject]@{
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
            $targetComputeClusters += $computeClusterItem
          }
        }
      }
    }
  }
}
Write-Host "Found the following target compute clusters:"
$targetComputeClusters.computeClusterName
Write-Host ""

Write-Host "Getting source storage datastore clusters..."
$sourceDatastoreClusters = Get-vmDataStores -rubrikClusterID $sourceClusterID
$sourceDatastores = $sourceDatastoreClusters.descendantConnection.edges.node | Where { $_.objectType -eq 'VSphereDatastore' }
Write-Host "Found the following source datastore clusters:"
$sourceDatastoreClusters.name
Write-Host ""
Write-Host "Getting target storage datastore clusters..."
$targetDatastoreClusters = Get-vmDataStores -rubrikClusterID $targetClusterID
$targetDatastores = $targetDatastoreClusters.descendantConnection.edges.node | Where { $_.objectType -eq 'VSphereDatastore' }
Write-Host "Found the following source datastore clusters:"
$targetDatastoreClusters.name

# Containst list of source VMs with all human readable and UIDs
$sourceVMDetailList = @()

# Builds a list of VMs with their source details
foreach ($vm in $sourceVMs) {
  foreach ($ds in $vm.newestsnapshot.cdmWorkloadSnapshot.subObjs.subobj.vmwareVmSubObj) {
    $dsDetail = $sourceDatastores | Where { $_.id -eq $ds.currentDatastoreId }
    $dsCluster = $dsDetail.physicalPath | Where { $_.objectType -eq 'VSPHERE_DATASTORE_CLUSTER' }
    $ds | Add-Member -MemberType NoteProperty -Name "datastoreCluster" -Value $dsCluster.name
    $ds | Add-Member -MemberType NoteProperty -Name "datastoreClusterID" -Value $dsCluster.fid
  }
  $computeCluster = $vm.physicalPath | Where { $_.objectType -eq 'VSphereComputeCluster' }
  $vnets = $(Get-VMNetworks -computeClusterID $computeCluster.fid).descendantConnection.edges.node
  $resourceSpec = $vm.newestSnapshot.resourceSpec | ConvertFrom-Json | ConvertFrom-Json
  # Go through each NIC and add the VNET name
  foreach ($nic in $resourceSpec.NetworkInterfaces) {
    $vnetName = $vnets | Where { $_.moid -eq $resourceSpec.networkinterfaces.networkMoidOpt }
    $resourceSpec.networkinterfaces | Add-Member -MemberType NoteProperty -Name "sourceVnetName" -Value $vnetName.name
    $resourceSpec.networkinterfaces | Add-Member -MemberType NoteProperty -Name "sourceVnetID" -Value $vnetName.id
  }
  $sourceVMDetail = [PSCustomObject] @{
    "Name" = $vm.name
    "ID" = $vm.id
    "Cluster" = $vm.primaryClusterLocation.name
    "ClusterID" = $vm.primaryClusterLocation.id
    "ComputeCluster" = $computeCluster.name
    "ComputeClusterID" = $computeCluster.fid
    "NewestSnapshot" = $vm.newestSnapshot.date
    "NewestSnapshotID" = $vm.newestSnapshot.id
    "Datastores" = $vm.newestsnapshot.cdmWorkloadSnapshot.subObjs.subobj.vmwareVmSubObj
    "NetworkInterfaces" = $resourceSpec.NetworkInterfaces
  }
  $sourceVMDetailList += $sourceVMDetail
}

$targetList = @()

# Go through each Source VM and create Target resources
foreach ($vm in $sourceVMDetailList) {
  # Create Target resources for the Compute Cluster
  # If match is true, try to match Target Compute Cluster with Source Compute Cluster name
  if ($computeClusterMatch -eq $true) {
    $bpTargetComputeClusterName = $($targetComputeClusters |
        Where { $_.computeClusterName -eq $vm.computeCluster }).Name
    # If no match is found, use the default
    if ($bpTargetComputeCluster.count -eq 0 -or $bpTargetComputeCluster -eq $null) {
      $bpTargetComputeClusterName = $computeClusterDefault
    }
  } else {
    # If not trying to match names, then use the following rules
    if ($vm.name -match "SQL") {
      $bpTargetComputeClusterName = $computeSQLMatch
    } elseif ($vm.name -match "ORA") {
      $bpTargetComputeClusterName = $computeORAMatch
    } else {
      $bpTargetComputeClusterName = $computeClusterDefault
    }
  }
  # Get the Target Compute Cluster ID
  $bpTargetComputeClusterID = $($targetComputeClusters |
      Where { $_.computeClusterName -eq $vm.computeCluster }).computeclusterID
  # Get a list of Target VNETs based on Target Compute Cluster
  $targetVnets = $(Get-VMNetworks -computeClusterID $bpTargetComputeClusterID).descendantConnection.edges.node
  # For each NIC on the VM, try to match the VNET Name
  foreach ($nic in $vm.NetworkInterfaces) {
    $bpTargetVnet = $targetVnets | Where { $_.name -eq $nic.sourceVnetName }
    $nic | Add-Member -MemberType NoteProperty -Name "targetVnetMoid" -Value $bpTargetVnet.moid
    $nic | Add-Member -MemberType NoteProperty -Name "targetVnetName" -Value $bpTargetVnet.name
    $nic | Add-Member -MemberType NoteProperty -Name "targetVnetID" -Value $bpTargetVnet.id
  }
  # Find the datastore in the Mapping List
  $sourceDatastoreClusterName = $vm.datastores.datastoreCluster
  $targetDatastoreClusterName = $datastoreClustersMapping."$sourceDatastoreClusterName"
  # If Datastore Cluster mapping is not found, use the default
  if ($targetDatastoreClusterName -eq 0 -or $targetDatastoreClusterName -eq $null) {
    $targetDatastoreClusterName = $datastoreClusterDefault
  }
  $targetDatastoreCluster = $targetDatastoreClusters | Where { $_.name -eq $targetDatastoreClusterName }
  $targetItem = [PSCustomObject] @{
    "Name" = $vm.name
    "ID" = $vm.id
    "TargetComputeCluster" = $bpTargetComputeCluster
    "TargetComputeID" = $bpTargetComputeClusterID
    "TargetNetworkInterfaces" = $vm.NetworkInterfaces
    "TargetDatastoreClusterName" = $targetDatastoreCluster.name
    "TargetDatastoreClusterID" = $targetDatastoreCluster.id
    "TargetDatastoreClusterCapacity" = $targetDatastoreCluster.capacity
    "TargetDatastoreClusterFreeSpace" = $targetDatastoreCluster.freeSpace
  }
  $targetList += $targetItem
}
#>
