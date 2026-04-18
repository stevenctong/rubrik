# https://www.rubrik.com/api
<#
.SYNOPSIS
Interactive report manager for Rubrik CDM clusters using the local REST API — 
list, view, create, and delete custom reports.

.DESCRIPTION
Authenticates to a Rubrik CDM cluster using a RSC Service Account JSON file.
Then the script presents a persistent interactive loop that supports:

  Viewing reports:
    - Lists all reports with row number, name, status (color-coded), ID, and type.
    - Status is color-coded: Ready = green, Updating = yellow.
    - Reports that are currently Updating cannot be accessed; the list is redisplayed.
    - Enter a row number or Report ID to select a report.
    - Enter 'r' or 'refresh' to re-fetch the list. Press Enter to exit.

  Actions on a selected report:
    1. View charts    — fetches chart data via GET /report/{id}/chart, builds an HTML
                        file with Chart.js visualizations, and opens it in the browser.
                        Byte-based measures (storage, data transferred, etc.) are
                        auto-scaled to the appropriate unit (MB/GB/TB/PB).
    2. Export table data as CSV — requests a CSV export link via GET /report/{id}/csv_link and
                        downloads the CSV to a timestamped local file.
    3. Delete report  — prompts for confirmation, then calls DELETE /report/{id}.

  Creating a new report (enter 'new' at the list prompt):
    - Choose from 9 hardcoded report templates (sourced from CDM 9.2 User Guide).
    - Select Default mode: uses the template's default chart/table configuration,
      with optional date or snapshot range override.
    - Select Customize mode: interactively configure filters (date range, task types,
      task status, object types, compliance status, cluster location), chart type,
      chart attribute/measure, and table columns — all constrained to the valid
      options for the chosen template.
    - Creates the report shell via POST /report, then applies full configuration
      via PATCH /report/{id}. Displays the PATCH JSON body on both success and failure.
    - After creation, loops back to the report list.

  Output files:
    - HTML chart file : ./<htmlOutputPrefix>-<ReportName>-yyyy-MM-dd_HHmm.html
    - CSV table file  : ./<csvOutputPrefix>-<ReportName>-yyyy-MM-dd_HHmm.csv

.PARAMETER serviceAccountPath
Path to the RSC Service Account JSON file. The file must contain the fields:
client_id, client_secret, and access_token_uri.

.PARAMETER clusterIP
IP address or hostname of the Rubrik CDM cluster to connect to.

.PARAMETER reportID
Report ID to target when using -getCSV or -getHTML. Required when either flag is passed.

.PARAMETER getCSV
Non-interactive flag. When passed, downloads the CSV export for the report specified
by -reportID and exits. Requires -reportID.

.PARAMETER getHTML
Non-interactive flag. When passed, fetches chart data for the report specified by
-reportID, generates an HTML chart file, opens it in the browser, and exits.
Requires -reportID.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 4/17/26
Updated: 4/18/26

Requires PowerShell 7+.

The CDM Bearer token is obtained via POST /api/v1/service_account/session
and is deleted on exit via DELETE /api/v1/session/{id}.

.EXAMPLE
./Manage-CDM-Reports.ps1 -serviceAccountPath './rubrik-sa.json' -clusterIP '10.8.49.104'

Launches the interactive report manager. Lists all reports; enter a row number or
Report ID to select one, then choose to view charts, download CSV, or delete.
Enter 'new' to create a report using the wizard. Press Enter to exit.

.EXAMPLE
./Manage-CDM-Reports.ps1 -serviceAccountPath './rubrik-sa.json' -clusterIP '10.8.49.104' -reportID 'ReportId:::abc123' -getCSV

Non-interactive: downloads the CSV export for the specified report and exits.
Output file: ./rubrik_<ReportName>-yyyy-MM-dd_HHmm.csv

.EXAMPLE
./Manage-CDM-Reports.ps1 -serviceAccountPath './rubrik-sa.json' -clusterIP '10.8.49.104' -reportID 'ReportId:::abc123' -getHTML

Non-interactive: generates an HTML chart file for the specified report, opens it
in the browser, and exits.
Output file: ./rubrik_<ReportName>-yyyy-MM-dd_HHmm.html

.EXAMPLE
./Manage-CDM-Reports.ps1 -serviceAccountPath './rubrik-sa.json' -clusterIP '10.8.49.104' -reportID 'ReportId:::abc123' -getCSV -getHTML

Non-interactive: downloads both the CSV export and the HTML chart file for the
specified report and exits.
#>

param (
  [Parameter(Mandatory = $true)]
  [string] $serviceAccountPath,

  [Parameter(Mandatory = $true)]
  [string] $clusterIP,

  [Parameter(Mandatory = $false)]
  [string] $reportID = '',

  [Parameter(Mandatory = $false)]
  [switch] $getCSV,

  [Parameter(Mandatory = $false)]
  [switch] $getHTML
)

### VARIABLES - BEGIN ###

$date = Get-Date

# Location and prefix for output files. The report name and timestamp are appended automatically.
# To write to a subdirectory, include the path here (e.g. "./reports/rubrik_").
# The directory must already exist.
$csvOutputPrefix  = "./rubrik_"
$htmlOutputPrefix = "./rubrik_"

### VARIABLES - END ###

if ($psversiontable.PSVersion.Major -lt 7) {
  Write-Error "Script requires PowerShell 7+, current version: $($psversiontable.PSVersion)"
  exit 1
}

if (($getCSV -or $getHTML) -and $reportID -eq '') {
  Write-Error "-reportID is required when using -getCSV or -getHTML."
  exit 2
}

###### RUBRIK AUTHENTICATION - BEGIN ######
Write-Host "Attempting to read the Service Account file: $serviceAccountPath"
try {
  $serviceAccountFile = Get-Content -Path "$serviceAccountPath" -ErrorAction Stop | ConvertFrom-Json
} catch {
  $errorMessage = $_.Exception | Out-String
  if ($errorMessage.Contains('because it does not exist')) {
    Write-Error "Service Account JSON not found at $serviceAccountPath."
    exit 100
  }
  Write-Error $_.Exception
  exit 100
}

$missingFields = @()
if ($null -eq $serviceAccountFile.client_id)     { $missingFields += "'client_id'" }
if ($null -eq $serviceAccountFile.client_secret) { $missingFields += "'client_secret'" }
if ($missingFields.count -gt 0) {
  Write-Error "Service Account JSON is missing required fields: $missingFields"
  exit 101
}

$response = Invoke-RestMethod -Method Post -ContentType "application/json" -SkipCertificateCheck `
  -Uri "https://$clusterIP/api/v1/service_account/session" `
  -Body (@{ serviceAccountId = $serviceAccountFile.client_id; secret = $serviceAccountFile.client_secret } | ConvertTo-Json)

$token     = $response.token
$sessionId = $response.sessionId
if ($token -eq '' -or $null -eq $token) {
  Write-Error "Failed to obtain bearer token from cluster, exiting..."
  exit 110
}
Write-Host "Successfully connected to Rubrik cluster: $clusterIP" -ForegroundColor Green

$headers = @{
  'Accept'        = 'application/json'
  'Content-Type'  = 'application/json'
  'Authorization' = "Bearer $token"
}
###### RUBRIK AUTHENTICATION - END ######


# Session cleanup — call before every exit after auth succeeds
function Remove-RubrikSession {
  try {
    Invoke-RestMethod -Method DELETE -SkipCertificateCheck -Headers $script:headers `
      -Uri "https://$script:clusterIP/api/v1/session/$([Uri]::EscapeDataString($script:sessionId))" | Out-Null
    Write-Host "`nSession deleted." -ForegroundColor DarkGray
  } catch {
    Write-Warning "Failed to delete session: $($_.Exception.Message)"
  }
}

