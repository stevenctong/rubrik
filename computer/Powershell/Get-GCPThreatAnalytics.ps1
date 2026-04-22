# https://www.rubrik.com/api
<#
.SYNOPSIS
Queries RSC for GCP VM inventory and retrieves threat analytics (file delta)
metrics for snapshots near a specified point in time.

.DESCRIPTION
This script performs the following steps:
1. Gets a list of GCP VM inventory from RSC
2. For each VM, finds snapshots near a specified point in time:
   - 1 snapshot taken right after the given date
   - N snapshots taken before the given date (configurable via -SnapshotsBefore)
3. For each snapshot, opens the threat analytics view (triggers indexing)
4. Polls until the index is ready
5. Retrieves file delta metrics: current snapshot, base snapshot, and counts
   for created, deleted, modified, suspicious files, and byte changes

Supports parallel processing of multiple VMs and multiple snapshots per VM.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 4/21/26
Updated: 4/21/26

The script requires communication to RSC via outbound HTTPS (TCP 443).

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only role
** Download the service account JSON
** Define the service account JSON path in the script: $RscServiceAccountJson

Update this variable to point to your RSC Service Account JSON:
- $RscServiceAccountJson

.PARAMETER PointInTime
The target date/time to find snapshots near. Format: '2026-04-20 21:00'
Treated as Pacific Time (PT). Converted to UTC internally for API comparisons.

.PARAMETER VMNameFilter
Optional substring filter for GCP VM names. Only VMs whose name contains
this string will be processed.

.PARAMETER SnapshotsBefore
Number of snapshots to look back before the target time. Default: 2.

.PARAMETER MaxConcurrentVMs
Maximum number of VMs to process in parallel. Default: 5.

.PARAMETER MaxRetries
Maximum number of retries when waiting for threat analytics indexing.
Default: 30.

.PARAMETER RetryIntervalSec
Seconds to wait between index readiness checks. Default: 10.

.PARAMETER RscServiceAccountJson
File path to the RSC Service Account JSON. Default: './rsc-gaia.json'.

.EXAMPLE
./Get-GCPThreatAnalytics.ps1 -PointInTime '2026-04-20 21:00'
Gets threat analytics for all GCP VMs, using snapshots near April 20, 2026 9pm PT.

.EXAMPLE
./Get-GCPThreatAnalytics.ps1 -PointInTime '2026-04-20 21:00' -VMNameFilter 'gcp-l1' -MaxConcurrentVMs 3
Processes only VMs matching 'gcp-l1', up to 3 in parallel.

.EXAMPLE
./Get-GCPThreatAnalytics.ps1 -PointInTime '2026-04-20 21:00' -SnapshotsBefore 5
Looks back 5 snapshots before the target time instead of the default 2.

#>

### VARIABLES - BEGIN ###

param (
  [CmdletBinding()]
  # Target point in time to find snapshots near (Pacific Time)
  # Format: '2026-04-20 21:00'
  [Parameter(Mandatory=$false)]
  [string]$PointInTime = '',
  # Optional filter for VM names (substring match)
  [Parameter(Mandatory=$false)]
  [string]$VMNameFilter = '',
  # Number of snapshots to look back before the target time
  [Parameter(Mandatory=$false)]
  [int]$SnapshotsBefore = 2,
  # Max VMs to process in parallel
  [Parameter(Mandatory=$false)]
  [int]$MaxConcurrentVMs = 5,
  # Max retries waiting for indexing
  [Parameter(Mandatory=$false)]
  [int]$MaxRetries = 30,
  # Seconds between index readiness checks
  [Parameter(Mandatory=$false)]
  [int]$RetryIntervalSec = 10,
  # File path to the RSC Service Account JSON
  [Parameter(Mandatory=$false)]
  [string]$RscServiceAccountJson = "./rsc-gaia.json"
)

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# CSV output prefix - filename and timestamp auto-appended
$csvOutputPrefix = "./rubrik_gcp_threat_analytics"
$csvOutput = "$($csvOutputPrefix)-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

