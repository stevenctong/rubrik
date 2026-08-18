<#
.SYNOPSIS
This script outputs all VMware VMDK info for VMs with at least one backup to a CSV.

.DESCRIPTION
This script outputs all VMware VMDK info for VMs with at least one backup to a CSV.
Fetches both primary and replica (replicated) VM objects so the user can choose
which cluster to recover from. Includes user-editable columns: Convert, CreateOnly,
BootDisk, DriveLetter, tgtVMName, DiskSuffix, per-VM Azure settings, and
post-recovery action columns (sourceHostname, targetRbsWinHost, sourceFlrDrive,
targetFlrDrive, srcSqlInstance, tgtSqlInstance, sqlDataPath, sqlLogPath). On re-run,
user-edited values are merged forward from the previous CSV.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 5/21/25
Updated: 8/18/26

Requires PowerShell 7+.

.PARAMETER RscServiceAccountJson
File path to the RSC Service Account JSON file.

.PARAMETER csvOutputPrefix
Prefix for the output CSV file. A timestamp is appended automatically.

.PARAMETER RecoveryCluster
Filter the CSV output to a specific Rubrik cluster name. Both primary and
replica objects are fetched from RSC, but only rows matching this cluster
name are written to the CSV. If omitted, all clusters are included.

.PARAMETER SkipMerge
Skip merging user-edited columns from a previous CSV. By default, the script
looks for the latest existing CSV matching the prefix and carries forward
Convert, CreateOnly, BootDisk, DriveLetter, tgtVMName, DiskSuffix, and
per-VM Azure settings.

.EXAMPLE
./Get-RubrikVMDKList.ps1 -RscServiceAccountJson './rsc-service-account.json'
Runs the script and outputs all primary + replica VMs to a CSV

.EXAMPLE
./Get-RubrikVMDKList.ps1 -RscServiceAccountJson './rsc-service-account.json' -RecoveryCluster 'cluster-dr-01'
Outputs only VMs with snapshots on the specified cluster (primary or replica)

.EXAMPLE
./Get-RubrikVMDKList.ps1 -RscServiceAccountJson './rsc-service-account.json' -SkipMerge
Runs the script and outputs a fresh CSV without merging previous values

#>

param (
  [CmdletBinding()]
  # File path to the RSC Service Account JSON
  [Parameter(Mandatory=$false)]
  [string]$RscServiceAccountJson = '',
  # Prefix for the output CSV file
  [Parameter(Mandatory=$false)]
  [string]$csvOutputPrefix = './rubrik_vm_list',
  # Filter CSV output to a specific Rubrik cluster name
  [Parameter(Mandatory=$false)]
  [string]$RecoveryCluster = '',
  # Skip merging user-edited columns from a previous CSV
  [switch]$SkipMerge
)

$date = Get-Date

if ([string]::IsNullOrEmpty($RscServiceAccountJson)) {
  Write-Host ""
  Write-Host "Usage: ./Get-RubrikVMDKList.ps1" -ForegroundColor Cyan
  Write-Host "  -RscServiceAccountJson <path to RSC service account JSON>"
  Write-Host "  [-csvOutputPrefix <output file prefix>] (default: ./rubrik_vm_list)"
  Write-Host "  [-RecoveryCluster <cluster name>] (filter output to a specific cluster)"
  Write-Host "  [-SkipMerge] (skip merging from previous CSV)"
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
      ... on HierarchyObject {
        id
        name
        effectiveSlaDomain {
          id
          name
        }
      }
      ... on CdmHierarchyObject {
        cluster {
          id
          name
        }
      }
      snapshotConnection {
        edges {
          node {
            id
            date
          }
        }
      }
      vsphereVirtualDisks {
        edges {
          node {
            fileName
            size
            excludeFromSnapshots
          }
        }
      }
    }
  }
  pageInfo {
    endCursor
    hasNextPage
  }
  count
}
}'

$baseFilters = @(
  @{ "field" = "IS_RELIC"; "texts" = @("false") },
  @{ "field" = "IS_ACTIVE"; "texts" = @("true") },
  @{ "field" = "IS_ACTIVE_AMONG_DUPLICATED_OBJECTS"; "texts" = @("false") }
)

$filterSets = @(
  @{ Label = 'Primary'; IsReplicated = 'false' },
  @{ Label = 'Replica'; IsReplicated = 'true' }
)

### RSC GQL Queries - END ###

###### RUBRIK AUTHENTICATION - BEGIN ######

if ($PSVersionTable.PSVersion.Major -lt 7) {
  throw "PowerShell 7+ is required. Current version: $($PSVersionTable.PSVersion)"
}