###### HELPER FUNCTIONS - BEGIN ######

# Single-item selection from a numbered list; returns $null if skipped
function Select-FromList {
  param(
    [string]   $Prompt,
    [string[]] $Items,
    [switch]   $AllowSkip
  )
  Write-Host ""
  Write-Host $Prompt -ForegroundColor Cyan
  for ($i = 0; $i -lt $Items.Count; $i++) {
    Write-Host ("  {0,2}. {1}" -f ($i + 1), $Items[$i])
  }
  if ($AllowSkip) { Write-Host "  Press Enter to skip / use default" }
  $choice = Read-Host "Selection"
  if ($choice -eq '' -and $AllowSkip) { return $null }
  if ($choice -match '^\d+$') {
    $idx = [int]$choice - 1
    if ($idx -ge 0 -and $idx -lt $Items.Count) { return $Items[$idx] }
  }
  Write-Warning "Invalid selection — skipping."
  return $null
}

# Returns the 0-based index chosen (not the item), or -1 if skipped
function Select-FromListIndex {
  param(
    [string]   $Prompt,
    [string[]] $Items,
    [switch]   $AllowSkip
  )
  Write-Host ""
  Write-Host $Prompt -ForegroundColor Cyan
  for ($i = 0; $i -lt $Items.Count; $i++) {
    Write-Host ("  {0,2}. {1}" -f ($i + 1), $Items[$i])
  }
  if ($AllowSkip) { Write-Host "  Press Enter to skip / use default" }
  $choice = Read-Host "Selection"
  if ($choice -eq '' -and $AllowSkip) { return -1 }
  if ($choice -match '^\d+$') {
    $idx = [int]$choice - 1
    if ($idx -ge 0 -and $idx -lt $Items.Count) { return $idx }
  }
  Write-Warning "Invalid selection — skipping."
  return -1
}

# Multi-item selection from a numbered list; returns array (empty if skipped)
function Select-MultipleFromList {
  param(
    [string]   $Prompt,
    [string[]] $Items
  )
  Write-Host ""
  Write-Host $Prompt -ForegroundColor Cyan
  for ($i = 0; $i -lt $Items.Count; $i++) {
    Write-Host ("  {0,2}. {1}" -f ($i + 1), $Items[$i])
  }
  $raw = Read-Host "Enter comma-separated numbers, 'all', or press Enter to skip"
  if ($raw -eq '') { return @() }
  if ($raw -ieq 'all') { return $Items }
  $selected = @()
  foreach ($part in ($raw -split ',')) {
    $n = $part.Trim()
    if ($n -match '^\d+$') {
      $idx = [int]$n - 1
      if ($idx -ge 0 -and $idx -lt $Items.Count) { $selected += $Items[$idx] }
    }
  }
  return $selected
}

# Wizard: interactively create a custom report (POST shell, then PATCH full config)
function Invoke-ReportPatch {
  param($NewId, $ReportName, $PatchBody)
  Write-Host "Applying configuration..."
  try {
    $null = Invoke-RestMethod -Method PATCH -SkipCertificateCheck -Headers $script:headers `
      -Uri "https://$script:clusterIP/api/internal/report/$([Uri]::EscapeDataString($NewId))" -Body $PatchBody
    Write-Host "Report configured successfully." -ForegroundColor Green
    Write-Host "New report ID: $NewId" -ForegroundColor Cyan
    Write-Host "`nPATCH body sent:" -ForegroundColor DarkGray
    Write-Host $PatchBody -ForegroundColor DarkGray
  } catch {
    $errDetail = $_.ErrorDetails.Message
    Write-Error "Failed to configure report: $($_.Exception.Message)"
    if ($errDetail) { Write-Host "API error detail: $errDetail" -ForegroundColor Red }
    Write-Warning "Shell exists (ID: $NewId) but configuration failed — delete it or retry the PATCH manually."
    Write-Host "`nPATCH body sent:" -ForegroundColor DarkGray
    Write-Host $PatchBody -ForegroundColor DarkGray
  }
}