### VARIABLES - END ###

# Show usage if no parameters provided
if ([string]::IsNullOrEmpty($PointInTime)) {
  Write-Host ""
  Write-Host "Usage: ./Get-GCPThreatAnalytics.ps1 -PointInTime '2026-04-20 21:00'" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "Parameters:" -ForegroundColor Yellow
  Write-Host "  -PointInTime          Target datetime (Pacific Time) to find snapshots near. Format: '2026-04-20 21:00'"
  Write-Host "  -VMNameFilter         (Optional) Substring filter for VM names"
  Write-Host "  -SnapshotsBefore      (Optional) Number of snapshots to look back (default: 2)"
  Write-Host "  -MaxConcurrentVMs     (Optional) Max VMs to process in parallel (default: 5)"
  Write-Host "  -MaxRetries           (Optional) Max retries for index readiness (default: 30)"
  Write-Host "  -RetryIntervalSec     (Optional) Seconds between index checks (default: 10)"
  Write-Host ""
  Write-Host "Examples:" -ForegroundColor Yellow
  Write-Host "  ./Get-GCPThreatAnalytics.ps1 -PointInTime '2026-04-20 21:00'"
  Write-Host "  ./Get-GCPThreatAnalytics.ps1 -PointInTime '2026-04-20 21:00' -VMNameFilter 'gcp-l1'"
  Write-Host "  ./Get-GCPThreatAnalytics.ps1 -PointInTime '2026-04-20 21:00' -MaxConcurrentVMs 3"
  Write-Host ""
  exit
}

# Parse and validate PointInTime (input is Pacific Time)
$pacificTZ = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/Los_Angeles")

try {
  $parsedTime = [datetime]::ParseExact($PointInTime, 'yyyy-MM-dd HH:mm', $null)
  $targetTimeUTC = [System.TimeZoneInfo]::ConvertTimeToUtc($parsedTime, $pacificTZ)
} catch {
  Write-Error "Invalid PointInTime format. Use: '2026-04-20 21:00'"
  exit 1
}

Write-Host "Target point in time: $($parsedTime.ToString('yyyy-MM-dd HH:mm')) PT ($($targetTimeUTC.ToString('yyyy-MM-dd HH:mm')) UTC)" -ForegroundColor Cyan

###### RUBRIK AUTHENTICATION - BEGIN ######

Write-Host ""
Write-Host "Reading Service Account file: $RscServiceAccountJson"
try {
  $serviceAccountFile = Get-Content -Path "$RscServiceAccountJson" -ErrorAction Stop | ConvertFrom-Json
} catch {
  Write-Error "Failed to read Service Account JSON at '$RscServiceAccountJson': $($_.Exception.Message)"
  exit 1
}

$missingFields = @()
if ($null -eq $serviceAccountFile.client_id) { $missingFields += 'client_id' }
if ($null -eq $serviceAccountFile.client_secret) { $missingFields += 'client_secret' }
if ($null -eq $serviceAccountFile.access_token_uri) { $missingFields += 'access_token_uri' }

if ($missingFields.Count -gt 0) {
  Write-Error "Service Account JSON is missing required fields: $($missingFields -join ', ')"
  exit 1
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
  Write-Error "RSC authentication failed: $($_.Exception.Message)"
  exit 1
}

if ($null -eq $response.access_token) {
  Write-Error "RSC returned a response but no access token was included."
  exit 1
}

$rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")