Write-Host "Reading Service Account file: $RscServiceAccountJson"
try {
  $serviceAccountFile = Get-Content -Path "$RscServiceAccountJson" -ErrorAction Stop | ConvertFrom-Json
} catch {
  throw "Failed to read Service Account JSON at '$RscServiceAccountJson': $($_.Exception.Message)"
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

Write-Host "Getting a list of all VMs (primary + replica)..."
$vmList = @()
$primaryCount = 0
$replicaCount = 0

foreach ($fs in $filterSets) {
  $varGetVMs = @{
    "first" = 1000
    "filter" = $baseFilters + @(
      @{ "field" = "IS_REPLICATED"; "texts" = @($fs.IsReplicated) }
    )
    "sortBy" = "NAME"
    "sortOrder" = "ASC"
  }
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
    foreach ($node in $vmInventory.edges.node) {
      $node | Add-Member -NotePropertyName '_SourceType' -NotePropertyValue $fs.Label
      $vmList += $node
    }
    $afterCursor = $vmInventory.pageInfo.endCursor
  } while ($vmInventory.pageInfo.hasNextPage)
}

# Filter VMs by those that have at least one backup
$vmList = $vmList | Where-Object { $_.SnapshotConnection.edges.node -ne $null }
$primaryCount = @($vmList | Where-Object { $_._SourceType -eq 'Primary' }).Count
$replicaCount = @($vmList | Where-Object { $_._SourceType -eq 'Replica' }).Count
Write-Host "Found $primaryCount primary + $replicaCount replica VM(s) ($($vmList.Count) total) with at least one backup" -ForegroundColor Green

# Check for a previous CSV to merge in Convert and DriveLetter values
$previousData = @{}
if (-not $SkipMerge) {
  $prefixDir = Split-Path -Parent $csvOutputPrefix
  if ([string]::IsNullOrEmpty($prefixDir)) { $prefixDir = '.' }
  $prefixName = Split-Path -Leaf $csvOutputPrefix
  $previousCsvFiles = Get-ChildItem -Path $prefixDir -Filter "$prefixName-*.csv" -File |
    Sort-Object Name -Descending
  if ($previousCsvFiles.Count -gt 0) {
    $previousCsvPath = $previousCsvFiles[0].FullName
    Write-Host "Previous CSV found: $($previousCsvFiles[0].Name) - merging user-edited columns" -ForegroundColor Yellow
    $previousCsv = Import-CSV -Path $previousCsvPath
    foreach ($row in $previousCsv) {
      $key = "$($row.vmdkFile)|$($row.Cluster)"
      $previousData[$key] = @{
        Convert = $row.Convert
        CreateOnly = $row.CreateOnly
        DriveLetter = $row.DriveLetter
        BootDisk = $row.BootDisk
        tgtVMName = $row.tgtVMName
        DiskSuffix = $row.DiskSuffix
        ResourceGroup = $row.ResourceGroup
        VNetRG = $row.VNetRG
        VNetName = $row.VNetName
        SubnetName = $row.SubnetName
        NsgRG = $row.NsgRG
        NsgName = $row.NsgName
        VMSize = $row.VMSize
        ManagedDiskSku = $row.ManagedDiskSku
        sourceHostname = $row.sourceHostname
        targetRbsWinHost = $row.targetRbsWinHost
        sourceFlrDrive = $row.sourceFlrDrive
        targetFlrDrive = $row.targetFlrDrive
        srcSqlInstance = $row.srcSqlInstance
        tgtSqlInstance = $row.tgtSqlInstance
        sqlDataPath = $row.sqlDataPath
        sqlLogPath = $row.sqlLogPath
      }
    }
  }
}