function New-CustomReport {
  Write-Host "`n=== Create New Custom Report ===" -ForegroundColor Yellow

  # ── Hardcoded template defaults (mirrors GET /api/internal/report/template) ──
  # Default chart/table configs sourced from CDM 9.2 User Guide, Ch.27.
  # reportTemplate values are the API enum identifiers used in POST /report.
  $apiTemplates = @(
    @{
      name           = 'Protection Tasks Summary'
      reportTemplate = 'ProtectionTasksSummary'
      filters        = @{ dateConfig = @{ period = 'Past7Days' } }
      chart0         = @{ name = 'Tasks by Status';     chartType = 'Vertical'; attribute = 'TaskStatus'; measure = 'TaskCount'       }
      chart1         = @{ name = 'Tasks by SLA Domain'; chartType = 'Vertical'; attribute = 'SlaDomain';  measure = 'TaskCount'       }
      table          = @{ columns = @('ObjectName','ClusterLocation','SlaDomain','TaskStatus','Month','DataTransferred','SuccessfulTasks','FailedTasks','CanceledTasks','TaskCount') }
    }
    @{
      name           = 'Protection Tasks Details'
      reportTemplate = 'ProtectionTasksDetails'
      filters        = @{ dateConfig = @{ period = 'Past24Hours' } }
      chart0         = @{ name = 'Tasks by Status';          chartType = 'Vertical'; attribute = 'TaskStatus';  measure = 'TaskCount'  }
      chart1         = @{ name = 'Failed Tasks by Object';   chartType = 'Vertical'; attribute = 'ObjectName';  measure = 'FailedTasks' }
      table          = @{ columns = @('ObjectName','ClusterLocation','SlaDomain','TaskStatus','TaskType','StartTime','EndTime','DataTransferred','Duration') }
    }
    @{
      name           = 'Recovery Tasks Details'
      reportTemplate = 'RecoveryTasksDetails'
      filters        = @{ dateConfig = @{ period = 'Past30Days' } }
      chart0         = @{ name = 'Tasks by Status';        chartType = 'Donut';    attribute = 'TaskStatus'; measure = 'TaskCount'   }
      chart1         = @{ name = 'Failed Tasks by Object'; chartType = 'Vertical'; attribute = 'ObjectName'; measure = 'FailedTasks' }
      table          = @{ columns = @('ObjectName','ClusterLocation','SlaDomain','TaskStatus','TaskType','StartTime','EndTime','DataTransferred') }
    }
    @{
      name           = 'SLA Compliance Summary'
      reportTemplate = 'SlaComplianceSummary'
      filters        = @{ snapshotRange = 'StartOfProtection' }
      chart0         = @{ name = 'Compliance by Status';      chartType = 'Donut';    attribute = 'ComplianceStatus'; measure = 'ComplianceCountByStatus' }
      chart1         = @{ name = 'Object Count by SLA Domain'; chartType = 'Vertical'; attribute = 'SlaDomain';        measure = 'ObjectCount'             }
      table          = @{ columns = @('ObjectName','ClusterLocation','SlaDomain','ComplianceStatus','InCompliance','OutOfCompliance','LocalStorage','LatestLocalSnapshot') }
    }
    @{
      name           = 'Object Backup Task Summary'
      reportTemplate = 'ObjectBackupTaskSummary'
      filters        = @{}
      chart0         = @{ name = 'Task Count by Day';          chartType = 'Vertical'; attribute = 'Day';        measure = 'TaskCount'   }
      chart1         = @{ name = 'Failed Tasks by Object';     chartType = 'Vertical'; attribute = 'ObjectName'; measure = 'FailedTasks' }
      table          = @{ columns = @('ObjectName','ClusterLocation','SlaDomain','SuccessfulTasks','FailedTasks','CanceledTasks','MissedTasks','TaskCount') }
    }
    @{
      name           = 'Object Indexing Summary'
      reportTemplate = 'ObjectIndexingSummary'
      filters        = @{}
      chart0         = @{ name = 'Snapshot Count by Index Status'; chartType = 'Vertical'; attribute = 'SlaDomain';                    measure = 'LocalSnapshotCountByIndexStatus' }
      chart1         = @{ name = 'Indexed Snapshots by Object';    chartType = 'Vertical'; attribute = 'LatestLocalSnapshotIndexStatus'; measure = 'LocalSnapshotsIndexed'           }
      table          = @{ columns = @('ObjectName','ClusterLocation','SlaDomain','LatestLocalSnapshotIndexStatus','LocalSnapshotsIndexed','LocalSnapshotsPendingForIndexing','LocalSnapshotsUnindexed') }
    }
    @{
      name           = 'Object Protection Summary'
      reportTemplate = 'ObjectProtectionSummary'
      filters        = @{}
      chart0         = @{ name = 'Local Storage by SLA Domain';  chartType = 'Vertical'; attribute = 'SlaDomain';        measure = 'LocalStorage'             }
      chart1         = @{ name = 'Compliance Count by Status';   chartType = 'Donut';    attribute = 'ComplianceStatus'; measure = 'ComplianceCountByStatus'  }
      table          = @{ columns = @('ObjectName','ClusterLocation','SlaDomain','ComplianceStatus','LocalStorage','ArchiveStorage','ReplicaStorage','ObjectLogicalSize') }
    }
    @{
      name           = 'Capacity Over Time'
      reportTemplate = 'CapacityOverTime'
      filters        = @{ dateConfig = @{ period = 'Past30Days' } }
      chart0         = @{ name = 'Local Storage by Month';   chartType = 'Line'; attribute = 'Month'; measure = 'LocalStorage'   }
      chart1         = @{ name = 'Archive Storage by Month'; chartType = 'Line'; attribute = 'Month'; measure = 'ArchiveStorage' }
      table          = @{ columns = @('ObjectName','Month','LocalStorage','LocalStorageGrowth','ArchiveStorage','ReplicaStorage') }
    }
    @{
      name           = 'System Capacity'
      reportTemplate = 'SystemCapacity'
      filters        = @{}
      chart0         = @{ name = 'Local Storage by SLA Domain';        chartType = 'Vertical'; attribute = 'SlaDomain'; measure = 'LocalStorage'       }
      chart1         = @{ name = 'Local Storage Growth by SLA Domain'; chartType = 'Vertical'; attribute = 'SlaDomain'; measure = 'LocalStorageGrowth' }
      table          = @{ columns = @('ObjectName','ClusterLocation','SlaDomain','LocalStorage','LocalStorageGrowth','ArchiveStorage','ReplicaStorage','ObjectLogicalSize') }
    }
  )

  # ── Per-template customization constraints (from CDM 9.2 User Guide, Ch.27) ──
  # Attributes, Measures, TableCols, Filters are the valid API enum values per template.
  # Chart types (doc names): Vertical, Horizontal, Line, Donut, StackedVertical, StackedHorizontal
  $templateConstraints = [ordered]@{
    'ProtectionTasksSummary'  = @{
      Display    = 'Protection Tasks Summary'
      Attributes = @('ClusterLocation','ComplianceStatus','Location','ObjectName','ObjectType','SlaDomain','TaskStatus','TaskType')
      Measures   = @('AverageDuration','CanceledTasks','DataReduction','DataStored','DataTransferred','DataTransferredVsStored','DedupRatio','EffectiveThroughput','FailedTasks','LogicalDataProtected','LogicalDataReduction','LogicalDedupRatio','MissedObjects','SuccessfulTasks','TaskCount','TaskCountByStatus','TotalFilesTransferred')
      TableCols  = @('ArchivalTarget','ClusterLocation','Day','DirectArchive','Hour','Location','Month','ObjectName','ObjectType','Organization','Quarter','ReplicationSource','ReplicationTarget','SlaDomain','TaskStatus','Year','AverageDuration','CanceledTasks','DataReduction','DataStored','DataTransferred','DataTransferredVsStored','DedupRatio','EffectiveThroughput','FailedTasks','LogicalDataProtected','LogicalDataReduction','LogicalDedupRatio','MissedObjects','SuccessfulTasks','TaskCount','TaskCountByStatus','TotalFilesTransferred')
      Filters    = @('Date','ClusterLocation','Location','ObjectName','ObjectType','SlaDomain','TaskStatus','TaskTypes')
      DefaultCols = @('ObjectName','ClusterLocation','SlaDomain','TaskStatus','Month','DataTransferred','SuccessfulTasks','FailedTasks','CanceledTasks')
    }
    'ProtectionTasksDetails'  = @{
      Display    = 'Protection Tasks Details'
      Attributes = @('ClusterLocation','ComplianceStatus','Location','ObjectName','ObjectType','SlaDomain','TaskStatus','TaskType')
      Measures   = @('AverageDuration','CanceledTasks','DataReduction','DataStored','DataTransferred','DataTransferredVsStored','DedupRatio','EffectiveThroughput','FailedTasks','LogicalDataProtected','LogicalDataReduction','LogicalDedupRatio','MissedObjects','SuccessfulTasks','TaskCount','TaskCountByStatus','TotalFilesTransferred')
      TableCols  = @('ArchivalTarget','ClusterLocation','DirectArchive','Location','ObjectName','ObjectType','ReplicationSource','ReplicationTarget','SlaDomain','SnapshotConsistency','TaskStatus','TaskType','DataReduction','DataStored','DataTransferred','DataTransferredVsStored','DedupRatio','Duration','EffectiveThroughput','EndTime','LogicalDataProtected','LogicalDataReduction','LogicalDedupRatio','MissedObjects','QueuedTime','StartTime','TotalFilesTransferred')
      Filters    = @('Date','ClusterLocation','Location','ObjectName','ObjectType','SlaDomain','TaskStatus','TaskTypes')
      DefaultCols = @('ObjectName','ClusterLocation','SlaDomain','TaskStatus','TaskType','StartTime','EndTime','DataTransferred','Duration')
    }
    'RecoveryTasksDetails'    = @{
      Display    = 'Recovery Tasks Details'
      Attributes = @('ClusterLocation','ComplianceStatus','Location','ObjectName','ObjectType','SlaDomain','TaskStatus','TaskType')
      Measures   = @('AverageDuration','CanceledTasks','DataTransferred','FailedTasks','ObjectCount','SuccessfulTasks','TaskCount','TaskCountByStatus','TotalFilesTransferred')
      TableCols  = @('ArchivalTarget','ClusterLocation','DirectArchive','FailureReason','Location','ObjectName','ObjectType','RecoveryPoint','RecoveryPointType','ReplicationSource','ReplicationTarget','SlaDomain','TaskStatus','TaskType','Username','DataTransferred','Duration','EndTime','QueuedTime','StartTime','TotalFilesTransferred')
      Filters    = @('Date','ClusterLocation','Location','ObjectName','ObjectType','SlaDomain','TaskStatus','TaskTypes')
      DefaultCols = @('ObjectName','ClusterLocation','SlaDomain','TaskStatus','TaskType','StartTime','EndTime','DataTransferred')
    }
    'SlaComplianceSummary'    = @{
      Display    = 'SLA Compliance Summary'
      Attributes = @('ClusterLocation','ComplianceStatus','LocalCdpStatus','Location','ObjectName','ObjectType','SlaDomain')
      Measures   = @('ArchivalSnapshotLag','ComplianceCountByStatus','InCompliance','LocalCdpHealth','LocalStorage','LocalStorageGrowth','ObjectCount','OutOfCompliance','ReplicaStorage','ReplicaStorageGrowth','SnapshotCountByDataLocation')
      TableCols  = @('ArchivalTarget','ClusterLocation','ComplianceStatus','DirectArchive','Location','ObjectName','ObjectType','Organization','ReplicationSource','ReplicationTarget','SlaDomain','ArchivalSnapshotLag','ArchivedOnDemandSnapshots','ArchivedSlaSnapshots','ArchivedSnapshots','InCompliance','LatestArchivedSnapshot','LatestLocalSnapshot','LocalOnDemandSnapshots','LocalSlaSnapshots','LocalSnapshots','LocalStorage','LocalStorageGrowth','MissedSnapshots','ObjectLogicalSize','OutOfCompliance','ProtectedOn','ReplicaStorage','ReplicaStorageGrowth','ReplicatedSnapshots','TotalSnapshots')
      Filters    = @('ArchivalComplianceStatus','ComplianceStatus','ClusterLocation','Location','ObjectName','ObjectType','Range','ReplicationComplianceStatus','SlaDomain')
      DefaultCols = @('ObjectName','ClusterLocation','SlaDomain','ComplianceStatus','InCompliance','OutOfCompliance','LocalStorage','LatestLocalSnapshot')
    }
    'ObjectBackupTaskSummary' = @{
      Display    = 'Object Backup Task Summary'
      Attributes = @('ComplianceStatus','Day','LocalCdpStatus','Location','ObjectName','ObjectType','SlaDomain')
      Measures   = @('CanceledTasks','ExpectedTasks','FailedTasks','MissedTasks','SuccessfulTasks','TaskCount')
      TableCols  = @('ClusterLocation','ComplianceStatus','CurrentTaskStatus','DirectArchive','LastSuccessfulTask','Location','ObjectName','ObjectType','Organization','ReplicationSource','ReplicationTarget','SlaDomain','ArchivalObjectCount','CanceledTasks','ExpectedTasks','FailedTasks','LongRunningTasks','MissedTasks','ObjectCount','OnTimeTasks','ProtectedOn','SuccessfulTasks','TaskCount')
      Filters    = @('ObjectName','ObjectType','SlaDomain')
      DefaultCols = @('ObjectName','ClusterLocation','SlaDomain','SuccessfulTasks','FailedTasks','CanceledTasks','MissedTasks','TaskCount')
    }
    'ObjectIndexingSummary'   = @{
      Display    = 'Object Indexing Summary'
      Attributes = @('LatestLocalSnapshotIndexStatus','LocalCdpStatus','Location','ObjectIndexType','ObjectName','ObjectType','SlaDomain')
      Measures   = @('LocalSnapshotCountByIndexStatus','LocalSnapshotsIndexed','LocalSnapshotsPendingForIndexing','LocalSnapshotsUnindexed')
      TableCols  = @('ArchivalTarget','ClusterLocation','DirectArchive','LatestLocalSnapshotIndexStatus','Location','ObjectIndexType','ObjectName','ObjectType','Organization','ReplicationSource','ReplicationTarget','SlaDomain','ArchivalObjectCount','ArchivedOnDemandSnapshots','ArchivedSlaSnapshots','ArchivedSnapshots','LatestArchivedSnapshot','LatestLocalIndexedSnapshot','LatestLocalSnapshot','LocalOnDemandSnapshots','LocalSlaSnapshots','LocalSnapshots','LocalSnapshotsIndexed','LocalSnapshotsPendingForIndexing','LocalSnapshotsUnindexed','ObjectCount','ProtectedOn','ReplicatedSnapshots','TotalSnapshots')
      Filters    = @('ClusterLocation','Location','ObjectIndexType','ObjectName','ObjectType','SlaDomain')
      DefaultCols = @('ObjectName','ClusterLocation','SlaDomain','LatestLocalSnapshotIndexStatus','LocalSnapshotsIndexed','LocalSnapshotsPendingForIndexing','LocalSnapshotsUnindexed')
    }
    'ObjectProtectionSummary' = @{
      Display    = 'Object Protection Summary'
      Attributes = @('ClusterLocation','ComplianceStatus','LocalCdpStatus','Location','ObjectName','ObjectType','SlaDomain')
      Measures   = @('ArchivalSnapshotLag','ArchiveDataReduction','ArchiveDedupRatio','ArchiveEffectiveDataTransferred','ArchiveEffectiveLogicalData','ArchiveLogicalDataReduction','ArchiveLogicalDedupRatio','ArchiveStorage','ArchiveStorageGrowth','ComplianceCountByStatus','InCompliance','LocalCdpHealth','LocalCdpLogStorage','LocalCdpThroughput','LocalDataReduction','LocalDataTransferred','LocalDedupRatio','LocalEffectiveLogicalData','LocalEffectiveStorage','LocalLogicalDataReduction','LocalLogicalDedupRatio','LocalMeteredData','LocalProtectedData','LocalStorage','LocalStorageGrowth','ObjectCount','ObjectLogicalSize','OutOfCompliance','ProvisionedSize','ReplicaStorage','ReplicaStorageGrowth','SnapshotCountByDataLocation','StorageGrowthByDataLocation','TotalStorageByDataLocation','UsedSize')
      TableCols  = @('ArchivalTarget','ClusterLocation','ComplianceStatus','DirectArchive','Location','ObjectName','ObjectType','Organization','ReplicationSource','ReplicationTarget','SlaDomain','ArchivalObjectCount','ArchivalSnapshotLag','ArchiveDataReduction','ArchiveDedupRatio','ArchiveEffectiveDataTransferred','ArchiveEffectiveLogicalData','ArchiveLogicalDataReduction','ArchiveLogicalDedupRatio','ArchiveStorage','ArchiveStorageGrowth','ArchivedSlaSnapshots','ArchivedSnapshots','InCompliance','LocalDataReduction','LocalDataTransferred','LocalDedupRatio','LocalEffectiveLogicalData','LocalLogicalDataReduction','LocalLogicalDedupRatio','LocalSnapshots','LocalStorage','LocalStorageGrowth','MissedSnapshots','ObjectCount','ObjectLogicalSize','OutOfCompliance','ProtectedOn','ReplicaStorage','ReplicaStorageGrowth','ReplicatedSnapshots','TotalSnapshots')
      Filters    = @('ClusterLocation','Location','ObjectName','ObjectType','SlaDomain','TaskTypes')
      DefaultCols = @('ObjectName','ClusterLocation','SlaDomain','ComplianceStatus','LocalStorage','ArchiveStorage','ReplicaStorage','ObjectLogicalSize')
    }
    'CapacityOverTime'        = @{
      Display    = 'Capacity Over Time'
      Attributes = @('Day','Month','Quarter')
      Measures   = @('ArchiveDataReduction','ArchiveDedupRatio','ArchiveEffectiveDataTransferred','ArchiveEffectiveLogicalData','ArchiveLogicalDataReduction','ArchiveLogicalDedupRatio','ArchiveStorage','ArchiveStorageGrowth','LocalCdpLogStorage','LocalCdpThroughput','LocalDataReduction','LocalDataTransferred','LocalDedupRatio','LocalEffectiveLogicalData','LocalEffectiveStorage','LocalLogicalDataReduction','LocalLogicalDedupRatio','LocalMeteredData','LocalProtectedData','LocalStorage','LocalStorageGrowth','ObjectLogicalSize','ProvisionedSize','ReplicaStorage','ReplicaStorageGrowth','UsedSize')
      TableCols  = @('ArchivalTarget','ClusterLocation','Day','DirectArchive','Location','Month','ObjectName','ObjectType','Organization','Quarter','ReplicationSource','ReplicationTarget','SlaDomain','ArchivalObjectCount','ArchiveDataReduction','ArchiveDedupRatio','ArchiveEffectiveDataTransferred','ArchiveEffectiveLogicalData','ArchiveLogicalDataReduction','ArchiveLogicalDedupRatio','ArchiveStorage','ArchiveStorageGrowth','LocalDataReduction','LocalDataTransferred','LocalDedupRatio','LocalEffectiveLogicalData','LocalLogicalDataReduction','LocalLogicalDedupRatio','LocalStorage','LocalStorageGrowth','ObjectCount','ObjectLogicalSize','ProtectedOn','ReplicaStorage','ReplicaStorageGrowth')
      Filters    = @('Date','ClusterLocation','Location','ObjectName','ObjectType','SlaDomain')
      DefaultCols = @('ObjectName','Month','LocalStorage','LocalStorageGrowth','ArchiveStorage','ReplicaStorage')
    }
    'SystemCapacity'          = @{
      Display    = 'System Capacity'
      Attributes = @('ClusterLocation','ComplianceStatus','LocalCdpStatus','Location','ObjectName','ObjectType','SlaDomain')
      Measures   = @('ArchiveDataReduction','ArchiveDedupRatio','ArchiveEffectiveDataTransferred','ArchiveEffectiveLogicalData','ArchiveLogicalDataReduction','ArchiveLogicalDedupRatio','ArchiveStorage','ArchiveStorageGrowth','LocalCdpLogStorage','LocalCdpThroughput','LocalDataReduction','LocalDataTransferred','LocalDedupRatio','LocalEffectiveLogicalData','LocalEffectiveStorage','LocalLogicalDataReduction','LocalLogicalDedupRatio','LocalMeteredData','LocalProtectedData','LocalStorage','LocalStorageGrowth','ObjectLogicalSize','ProvisionedSize','ReplicaStorage','ReplicaStorageGrowth','StorageGrowthByDataLocation','TotalStorageByDataLocation','UsedSize')
      TableCols  = @('ArchivalTarget','ClusterLocation','DirectArchive','Location','ObjectName','ObjectType','Organization','ReplicationSource','ReplicationTarget','SlaDomain','ArchivalObjectCount','ArchiveDataReduction','ArchiveDedupRatio','ArchiveEffectiveDataTransferred','ArchiveEffectiveLogicalData','ArchiveLogicalDataReduction','ArchiveLogicalDedupRatio','ArchiveStorage','ArchiveStorageGrowth','LocalDataReduction','LocalDataTransferred','LocalDedupRatio','LocalEffectiveLogicalData','LocalLogicalDataReduction','LocalLogicalDedupRatio','LocalStorage','LocalStorageGrowth','ObjectCount','ObjectLogicalSize','ProtectedOn','ReplicaStorage','ReplicaStorageGrowth')
      Filters    = @('ClusterLocation','Location','ObjectName','ObjectType','SlaDomain')
      DefaultCols = @('ObjectName','ClusterLocation','SlaDomain','LocalStorage','LocalStorageGrowth','ArchiveStorage','ReplicaStorage','ObjectLogicalSize')
    }
  }

  # ── 1. Report name ─────────────────────────────────────────────────────────
  $reportName = ''
  while ($reportName -eq '') { $reportName = Read-Host "`nReport name (required)" }

  # ── 2. Template — list from API ────────────────────────────────────────────
  Write-Host ""
  Write-Host "Select report template:" -ForegroundColor Cyan
  for ($i = 0; $i -lt $apiTemplates.Count; $i++) {
    $t = $apiTemplates[$i]
    $tDisplay = if ($t.name) { $t.name } else { $t.reportTemplate }
    Write-Host ("  {0,2}. {1}" -f ($i + 1), $tDisplay)
  }
  $tChoice = Read-Host "Selection"
  if ($tChoice -notmatch '^\d+$') { Write-Warning "Invalid selection — cancelled."; return }
  $tIdx = [int]$tChoice - 1
  if ($tIdx -lt 0 -or $tIdx -ge $apiTemplates.Count) { Write-Warning "Out of range — cancelled."; return }
  $apiTemplate = $apiTemplates[$tIdx]

  # Derive the reportTemplate key used in POST (prefer reportTemplate field, fall back to id/name)
  $templateKey = if ($apiTemplate.reportTemplate) { $apiTemplate.reportTemplate } `
                 elseif ($apiTemplate.id)          { $apiTemplate.id }            `
                 else                              { $apiTemplate.name }
  $tDisplayName = if ($apiTemplate.name) { $apiTemplate.name } else { $templateKey }
  Write-Host "  → $tDisplayName" -ForegroundColor DarkGray

  # Look up per-template customization constraints (for the customize path)
  $td = $templateConstraints[$templateKey]

  # ── 3. Default or customize? ───────────────────────────────────────────────
  Write-Host ""
  Write-Host "  1. Use default template configuration" -ForegroundColor Cyan
  Write-Host "  2. Customize (filters, charts, columns)" -ForegroundColor Cyan
  $modeChoice = Read-Host "Selection (1 or 2)"

  # ── Build $patchBody based on chosen mode ──────────────────────────────────
  $patchBody = $null

  if ($modeChoice -eq '1') {
    # ── DEFAULT PATH ──────────────────────────────────────────────────────────
    # Use the template's stored chart/table config directly.
    # Only ask about dateConfig if this template supports the Date or Range filter.
    $filters = @{}
    $supportsDate  = $null -ne $td -and 'Date'  -in $td.Filters
    $supportsRange = $null -ne $td -and 'Range' -in $td.Filters

    if ($supportsDate) {
      Write-Host "`n--- Date Filter ---" -ForegroundColor Yellow
      $datePeriods = @('Past24Hours','Past7Days','Past30Days','PastYear')
      $period = Select-FromList -Prompt "Date range period (press Enter to use template default):" -Items $datePeriods -AllowSkip
      if ($null -ne $period) { $filters.dateConfig = @{ period = $period } }
    } elseif ($supportsRange) {
      Write-Host "`n--- Snapshot Range Filter ---" -ForegroundColor Yellow
      $ranges = @('Past24Hours','Past7Days','Past30Days','Past90Days','Past365Days','LastSnapshot','Last2Snapshots','Last3Snapshots','StartOfProtection')
      $range = Select-FromList -Prompt "Snapshot range (press Enter to use template default):" -Items $ranges -AllowSkip
      if ($null -ne $range) { $filters.snapshotRange = $range }
    }

    $patchMap = @{
      name   = $reportName
      chart0 = $apiTemplate.chart0
      chart1 = $apiTemplate.chart1
      table  = $apiTemplate.table
    }
    # Use user-specified filters if provided, otherwise fall back to template filters
    $patchMap.filters = if ($filters.Count -gt 0) { $filters }
                        elseif ($apiTemplate.filters) { $apiTemplate.filters }
                        else { @{} }
    $patchBody = $patchMap | ConvertTo-Json -Depth 6

  } else {
    # ── CUSTOMIZE PATH ────────────────────────────────────────────────────────
    if ($null -eq $td) {
      Write-Warning "No customization constraints found for template '$templateKey'. Proceeding with all options."
      $td = @{
        Display    = $tDisplayName
        Attributes = @('ClusterLocation','Location','ObjectName','ObjectType','SlaDomain','TaskStatus','TaskType')
        Measures   = @('TaskCount','SuccessfulTasks','FailedTasks','CanceledTasks','DataTransferred','LocalStorage')
        TableCols  = @('ObjectName','ClusterLocation','SlaDomain','TaskStatus','StartTime','EndTime','DataTransferred')
        DefaultCols= @('ObjectName','ClusterLocation','SlaDomain','TaskStatus','DataTransferred')
        Filters    = @('Date','ObjectType','SlaDomain','TaskStatus','TaskTypes')
      }
    }

    Write-Host "`n--- Filters ---" -ForegroundColor Yellow
    $filters = @{}
    if ('Date' -in $td.Filters) {
      $datePeriods = @('Past24Hours','Past7Days','Past30Days','PastYear')
      $period = Select-FromList -Prompt "Date range period:" -Items $datePeriods -AllowSkip
      if ($null -eq $period) { $period = 'Past7Days'; Write-Host "  Defaulting to Past7Days" -ForegroundColor DarkGray }
      $filters.dateConfig = @{ period = $period }
    }
    if ('Range' -in $td.Filters) {
      $ranges = @('Past24Hours','Past7Days','Past30Days','Past90Days','Past365Days','LastSnapshot','Last2Snapshots','Last3Snapshots','StartOfProtection')
      $range = Select-FromList -Prompt "Snapshot range (SLA compliance window):" -Items $ranges -AllowSkip
      if ($null -ne $range) { $filters.snapshotRange = $range }
    }
    if ('TaskTypes' -in $td.Filters) {
      $sel = Select-MultipleFromList -Prompt "Task types (blank = all):" -Items @('Backup','Archival','Replication')
      if ($sel.Count -gt 0) { $filters.taskType = $sel }
    }
    if ('TaskStatus' -in $td.Filters) {
      $sel = Select-MultipleFromList -Prompt "Task statuses (blank = all):" -Items @('Succeeded','Failed','Canceled')
      if ($sel.Count -gt 0) { $filters.taskStatus = $sel }
    }
    if ('ObjectType' -in $td.Filters) {
      $sel = Select-MultipleFromList -Prompt "Object types (blank = all):" `
        -Items @('VirtualMachine','LinuxFileset','WindowsFileset','MssqlDatabase','NutanixVirtualMachine','HypervVirtualMachine','ManagedVolume')
      if ($sel.Count -gt 0) { $filters.objectType = $sel }
    }
    if ('ComplianceStatus' -in $td.Filters) {
      $sel = Select-MultipleFromList -Prompt "Compliance status (blank = all):" -Items @('InCompliance','OutOfCompliance')
      if ($sel.Count -gt 0) { $filters.complianceStatus = $sel }
    }
    if ('ClusterLocation' -in $td.Filters) {
      $cl = Select-FromList -Prompt "Cluster location:" -Items @('Local','Remote') -AllowSkip
      if ($null -ne $cl) { $filters.clusterLocation = $cl }
    }

    $chartTypes  = @('Vertical','Horizontal','Line','Donut','StackedVertical','StackedHorizontal')
    $chartObjects = @()
    foreach ($chartNum in @('0','1')) {
      Write-Host "`n--- Chart $chartNum Configuration ---" -ForegroundColor Yellow
      $cName = Read-Host "Chart $chartNum name"
      $cType = Select-FromList -Prompt "Chart $chartNum type:" -Items $chartTypes -AllowSkip
      if ($null -eq $cType) { $cType = if ($chartNum -eq '0') { 'Vertical' } else { 'Line' } }
      $cAttr = Select-FromList -Prompt "Chart $chartNum attribute (grouping dimension):" -Items $td.Attributes -AllowSkip
      if ($null -eq $cAttr) { $cAttr = $td.Attributes[0] }
      $cMeas = Select-FromList -Prompt "Chart $chartNum measure (Y-axis metric):" -Items $td.Measures -AllowSkip
      if ($null -eq $cMeas) { $cMeas = $td.Measures[0] }
      if ($cName -eq '') { $cName = "$cAttr — $cMeas" }
      $chartObjects += @{ name = $cName; chartType = $cType; attribute = $cAttr; measure = $cMeas }
    }

    $selColumns = Select-MultipleFromList -Prompt "Table columns (valid for $tDisplayName):" -Items $td.TableCols
    if ($selColumns.Count -eq 0) {
      $selColumns = $td.DefaultCols
      Write-Host "  Using default columns: $($selColumns -join ', ')" -ForegroundColor DarkGray
    }

    $patchBody = @{
      name    = $reportName
      filters = $filters
      chart0  = $chartObjects[0]
      chart1  = $chartObjects[1]
      table   = @{ columns = $selColumns }
    } | ConvertTo-Json -Depth 6
  }

  # ── POST — create report shell ─────────────────────────────────────────────
  Write-Host "`nCreating report..."
  $postBody = @{ name = $reportName; reportTemplate = $templateKey } | ConvertTo-Json
  try {
    $newReport = Invoke-RestMethod -Method POST -SkipCertificateCheck -Headers $script:headers `
      -Uri "https://$script:clusterIP/api/internal/report" -Body $postBody
  } catch {
    Write-Error "Failed to create report: $($_.Exception.Message)"
    return
  }
  $newId = $newReport.id
  Write-Host "Report shell created — ID: $newId" -ForegroundColor Green

  # ── PATCH — apply configuration ────────────────────────────────────────────
  Invoke-ReportPatch -NewId $newId -ReportName $reportName -PatchBody $patchBody
}

# Byte measure detection and auto-scaling (used by Invoke-ChartHtml)
$byteMeasureKeywords = @('Bytes','Storage','Data','Size','Growth','Ingested','Transferred','Protected','Stored')

function IsBytesMeasure ($measureName) {
  foreach ($kw in $script:byteMeasureKeywords) {
    if ($measureName -match $kw) { return $true }
  }
  return $false
}

function Get-ByteUnit ($maxValue) {
  if     ($maxValue -ge 1PB) { return @{ unit = 'PB'; divisor = 1PB } }
  elseif ($maxValue -ge 1TB) { return @{ unit = 'TB'; divisor = 1TB } }
  elseif ($maxValue -ge 1GB) { return @{ unit = 'GB'; divisor = 1GB } }
  elseif ($maxValue -ge 1MB) { return @{ unit = 'MB'; divisor = 1MB } }
  else                       { return @{ unit = 'B';  divisor = 1    } }
}

function Format-MonthLabel ($label) {
  try { return ([datetime]::ParseExact($label, 'yyyy-MM', $null)).ToString('MMM yyyy') }
  catch { return $label }
}

# Generates an HTML chart file for a given report and opens it in the browser.
function Invoke-ChartHtml {
  param(
    [object[]] $Charts,
    [string]   $ReportName,
    [string]   $ReportId,
    [string]   $HtmlOutput
  )

  $colors      = @('#4e79a7','#f28e2b','#e15759','#76b7b2','#59a14f','#edc948','#b07aa1','#ff9da7','#9c755f','#bab0ac')
  $chartBlocks = @()

  foreach ($chart in $Charts) {
    $canvasId   = "chart_$($chart.id -replace '[^a-zA-Z0-9]','_')"
    $isMonth    = $chart.attribute -eq 'Month'
    $isByte     = IsBytesMeasure $chart.measure
    $divisor    = 1
    $yAxisLabel = $chart.measure

    $xLabels  = $chart.dataColumns | ForEach-Object { if ($isMonth) { Format-MonthLabel $_.label } else { $_.label } }
    $labelsJs = ($xLabels | ForEach-Object { "'$_'" }) -join ', '

    if ($isByte) {
      $allValues  = $chart.dataColumns | ForEach-Object { $_.dataPoints[0].value }
      $maxVal     = ($allValues | Measure-Object -Maximum).Maximum
      $unitInfo   = Get-ByteUnit $maxVal
      $divisor    = $unitInfo.divisor
      $yAxisLabel = "$($chart.measure) ($($unitInfo.unit))"
    }

    $values   = $chart.dataColumns | ForEach-Object { [math]::Round($_.dataPoints[0].value / $divisor, 2) }
    $valuesJs = $values -join ', '
    $color    = $colors[0]

    $datasetsJs = @"
      {
        label: '$($chart.name -replace "'","\\'")',
        data: [$valuesJs],
        backgroundColor: '$($color)33',
        borderColor: '$color',
        borderWidth: 2,
        pointRadius: 4,
        pointHoverRadius: 6,
        fill: true,
        tension: 0.3
      }
"@

    $chartBlocks += @"
  <div class="chart-container">
    <h2>$($chart.name)</h2>
    <p class="meta">Attribute: $($chart.attribute) &nbsp;|&nbsp; Measure: $($chart.measure)</p>
    <canvas id="$canvasId"></canvas>
  </div>
  <script>
    new Chart(document.getElementById('$canvasId'), {
      type: 'line',
      data: {
        labels: [$labelsJs],
        datasets: [$datasetsJs]
      },
      options: {
        responsive: true,
        plugins: { legend: { display: false } },
        scales: {
          x: {
            title: { display: true, text: '$($chart.attribute)' },
            ticks: { maxRotation: 45, minRotation: 30 }
          },
          y: {
            title: { display: true, text: '$yAxisLabel' },
            beginAtZero: false
          }
        }
      }
    });
  </script>
"@
  }

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>$ReportName - Rubrik Report Charts</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
  <style>
    body { font-family: Arial, sans-serif; background: #f4f4f4; margin: 0; padding: 20px; }
    h1   { color: #333; }
    .meta-bar { color: #666; font-size: 13px; margin-bottom: 30px; }
    .chart-container {
      background: white; border-radius: 8px;
      box-shadow: 0 2px 6px rgba(0,0,0,0.1);
      padding: 24px; margin-bottom: 30px; max-width: 1000px;
    }
    h2   { margin: 0 0 4px; color: #1a1a1a; font-size: 18px; }
    .meta { color: #888; font-size: 12px; margin: 0 0 16px; }
    canvas { max-height: 400px; }
  </style>
</head>
<body>
  <h1>$ReportName</h1>
  <p class="meta-bar">Cluster: $script:clusterIP &nbsp;|&nbsp; Report ID: $ReportId &nbsp;|&nbsp; Generated: $($script:date.ToString("yyyy-MM-dd HH:mm"))</p>
$($chartBlocks -join "`n")
</body>
</html>
"@

  $html | Out-File -FilePath $HtmlOutput -Encoding utf8
  Write-Host "Chart HTML written to: $HtmlOutput" -ForegroundColor Green
  if ($IsMacOS) { open $HtmlOutput } elseif ($IsWindows) { Start-Process $HtmlOutput } else { xdg-open $HtmlOutput }
}

###### HELPER FUNCTIONS - END ######

###### NON-INTERACTIVE MODE - BEGIN ######
if ($getCSV -or $getHTML) {
  Write-Host "Non-interactive mode — Report ID: $reportID"

  try {
    $selectedReport = Invoke-RestMethod -Method GET -SkipCertificateCheck -Headers $headers `
      -Uri "https://$clusterIP/api/internal/report/$([Uri]::EscapeDataString($reportID))"
  } catch {
    Write-Error "Failed to retrieve report '$reportID': $($_.Exception.Message)"
    Remove-RubrikSession; exit 201
  }

  if ($selectedReport.updateStatus -eq 'Updating') {
    Write-Warning "Report '$($selectedReport.name)' is currently updating. Try again later."
    Remove-RubrikSession; exit 202
  }

  $reportId   = $selectedReport.id
  $reportName = $selectedReport.name
  $safeName   = $reportName -replace '[\\/:*?"<>|]', '' -replace '\s+', '_'
  Write-Host "Report: $reportName" -ForegroundColor Cyan

  if ($getHTML) {
    $htmlOutput = "${htmlOutputPrefix}${safeName}-$($date.ToString("yyyy-MM-dd_HHmm")).html"
    Write-Host "Fetching chart data..."
    try {
      $charts = Invoke-RestMethod -Method GET -SkipCertificateCheck -Headers $headers `
        -Uri "https://$clusterIP/api/internal/report/$([Uri]::EscapeDataString($reportId))/chart"
    } catch {
      Write-Error "Failed to retrieve chart data: $($_.Exception.Message)"
      Remove-RubrikSession; exit 203
    }
    if ($charts.count -eq 0) {
      Write-Warning "No chart data returned for report '$reportName'."
    } else {
      Write-Host "Charts found: $($charts.count)"
      Invoke-ChartHtml -Charts $charts -ReportName $reportName -ReportId $reportId -HtmlOutput $htmlOutput
    }
  }

  if ($getCSV) {
    $csvOutput = "${csvOutputPrefix}${safeName}-$($date.ToString("yyyy-MM-dd_HHmm")).csv"
    Write-Host "Requesting CSV download link..."
    try {
      $csvLink = Invoke-RestMethod -Method GET -SkipCertificateCheck -Headers $headers `
        -Uri "https://$clusterIP/api/internal/report/$([Uri]::EscapeDataString($reportId))/csv_link"
    } catch {
      Write-Error "Failed to get CSV link: $($_.Exception.Message)"
      Remove-RubrikSession; exit 204
    }
    Write-Host "Downloading CSV..."
    try {
      Invoke-WebRequest -Uri $csvLink -OutFile $csvOutput -SkipCertificateCheck `
        -Headers @{ 'Authorization' = "Bearer $token" }
    } catch {
      Write-Error "Failed to download CSV: $($_.Exception.Message)"
      Remove-RubrikSession; exit 205
    }
    $rowCount = (Get-Content $csvOutput | Measure-Object -Line).Lines - 1
    Write-Host "CSV saved to: $csvOutput ($rowCount rows)" -ForegroundColor Green
  }

  Remove-RubrikSession
  exit 0
}
###### NON-INTERACTIVE MODE - END ######