$global:rubrikConnection = @{
  accessToken = $response.access_token
  bearer      = "Bearer $($response.access_token)"
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

###### FUNCTIONS - BEGIN ######

# Function to invoke RSC GraphQL queries with error handling
function Invoke-RscQuery {
  param (
    [string]$Endpoint,
    [hashtable]$Headers,
    [string]$OperationName,
    [string]$Query,
    [hashtable]$Variables = @{}
  )
  $body = @{
    operationName = $OperationName
    query         = $Query
    variables     = $Variables
  } | ConvertTo-Json -Depth 20
  try {
    $result = Invoke-RestMethod -Method POST -Uri $Endpoint -Body $body -Headers $Headers -ErrorAction Stop
    return $result
  } catch {
    Write-Warning "GraphQL query '$OperationName' failed: $($_.Exception.Message)"
    return $null
  }
}

###### FUNCTIONS - END ######

###### GRAPHQL QUERIES - BEGIN ######

$mutationWarmCache = '
mutation WarmCloudNativeIndexCacheMutation($workloadId: UUID!) {
  warmCloudNativeIndexCache(workloadId: $workloadId)
}
'

$queryGCPInstancesList = '
query GCPInstancesListQuery($first: Int, $after: String, $sortBy: GcpNativeGceInstanceSortFields, $sortOrder: SortOrder, $filters: GcpNativeGceInstanceFilters) {
  gcpNativeGceInstances(
    first: $first
    after: $after
    sortBy: $sortBy
    sortOrder: $sortOrder
    gceInstanceFilters: $filters
  ) {
    edges {
      cursor
      node {
        id
        nativeName
        region
        zone
        machineType
        effectiveSlaDomain {
          id
          name
          __typename
        }
        gcpProjectDetails {
          nativeName
          nativeId
          __typename
        }
        isExocomputeConfigured
        fileIndexingStatus
        __typename
      }
      __typename
    }
    pageInfo {
      endCursor
      hasNextPage
      __typename
    }
    __typename
  }
}
'

$queryEligibleSnapshots = '
query CloudNativeFileRecoveryEligibleSnapshotsQuery($workloadId: UUID!) {
  allCloudNativeFileRecoveryEligibleSnapshots(workloadId: $workloadId)
}
'

$querySnapshotList = '
query SnapshotListQuery($snappableId: String!, $first: Int, $after: String, $sortOrder: SortOrder) {
  snapshotsListConnection: snapshotOfASnappableConnection(
    workloadId: $snappableId
    first: $first
    after: $after
    sortOrder: $sortOrder
  ) {
    edges {
      cursor
      node {
        id
        date
        __typename
      }
      __typename
    }
    pageInfo {
      endCursor
      hasNextPage
      __typename
    }
    __typename
  }
}
'

$queryPolarisSnapshot = '
query RadarPolarisSnapshotQuery($id: UUID!) {
  polarisSnapshot(snapshotFid: $id) {
    id
    date
    sequenceNumber
    isQuarantined
    isQuarantineProcessing
    isAnomaly
    __typename
  }
}
'

$queryDeltaSnapshotDetails = '
query DeltaSnapshotDetailsQuery($snapshotId: UUID!) {
  snapshotFilesDeltaV2(
    first: 0
    path: ""
    snapshotFid: $snapshotId
  ) {
    previousSnapshot {
      id
      date
      isIndexed
      isUnindexable
      isOnDemandSnapshot
      sequenceNumber
      __typename
    }
    currentSnapshot {
      isQuarantined
      isQuarantineProcessing
      __typename
    }
    __typename
  }
}
'

$queryRadarBrowseList = '
query RadarInvestigationBrowseListQuery($snapshotId: UUID!, $path: String!, $first: Int, $after: String, $filter: SnapshotDeltaFilterInput) {
  snapshotFilesDeltaV2(
    snapshotFid: $snapshotId
    path: $path
    first: $first
    after: $after
    filter: $filter
  ) {
    edges {
      cursor
      node {
        file {
          absolutePath
          filename
          fileMode
          size
          lastModified
          __typename
        }
        childrenDeltas {
          deltaType
          deltaAmount
          __typename
        }
        selfDeltas {
          deltaType
          deltaAmount
          __typename
        }
        __typename
      }
      __typename
    }
    pageInfo {
      endCursor
      hasNextPage
      __typename
    }
    __typename
  }
}
'

###### GRAPHQL QUERIES - END ######

###### STEP 1: GET GCP VM INVENTORY ######

Write-Host ""
Write-Host "Getting GCP VM inventory..." -ForegroundColor Cyan

$gcpVMs = [System.Collections.Generic.List[object]]::new()
$hasNextPage = $true
$afterCursor = $null

while ($hasNextPage) {
  $variables = @{
    first     = 50
    sortBy    = "GCP_INSTANCE_NATIVE_NAME"
    sortOrder = "ASC"
    filters   = @{
      relicFilter = @{ relic = $false }
    }
  }
  if ($null -ne $afterCursor) {
    $variables['after'] = $afterCursor
  }

  $result = Invoke-RscQuery -Endpoint $endpoint -Headers $headers `
    -OperationName "GCPInstancesListQuery" `
    -Query $queryGCPInstancesList -Variables $variables

  if ($null -eq $result -or $null -eq $result.data) {
    Write-Error "Failed to retrieve GCP VM list"
    exit 1
  }

  $edges = $result.data.gcpNativeGceInstances.edges
  foreach ($edge in $edges) {
    $vm = $edge.node
    # Apply name filter if specified
    if (-not [string]::IsNullOrEmpty($VMNameFilter)) {
      if ($vm.nativeName -notlike "*$VMNameFilter*") {
        continue
      }
    }
    $gcpVMs.Add($vm)
  }

  $pageInfo = $result.data.gcpNativeGceInstances.pageInfo
  $hasNextPage = $pageInfo.hasNextPage
  $afterCursor = $pageInfo.endCursor
}

Write-Host "Found $($gcpVMs.Count) GCP VMs" -ForegroundColor Green

if ($gcpVMs.Count -eq 0) {
  Write-Host "No GCP VMs found matching criteria. Exiting." -ForegroundColor Yellow
  exit
}

# Display VM list
Write-Host ""
Write-Host "VM list:" -ForegroundColor Yellow
foreach ($vm in $gcpVMs) {
  $slaName = if ($vm.effectiveSlaDomain) { $vm.effectiveSlaDomain.name } else { "Unprotected" }
  $projectName = if ($vm.gcpProjectDetails) { $vm.gcpProjectDetails.nativeName } else { "N/A" }
  Write-Host "  $($vm.nativeName) | Project: $projectName | SLA: $slaName | Region: $($vm.region)"
}

###### STEP 2: GET SNAPSHOTS FOR EACH VM & SELECT NEAR TARGET TIME ######

Write-Host ""
Write-Host "Getting snapshots for each VM near target time: $($parsedTime.ToString('yyyy-MM-dd HH:mm')) PT ($($targetTimeUTC.ToString('yyyy-MM-dd HH:mm')) UTC)" -ForegroundColor Cyan

$workItems = [System.Collections.Generic.List[hashtable]]::new()

foreach ($vm in $gcpVMs) {
  $vmName = $vm.nativeName
  $vmId = $vm.id
  $projectName = if ($vm.gcpProjectDetails) { $vm.gcpProjectDetails.nativeName } else { "N/A" }
  $slaName = if ($vm.effectiveSlaDomain) { $vm.effectiveSlaDomain.name } else { "Unprotected" }

  Write-Host "[$vmName] Getting snapshots..." -ForegroundColor Cyan

  # Get all snapshots for this VM using snapshotOfASnappableConnection
  $snapshots = [System.Collections.Generic.List[object]]::new()
  $hasNextSnap = $true
  $snapCursor = $null

  while ($hasNextSnap) {
    $snapVars = @{
      snappableId = $vmId
      first       = 100
      sortOrder   = "DESC"
    }
    if ($null -ne $snapCursor) { $snapVars['after'] = $snapCursor }

    $snapResult = Invoke-RscQuery -Endpoint $endpoint -Headers $headers `
      -OperationName "SnapshotListQuery" `
      -Query $querySnapshotList -Variables $snapVars

    if ($null -eq $snapResult -or $null -eq $snapResult.data -or
        $null -eq $snapResult.data.snapshotsListConnection) {
      Write-Warning "[$vmName] No snapshot data returned"
      break
    }

    $edges = $snapResult.data.snapshotsListConnection.edges
    foreach ($edge in $edges) {
      $snapshots.Add($edge.node)
    }

    $pi = $snapResult.data.snapshotsListConnection.pageInfo
    $hasNextSnap = $pi.hasNextPage
    $snapCursor = $pi.endCursor
  }

  Write-Host "[$vmName] Found $($snapshots.Count) snapshots" -ForegroundColor Green

  if ($snapshots.Count -eq 0) {
    Write-Host "[$vmName] No snapshots found, skipping" -ForegroundColor Yellow
    continue
  }

  # Get file-recovery-eligible snapshot IDs (filters out archival copies)
  $eligibleResult = Invoke-RscQuery -Endpoint $endpoint -Headers $headers `
    -OperationName "CloudNativeFileRecoveryEligibleSnapshotsQuery" `
    -Query $queryEligibleSnapshots -Variables @{ workloadId = $vmId }
  $eligibleIds = @()
  if ($null -ne $eligibleResult.data) {
    $eligibleIds = $eligibleResult.data.allCloudNativeFileRecoveryEligibleSnapshots
  }
  Write-Host "[$vmName] $($eligibleIds.Count) file-recovery-eligible snapshots" -ForegroundColor Green

  # Helper to parse API date string to UTC DateTime
  # API returns dates like "2026-04-20T00:00:33.000Z"
  function ConvertTo-UtcDateTime($dateVal) {
    # API dates are always UTC. PowerShell's Invoke-RestMethod auto-parses ISO 8601
    # dates but may set Kind to Local or Unspecified, which breaks .ToUniversalTime().
    # Handle all three Kind states explicitly.
    if ($dateVal -is [datetime]) {
      switch ($dateVal.Kind) {
        'Utc'         { return $dateVal }
        'Local'       { return $dateVal.ToUniversalTime() }
        'Unspecified' { return [DateTime]::SpecifyKind($dateVal, [DateTimeKind]::Utc) }
      }
    }
    return [DateTimeOffset]::Parse($dateVal.ToString()).UtcDateTime
  }

  # Filter to only eligible snapshots (source copies, not archival)
  $eligibleSnapshots = $snapshots | Where-Object { $_.id -in $eligibleIds }

  # Sort snapshots by date (ascending)
  $sortedSnapshots = $eligibleSnapshots | Sort-Object { ConvertTo-UtcDateTime $_.date }

  # Find 1 snapshot after target time and N snapshots before target time
  $snapsAfter = $sortedSnapshots | Where-Object { (ConvertTo-UtcDateTime $_.date) -gt $targetTimeUTC } | Select-Object -First 1
  $snapsBefore = $sortedSnapshots | Where-Object { (ConvertTo-UtcDateTime $_.date) -le $targetTimeUTC } |
    Sort-Object { ConvertTo-UtcDateTime $_.date } -Descending | Select-Object -First $SnapshotsBefore

  if ($null -ne $snapsAfter) {
    $snapsAfterUTC = ConvertTo-UtcDateTime $snapsAfter.date
    $snapsAfterPT = [System.TimeZoneInfo]::ConvertTimeFromUtc($snapsAfterUTC, $pacificTZ)
    $workItems.Add(@{
      VMName = $vmName; VMId = $vmId; Project = $projectName; SLA = $slaName
      Region = $vm.region; SnapshotId = $snapsAfter.id
      SnapshotDatePT = $snapsAfterPT.ToString('yyyy-MM-dd HH:mm:ss')
      Label = "After"
    })
  }
  if ($null -ne $snapsBefore) {
    $beforeArr = @($snapsBefore)
    for ($i = 0; $i -lt $beforeArr.Count; $i++) {
      $label = "Before-$($i + 1)"
      $beforeUTC = ConvertTo-UtcDateTime $beforeArr[$i].date
      $beforePT = [System.TimeZoneInfo]::ConvertTimeFromUtc($beforeUTC, $pacificTZ)
      $workItems.Add(@{
        VMName = $vmName; VMId = $vmId; Project = $projectName; SLA = $slaName
        Region = $vm.region; SnapshotId = $beforeArr[$i].id
        SnapshotDatePT = $beforePT.ToString('yyyy-MM-dd HH:mm:ss')
        Label = $label
      })
    }
  }

  $vmWorkCount = ($workItems | Where-Object { $_.VMName -eq $vmName }).Count
  Write-Host "[$vmName] Selected $vmWorkCount snapshots near target time" -ForegroundColor Green
}

Write-Host ""
Write-Host "Total work items: $($workItems.Count) snapshots across $($gcpVMs.Count) VMs" -ForegroundColor Cyan
$sortedWorkItems = $workItems | Sort-Object { $_.VMName }, { $_.SnapshotDatePT }
foreach ($w in $sortedWorkItems) {
  Write-Host "  [$($w.VMName)] $($w.Label): $($w.SnapshotDatePT) (ID: $($w.SnapshotId))" -ForegroundColor Gray
}

###### STEP 3-6: PROCESS ALL SNAPSHOTS IN PARALLEL ######

# Throttle to MaxConcurrentVMs * (1 after + N before snapshots per VM)
$throttleLimit = [Math]::Max(1, [Math]::Min($workItems.Count, $MaxConcurrentVMs * ($SnapshotsBefore + 1)))

if ($workItems.Count -eq 0) {
  Write-Host ""
  Write-Host "No snapshots selected for processing. Exiting." -ForegroundColor Yellow
  exit
}

Write-Host ""
Write-Host "Processing $($workItems.Count) snapshots with throttle limit: $throttleLimit" -ForegroundColor Cyan

$allResults = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
$completedCount = [ref]0
$totalCount = $workItems.Count

$workItems | ForEach-Object -ThrottleLimit $throttleLimit -Parallel {
  $item = $_
  $ep = $using:endpoint
  $hdr = $using:headers
  $qBrowse = $using:queryRadarBrowseList
  $qDeltaDetails = $using:queryDeltaSnapshotDetails
  $qPolarisSnap = $using:queryPolarisSnapshot
  $mWarmCache = $using:mutationWarmCache
  $maxR = $using:MaxRetries
  $retryInt = $using:RetryIntervalSec
  $resultsBag = $using:allResults
  $completed = $using:completedCount
  $total = $using:totalCount

  $vmName = $item.VMName
  $vmId = $item.VMId
  $snapId = $item.SnapshotId
  $snapDate = $item.SnapshotDatePT
  $label = $item.Label

  # Helper function for GraphQL calls within runspace
  function Invoke-RscQueryLocal {
    param (
      [string]$Ep,
      [hashtable]$Hdr,
      [string]$OpName,
      [string]$Qry,
      [hashtable]$Vars = @{}
    )
    $body = @{
      operationName = $OpName
      query         = $Qry
      variables     = $Vars
    } | ConvertTo-Json -Depth 20
    try {
      return Invoke-RestMethod -Method POST -Uri $Ep -Body $body -Headers $Hdr -ErrorAction Stop
    } catch {
      # Try to parse error response body (GraphQL returns errors as HTTP 200,
      # but some return HTTP 400+ with JSON body containing errors array)
      $errResponse = $_.ErrorDetails.Message
      if ($errResponse) {
        try {
          return $errResponse | ConvertFrom-Json
        } catch {}
      }
      return $null
    }
  }

  $resultObj = [PSCustomObject]@{
    VMName           = $vmName
    Project          = $item.Project
    Region           = $item.Region
    SnapComparison   = $label
    SnapshotDatePT     = $snapDate
    NODES_SUSPICIOUS = 0
    NODES_DELETED    = 0
    NODES_MODIFIED   = 0
    NODES_CREATED    = 0
    BYTES_CREATED    = 0
    BYTES_DELETED    = 0
    BYTES_MODIFIED   = 0
    IsAnomaly        = ''
    SLA              = $item.SLA
    SnapshotId       = $snapId
    Error            = ''
  }

  $tag = "[$vmName] $label ($snapDate)"

  # Step 0: Warm the cloud native index cache for this workload
  $warmResult = Invoke-RscQueryLocal -Ep $ep -Hdr $hdr `
    -OpName "WarmCloudNativeIndexCacheMutation" -Qry $mWarmCache `
    -Vars @{ workloadId = $vmId }

  # Step 1: Check snapshot anomaly status
  $polarisResult = Invoke-RscQueryLocal -Ep $ep -Hdr $hdr `
    -OpName "RadarPolarisSnapshotQuery" -Qry $qPolarisSnap `
    -Vars @{ id = $snapId }
  if ($null -ne $polarisResult.data -and $null -ne $polarisResult.data.polarisSnapshot) {
    $resultObj.IsAnomaly = $polarisResult.data.polarisSnapshot.isAnomaly
  }

  # Step 2: Trigger on-demand indexing via DeltaSnapshotDetailsQuery (first: 0)
  $triggerResult = Invoke-RscQueryLocal -Ep $ep -Hdr $hdr `
    -OpName "DeltaSnapshotDetailsQuery" -Qry $qDeltaDetails `
    -Vars @{ snapshotId = $snapId }

  # Step 3: Poll RadarInvestigationBrowseListQuery until index is ready
  $indexReady = $false
  $browseVars = @{
    snapshotId = $snapId
    path       = ""
    first      = 1000
    filter     = @{ deltaType = @() }
  }
  for ($retry = 0; $retry -lt $maxR; $retry++) {
    $browseResult = Invoke-RscQueryLocal -Ep $ep -Hdr $hdr `
      -OpName "RadarInvestigationBrowseListQuery" -Qry $qBrowse `
      -Vars $browseVars

    if ($null -eq $browseResult) {
      Write-Host "  $tag - Retry $($retry+1)/${maxR}: Index not ready, waiting ${retryInt}s..." -ForegroundColor Yellow
      Start-Sleep -Seconds $retryInt
      continue
    }

    # Success — index is ready and we have data
    if ($null -ne $browseResult.data -and $null -ne $browseResult.data.snapshotFilesDeltaV2) {
      $indexReady = $true

      # Sum childrenDeltas and selfDeltas across all root-level entries
      $edges = $browseResult.data.snapshotFilesDeltaV2.edges
      foreach ($edge in $edges) {
        foreach ($deltaList in @($edge.node.childrenDeltas, $edge.node.selfDeltas)) {
          if ($null -ne $deltaList) {
            foreach ($d in $deltaList) {
              switch ($d.deltaType) {
                "NODES_CREATED"    { $resultObj.NODES_CREATED += $d.deltaAmount }
                "NODES_DELETED"    { $resultObj.NODES_DELETED += $d.deltaAmount }
                "NODES_MODIFIED"   { $resultObj.NODES_MODIFIED += $d.deltaAmount }
                "NODES_SUSPICIOUS" { $resultObj.NODES_SUSPICIOUS += $d.deltaAmount }
                "BYTES_CREATED"    { $resultObj.BYTES_CREATED += $d.deltaAmount }
                "BYTES_DELETED"    { $resultObj.BYTES_DELETED += $d.deltaAmount }
                "BYTES_MODIFIED"   { $resultObj.BYTES_MODIFIED += $d.deltaAmount }
              }
            }
          }
        }
      }
      break
    }

    # Error response — check if it's the expected "index not found" (triggers indexing)
    if ($null -ne $browseResult.errors) {
      $errMsg = $browseResult.errors[0].message
      if ($errMsg -like "*Index not found*" -or $errMsg -like "*FAILED_PRECONDITION*" -or $errMsg -like "*unexpected internal error*") {
        Write-Host "  $tag - Retry $($retry+1)/${maxR}: Index not ready, waiting ${retryInt}s..." -ForegroundColor Yellow
        Start-Sleep -Seconds $retryInt
        continue
      } else {
        $resultObj.Error = $errMsg
        $resultsBag.Add($resultObj)
        $n = [System.Threading.Interlocked]::Increment($completed)
        Write-Host "  $tag - ERROR: $errMsg [$n/$total]" -ForegroundColor Red
        return
      }
    }

    # Data is null but no errors either
    Write-Host "  $tag - Retry $($retry+1)/${maxR}: Index not ready, waiting ${retryInt}s..." -ForegroundColor Yellow
    Start-Sleep -Seconds $retryInt
  }

  if (-not $indexReady) {
    $resultObj.Error = "Index not ready after $maxR retries"
    $resultsBag.Add($resultObj)
    $n = [System.Threading.Interlocked]::Increment($completed)
    Write-Host "  $tag - ERROR: Index not ready after $maxR retries [$n/$total]" -ForegroundColor Red
    return
  }

  $resultsBag.Add($resultObj)
  $n = [System.Threading.Interlocked]::Increment($completed)
  Write-Host "  $tag - Done [$n/$total] (Created: $($resultObj.NODES_CREATED), Deleted: $($resultObj.NODES_DELETED), Modified: $($resultObj.NODES_MODIFIED), Suspicious: $($resultObj.NODES_SUSPICIOUS))" -ForegroundColor Green
}

###### OUTPUT RESULTS ######

$results = $allResults.ToArray() | Sort-Object VMName, SnapComparison

if ($results.Count -eq 0) {
  Write-Host ""
  Write-Host "No results collected." -ForegroundColor Yellow
  exit
}

# Display summary table
Write-Host ""
Write-Host "===== THREAT ANALYTICS RESULTS =====" -ForegroundColor Cyan

$lastVM = ''
foreach ($r in $results) {
  # Add header break between VMs
  if ($r.VMName -ne $lastVM) {
    Write-Host ""
    Write-Host "--- $($r.VMName) ---" -ForegroundColor Cyan
    $lastVM = $r.VMName
  }
  Write-Host ""
  Write-Host "VM: $($r.VMName) | $($r.SnapComparison) | Date: $($r.SnapshotDatePT)" -ForegroundColor Yellow
  if ($r.Error) {
    Write-Host "  Error: $($r.Error)" -ForegroundColor Red
  } else {
    Write-Host "  " -NoNewline; Write-Host "Files: " -NoNewline -ForegroundColor White; Write-Host "Suspicious: $($r.NODES_SUSPICIOUS) | Deleted: $($r.NODES_DELETED) | Modified: $($r.NODES_MODIFIED) | Created: $($r.NODES_CREATED)"
    Write-Host "  " -NoNewline; Write-Host "Bytes: " -NoNewline -ForegroundColor White; Write-Host "Created: $($r.BYTES_CREATED) | Deleted: $($r.BYTES_DELETED) | Modified: $($r.BYTES_MODIFIED)"
    if ($r.IsAnomaly -eq $true) {
      Write-Host "  ** ANOMALY DETECTED **" -ForegroundColor Red
    }
  }
}

# Export to CSV - select columns in specified order, exclude Error column on success
$csvResults = $results | Select-Object VMName, Project, Region, SnapComparison, SnapshotDatePT, IsAnomaly,
  NODES_SUSPICIOUS, NODES_DELETED, NODES_MODIFIED, NODES_CREATED,
  BYTES_CREATED, BYTES_DELETED, BYTES_MODIFIED, SLA, SnapshotId
$csvResults | Export-Csv -Path $csvOutput -NoTypeInformation
Write-Host "Results exported to: $csvOutput" -ForegroundColor Green
Write-Host ""