$vmOutput = @()
foreach ($vm in $vmList) {
  foreach ($vmDisk in $vm.VsphereVirtualDisks.edges.node) {
    $mergeKey = "$($vmDisk.FileName)|$($vm.Cluster.Name)"
    $mergedConvert = ""
    $mergedCreateOnly = ""
    $mergedDriveLetter = ""
    $mergedBootDisk = ""
    $mergedTgtVMName = ""
    $mergedDiskSuffix = ""
    $mergedResourceGroup = ""
    $mergedVNetRG = ""
    $mergedVNetName = ""
    $mergedSubnetName = ""
    $mergedNsgRG = ""
    $mergedNsgName = ""
    $mergedVMSize = ""
    $mergedManagedDiskSku = ""
    $mergedSourceHostname = ""
    $mergedTargetRbsWinHost = ""
    $mergedSourceFlrDrive = ""
    $mergedTargetFlrDrive = ""
    $mergedSrcSqlInstance = ""
    $mergedTgtSqlInstance = ""
    $mergedSqlDataPath = ""
    $mergedSqlLogPath = ""
    if ($previousData.ContainsKey($mergeKey)) {
      $mergedConvert = $previousData[$mergeKey].Convert
      $mergedCreateOnly = $previousData[$mergeKey].CreateOnly
      $mergedDriveLetter = $previousData[$mergeKey].DriveLetter
      $mergedBootDisk = $previousData[$mergeKey].BootDisk
      $mergedTgtVMName = $previousData[$mergeKey].tgtVMName
      $mergedDiskSuffix = $previousData[$mergeKey].DiskSuffix
      $mergedResourceGroup = $previousData[$mergeKey].ResourceGroup
      $mergedVNetRG = $previousData[$mergeKey].VNetRG
      $mergedVNetName = $previousData[$mergeKey].VNetName
      $mergedSubnetName = $previousData[$mergeKey].SubnetName
      $mergedNsgRG = $previousData[$mergeKey].NsgRG
      $mergedNsgName = $previousData[$mergeKey].NsgName
      $mergedVMSize = $previousData[$mergeKey].VMSize
      $mergedManagedDiskSku = $previousData[$mergeKey].ManagedDiskSku
      $mergedSourceHostname = $previousData[$mergeKey].sourceHostname
      $mergedTargetRbsWinHost = $previousData[$mergeKey].targetRbsWinHost
      $mergedSourceFlrDrive = $previousData[$mergeKey].sourceFlrDrive
      $mergedTargetFlrDrive = $previousData[$mergeKey].targetFlrDrive
      $mergedSrcSqlInstance = $previousData[$mergeKey].srcSqlInstance
      $mergedTgtSqlInstance = $previousData[$mergeKey].tgtSqlInstance
      $mergedSqlDataPath = $previousData[$mergeKey].sqlDataPath
      $mergedSqlLogPath = $previousData[$mergeKey].sqlLogPath
    }
    if ([string]::IsNullOrEmpty($mergedTgtVMName)) {
      $mergedTgtVMName = $vm.Name
    }
    if ([string]::IsNullOrEmpty($mergedDiskSuffix)) {
      $mergedDiskSuffix = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path $vmDisk.FileName -Leaf))
    }
    $vmDiskInfo = [PSCustomObject] @{
      "Convert" = $mergedConvert
      "CreateOnly" = $mergedCreateOnly
      "Name" = $vm.Name
      "SourceType" = $vm._SourceType
      "Excluded" = if ($vmDisk.excludeFromSnapshots) { "Y" } else { "" }
      "BootDisk" = $mergedBootDisk
      "DriveLetter" = $mergedDriveLetter
      "tgtVMName" = $mergedTgtVMName
      "DiskSuffix" = $mergedDiskSuffix
      "vmdkSizeGiB" = [math]::Round($vmDisk.Size / 1073741824, 1)
      "vmdkSizeGB" = [math]::Round($vmDisk.Size / 1000000000, 1)
      "vmdkFile" = $vmDisk.FileName
      "Cluster" = $vm.Cluster.Name
      "ResourceGroup" = $mergedResourceGroup
      "VNetRG" = $mergedVNetRG
      "VNetName" = $mergedVNetName
      "SubnetName" = $mergedSubnetName
      "NsgRG" = $mergedNsgRG
      "NsgName" = $mergedNsgName
      "VMSize" = $mergedVMSize
      "ManagedDiskSku" = $mergedManagedDiskSku
      "sourceHostname" = $mergedSourceHostname
      "targetRbsWinHost" = $mergedTargetRbsWinHost
      "sourceFlrDrive" = $mergedSourceFlrDrive
      "targetFlrDrive" = $mergedTargetFlrDrive
      "srcSqlInstance" = $mergedSrcSqlInstance
      "tgtSqlInstance" = $mergedTgtSqlInstance
      "sqlDataPath" = $mergedSqlDataPath
      "sqlLogPath" = $mergedSqlLogPath
      "SLA" = $vm.EffectiveSlaDomain.Name
      "LatestBackupDate" = $vm.snapshotconnection.edges.node[-1].Date
      "ID" = $vm.Id
      "LatestBackupID" = $vm.snapshotconnection.edges.node[-1].Id
      "OldestBackupDate" = $vm.snapshotconnection.edges.node[0].Date
      "OldestBackupID" = $vm.snapshotconnection.edges.node[0].Id
      "Notes" = ""
    }
    $vmOutput += $vmDiskInfo
  }
}

if (-not [string]::IsNullOrEmpty($RecoveryCluster)) {
  $beforeCount = $vmOutput.Count
  $vmOutput = @($vmOutput | Where-Object { $_.Cluster -eq $RecoveryCluster })
  Write-Host "Filtered to cluster '$RecoveryCluster': $($vmOutput.Count) of $beforeCount row(s)" -ForegroundColor Yellow
  if ($vmOutput.Count -eq 0) {
    $allClusters = @($vmList | ForEach-Object { $_.Cluster.Name } | Sort-Object -Unique)
    Write-Host "No VMs found on cluster '$RecoveryCluster'. Available clusters:" -ForegroundColor Red
    foreach ($c in $allClusters) { Write-Host "  $c" }
  }
}

$csvOutput = "$($csvOutputPrefix)-$($date.ToString("yyyy-MM-dd_HHmm")).csv"
$vmOutput | Export-CSV -Path $csvOutput -NoTypeInformation
Write-Host "VMDK info output to: $csvOutput" -ForegroundColor Green