###### GET REPORTS LIST + SELECTION LOOP - BEGIN ######
$selectedReport = $null
while ($true) {
  Write-Host "`nQuerying reports list..."
  try {
    $response = Invoke-RestMethod -Method GET -SkipCertificateCheck -Headers $headers `
      -Uri "https://$clusterIP/api/internal/report?sort_by=name&sort_order=asc"
  } catch {
    Write-Error "Failed to retrieve reports list: $($_.Exception.Message)"
    Remove-RubrikSession; exit 200
  }

  $reports = $response.data
  Write-Host "Total reports found: $($reports.count)`n"

  $reportRows = @()
  $i = 1
  foreach ($r in $reports) {
    $reportRows += [PSCustomObject]@{
      Row    = $i
      Name   = $r.name
      Status = $r.updateStatus
      ID     = $r.id
      Type   = $r.reportType
    }
    $i++
  }

  # Custom color-coded table (Format-Table cannot color individual cells)
  $wRow    = [Math]::Max(3, ($reportRows | ForEach-Object { "$($_.Row)".Length   } | Measure-Object -Maximum).Maximum)
  $wName   = [Math]::Max(4, ($reportRows | ForEach-Object { $_.Name.Length       } | Measure-Object -Maximum).Maximum)
  $wStatus = [Math]::Max(6, ($reportRows | ForEach-Object { $_.Status.Length     } | Measure-Object -Maximum).Maximum)
  $wID     = [Math]::Max(2, ($reportRows | ForEach-Object { $_.ID.Length         } | Measure-Object -Maximum).Maximum)
  $wType   = [Math]::Max(4, ($reportRows | ForEach-Object { $_.Type.Length       } | Measure-Object -Maximum).Maximum)

  $hdr = "{0,-$wRow}  {1,-$wName}  {2,-$wStatus}  {3,-$wID}  {4,-$wType}" -f 'Row','Name','Status','ID','Type'
  Write-Host $hdr
  Write-Host ('-' * $hdr.Length)

  foreach ($row in $reportRows) {
    $statusColor = switch ($row.Status.ToLower()) {
      'ready'    { 'Green'  }
      'updating' { 'Yellow' }
      default    { 'Gray'   }
    }
    Write-Host ("{0,-$wRow}  {1,-$wName}  " -f $row.Row, $row.Name) -NoNewline
    Write-Host ("{0,-$wStatus}" -f $row.Status) -NoNewline -ForegroundColor $statusColor
    Write-Host ("  {0,-$wID}  {1,-$wType}" -f $row.ID, $row.Type)
  }
  Write-Host ""

  $selection = Read-Host "Enter a row number, Report ID, 'new' to create, 'r' to refresh, or press Enter to exit"
  if ($selection -eq '') { Remove-RubrikSession; exit 0 }

  if ($selection -ieq 'r' -or $selection -ieq 'refresh') { continue }

  if ($selection -ieq 'new') { New-CustomReport; continue }

  if ($selection -match '^\d+$') {
    $rowNum = [int]$selection
    if ($rowNum -lt 1 -or $rowNum -gt $reportRows.count) {
      Write-Error "Row $rowNum is out of range (1-$($reportRows.count))."
      Remove-RubrikSession; exit 300
    }
    $selectedReport = $reports[$rowNum - 1]
  } else {
    $selectedReport = $reports | Where-Object { $_.id -eq $selection } | Select-Object -First 1
    if ($null -eq $selectedReport) {
      Write-Error "No report found with ID: $selection"
      Remove-RubrikSession; exit 301
    }
  }

  if ($selectedReport.updateStatus -eq 'Updating') {
    Write-Host "`nReport '$($selectedReport.name)' is currently updating and cannot be accessed." -ForegroundColor Yellow
    Write-Host "Please wait for it to finish or select a different report." -ForegroundColor Yellow
    $selectedReport = $null
    continue
  }

  $reportId   = $selectedReport.id
  $reportName = $selectedReport.name
  Write-Host "`nSelected: $reportName" -ForegroundColor Cyan

  ###### FEATURE MENU ######
  Write-Host "`nSelect an action:"
  Write-Host "  1. View charts"
  Write-Host "  2. Export table data as CSV"
  Write-Host "  3. Delete report"
  $action = Read-Host "Enter selection (1, 2, or 3)"

  # ══════════════════════════════════════════════════════════════════════
  #  ACTION 1 — CHARTS
  # ══════════════════════════════════════════════════════════════════════
  if ($action -eq '1') {

    $safeName   = $reportName -replace '[\\/:*?"<>|]', '' -replace '\s+', '_'
    $htmlOutput = "${htmlOutputPrefix}${safeName}-$($date.ToString("yyyy-MM-dd_HHmm")).html"
    Write-Host "`nFetching chart data..."
    try {
      $charts = Invoke-RestMethod -Method GET -SkipCertificateCheck -Headers $headers `
        -Uri "https://$clusterIP/api/internal/report/$([Uri]::EscapeDataString($reportId))/chart"
    } catch {
      Write-Error "Failed to retrieve chart data: $($_.Exception.Message)"
      Remove-RubrikSession; exit 201
    }

    if ($charts.count -eq 0) {
      Write-Host "No chart data returned for this report." -ForegroundColor Yellow
      continue
    }
    Write-Host "Charts found: $($charts.count)"
    Invoke-ChartHtml -Charts $charts -ReportName $reportName -ReportId $reportId -HtmlOutput $htmlOutput
    continue

  # ══════════════════════════════════════════════════════════════════════
  #  ACTION 2 — TABLE DATA (via CSV link)
  # ══════════════════════════════════════════════════════════════════════
  } elseif ($action -eq '2') {

    $safeName  = $reportName -replace '[\\/:*?"<>|]', '' -replace '\s+', '_'
    $csvOutput = "${csvOutputPrefix}${safeName}-$($date.ToString("yyyy-MM-dd_HHmm")).csv"
    Write-Host "`nRequesting CSV download link..."
    try {
      $csvLink = Invoke-RestMethod -Method GET -SkipCertificateCheck -Headers $headers `
        -Uri "https://$clusterIP/api/internal/report/$([Uri]::EscapeDataString($reportId))/csv_link"
    } catch {
      Write-Error "Failed to get CSV link: $($_.Exception.Message)"
      Remove-RubrikSession; exit 400
    }

    Write-Host "Downloading CSV from: $csvLink"
    try {
      $downloadHeaders = @{ 'Authorization' = "Bearer $token" }
      Invoke-WebRequest -Uri $csvLink -OutFile $csvOutput -SkipCertificateCheck -Headers $downloadHeaders
    } catch {
      Write-Error "Failed to download CSV: $($_.Exception.Message)"
      Remove-RubrikSession; exit 401
    }

    $rowCount = (Get-Content $csvOutput | Measure-Object -Line).Lines - 1
    Write-Host "CSV saved to: $csvOutput ($rowCount rows)" -ForegroundColor Green
    continue

  # ══════════════════════════════════════════════════════════════════════
  #  ACTION 3 — DELETE REPORT
  # ══════════════════════════════════════════════════════════════════════
  } elseif ($action -eq '3') {

    Write-Host "`nReport to delete: $reportName ($reportId)" -ForegroundColor Yellow
    $confirm = Read-Host "Type 'yes' to confirm deletion"
    if ($confirm -ine 'yes') {
      Write-Host "Deletion cancelled." -ForegroundColor DarkGray
      continue
    }

    try {
      Invoke-RestMethod -Method DELETE -SkipCertificateCheck -Headers $headers `
        -Uri "https://$clusterIP/api/internal/report/$([Uri]::EscapeDataString($reportId))" | Out-Null
      Write-Host "Report '$reportName' deleted successfully." -ForegroundColor Green
    } catch {
      Write-Error "Failed to delete report: $($_.Exception.Message)"
      Remove-RubrikSession; exit 600
    }
    continue

  } else {
    Write-Error "Invalid selection: '$action'. Enter 1, 2, or 3."
    continue
  }

} ###### MAIN LOOP - END ######

Remove-RubrikSession
