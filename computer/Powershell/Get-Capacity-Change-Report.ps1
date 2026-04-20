<#
.SYNOPSIS
Calculates capacity changes for each object between time periods from an RSC "Object Capacity Over Time" CSV
and generates an email-friendly HTML report + detailed CSV.

.DESCRIPTION
The Get-Capacity-Change-Report script processes an RSC "Object Capacity Over Time" report CSV
and calculates capacity changes per object across configurable lookback periods.

The CSV can be provided locally via -csvPath, or pulled directly from RSC using
-RscServiceAccountJson and -reportID. Use -getRscReportList to list available reports.

The RSC report must be a "Capacity Over Time" type (also called "Object Capacity Over Time").
The report should be configured for the time range of interest:
- Time ranges up to 30 days produce daily capacity figures (one data point per day).
- Time ranges greater than 30 days produce monthly capacity figures (first of each month only).

The report must include these columns:
- Identity: Object Name, Cluster Name, Location, Object Type
- Capacity: Logical Bytes, Data Stored, Local Storage, Used Size, Provisioned Size,
            Archive Storage, Replica Storage
- Time: Time (date column)

The 4-part unique key (Cluster Name + Object Name + Location + Object Type) identifies each object.

It tracks 5 capacity metrics:
- Logical Bytes / Provisioned Size (front-end provisioned size)
- Used Size (consumed bytes on source disk)
- Data Stored / Local Storage (Rubrik storage after data reduction, across retention)
- Archive Storage (data in archive target)
- Replica Storage (data on replication target)

For equivalent field pairs (Data Stored / Local Storage, Logical Bytes / Provisioned Size),
the script backfills using the larger value when one is missing.

Objects present in older dates but missing at the baseline are marked as "Deleted" with negative changes.
Objects present at baseline but not in older dates are treated as net new with full positive changes.

Output:
- HTML report (email-safe, inline styles) with summary table and top N tables per comparison period
- CSV with all objects and all capacity values + changes

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 4/19/26
Updated: 4/19/26

Requires PowerShell 7+ when using RSC mode (-RscServiceAccountJson).

.PARAMETER csvPath
Path to the RSC "Object Capacity Over Time" CSV file. Use this for local/offline mode.
Mutually exclusive with -RscServiceAccountJson.

.PARAMETER RscServiceAccountJson
Path to the RSC Service Account JSON file (must contain client_id, client_secret, access_token_uri).
When provided, either -reportID or -getRscReportList must also be specified.
Mutually exclusive with -csvPath.

.PARAMETER reportID
RSC Report ID to pull and process. Use with -RscServiceAccountJson.
Use -getRscReportList to find report IDs.

.PARAMETER getRscReportList
List available "Capacity Over Time" reports from RSC and exit.
Use with -RscServiceAccountJson.

.PARAMETER rscReportCSVOutputPrefix
Location and prefix for the downloaded RSC report CSV file. The timestamp is appended automatically.
Output filename: <prefix><YYYY-MM-DD_HHMM>.csv
To write to a subdirectory, include the path (e.g. "./reports/rsc_capacity_"). The directory must already exist.
Default: "./rsc_capacity_over_time_report_"

.PARAMETER compDates
Override default lookback periods. Daily default: @(-7, -14, -30). Monthly default: @(-1, -3, -6, -12).

.PARAMETER topNum
Number of top objects to show per comparison period in the HTML report. Default: 20.

.PARAMETER csvOutputPrefix
Location and prefix for the output CSV file. The report name and timestamp are appended automatically.
Output filename: <prefix>capacity_change_report-<YYYY-MM-DD_HHMM>.csv
To write to a subdirectory, include the path (e.g. "./reports/rubrik_"). The directory must already exist.
Default: "./rubrik_"

.PARAMETER htmlOutputPrefix
Location and prefix for the output HTML file. The report name and timestamp are appended automatically.
Output filename: <prefix>capacity_change_report-<YYYY-MM-DD_HHMM>.html
To write to a subdirectory, include the path (e.g. "./reports/rubrik_"). The directory must already exist.
Default: "./rubrik_"

.PARAMETER sendEmail
Switch to send the HTML report via email with the CSV as an attachment.

.PARAMETER emailTo
Array of email addresses to send the report to. Required if -sendEmail is used.

.PARAMETER emailFrom
Sender email address. Required if -sendEmail is used.

.PARAMETER SMTPServer
SMTP server hostname. Required if -sendEmail is used.

.PARAMETER SMTPPort
SMTP server port. Default: 25.

.EXAMPLE
./Get-Capacity-Change-Report.ps1 -RscServiceAccountJson "./rsc-sa.json" -getRscReportList
List available Capacity Over Time reports from RSC. Use the report ID with -reportID.

.EXAMPLE
./Get-Capacity-Change-Report.ps1 -RscServiceAccountJson "./rsc-sa.json" -reportID 143
Pull report ID 143 from RSC and process it with default settings.

.EXAMPLE
./Get-Capacity-Change-Report.ps1 -RscServiceAccountJson "./rsc-sa.json" -reportID 143 -rscReportCSVOutputPrefix "./reports/rsc_capacity_"
Pull report and save the raw CSV to ./reports/ with a custom prefix before processing.

.EXAMPLE
./Get-Capacity-Change-Report.ps1 -csvPath "./rsc_object_capacity_over_time_past_30_days.csv"
Process a local 30-day daily report with default lookback periods (-7, -14, -30 days).

.EXAMPLE
./Get-Capacity-Change-Report.ps1 -csvPath "./rsc_object_capacity_over_time_past_12_months.csv"
Process a local 12-month monthly report with default lookback periods (-1, -3, -6, -12 months).

.EXAMPLE
./Get-Capacity-Change-Report.ps1 -csvPath "./report.csv" -compDates @(-7, -14, -21) -topNum 30
Override lookback periods and show top 30 objects per period.

.EXAMPLE
./Get-Capacity-Change-Report.ps1 -csvPath "./report.csv" -csvOutputPrefix "./reports/customer_" -htmlOutputPrefix "./reports/customer_"
Output files to ./reports/ with prefix "customer_" (e.g. customer_capacity_change_report-2026-04-19_1200.csv).
#>

param (
  [CmdletBinding()]

  # Path to the RSC "Object Capacity Over Time" CSV (local/offline mode)
  [Parameter(Mandatory=$false)]
  [string]$csvPath,

  # Path to the RSC Service Account JSON file
  [Parameter(Mandatory=$false)]
  [string]$RscServiceAccountJson,

  # RSC Report ID to pull and process
  [Parameter(Mandatory=$false)]
  [int]$reportID,

  # List available "Capacity Over Time" reports from RSC and exit
  [Parameter(Mandatory=$false)]
  [switch]$getRscReportList,

  # Location and prefix for the downloaded RSC report CSV file. Timestamp is appended automatically.
  # To write to a subdirectory, include the path (e.g. "./reports/rsc_capacity_"). Directory must already exist.
  [Parameter(Mandatory=$false)]
  [string]$rscReportCSVOutputPrefix = './rsc_capacity_over_time_report_',

  # Override default lookback periods
  # Daily default: @(-7, -14, -30) — days back from baseline
  # Monthly default: @(-1, -3, -6, -12) — months back from baseline
  [Parameter(Mandatory=$false)]
  [int[]]$compDates,

  # Number of top objects to show per comparison period in HTML
  [Parameter(Mandatory=$false)]
  [int]$topNum = 20,

  # Location and prefix for output CSV file. Report name and timestamp are appended automatically.
  # To write to a subdirectory, include the path (e.g. "./reports/rubrik_"). Directory must already exist.
  [Parameter(Mandatory=$false)]
  [string]$csvOutputPrefix = './rubrik_',

  # Location and prefix for output HTML file. Report name and timestamp are appended automatically.
  # To write to a subdirectory, include the path (e.g. "./reports/rubrik_"). Directory must already exist.
  [Parameter(Mandatory=$false)]
  [string]$htmlOutputPrefix = './rubrik_',

  # Send email with HTML body and CSV attachment
  [Parameter(Mandatory=$false)]
  [switch]$sendEmail,

  # SMTP configuration (only used if -sendEmail)
  [Parameter(Mandatory=$false)]
  [string[]]$emailTo,
  [Parameter(Mandatory=$false)]
  [string]$emailFrom,
  [Parameter(Mandatory=$false)]
  [string]$SMTPServer,
  [Parameter(Mandatory=$false)]
  [string]$SMTPPort = '25'
)

### INPUT MODE VALIDATION ###

if ($csvPath -and $RscServiceAccountJson) {
  Write-Error "Specify either -csvPath or -RscServiceAccountJson, not both."
  exit 1
}

if ($RscServiceAccountJson) {
  if (-not $PSBoundParameters.ContainsKey('reportID') -and -not $getRscReportList) {
    Write-Error "When using -RscServiceAccountJson, either -reportID or -getRscReportList must be specified."
    exit 1
  }
  # Require PowerShell 7+ for RSC mode
  if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "PowerShell 7+ is required for RSC mode. Current version: $($PSVersionTable.PSVersion)"
    exit 1
  }
} else {
  if (-not $csvPath) {
    Write-Host ""
    Write-Host "Rubrik Capacity Change Report" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  List RSC reports:   ./Get-Capacity-Change-Report.ps1 -RscServiceAccountJson `"./rsc-sa.json`" -getRscReportList"
    Write-Host "  Pull & process:     ./Get-Capacity-Change-Report.ps1 -RscServiceAccountJson `"./rsc-sa.json`" -reportID <ID>"
    Write-Host "  Process local CSV:  ./Get-Capacity-Change-Report.ps1 -csvPath `"./report.csv`""
    Write-Host ""
    Write-Host "Run 'Get-Help ./Get-Capacity-Change-Report.ps1 -Detailed' for full documentation."
    Write-Host ""
    exit 0
  }
}

### VARIABLES - BEGIN ###
$date = Get-Date
$bytesPerGB = 1000000000
$bytesPerTB = 1000000000000

# Capacity field names in the CSV
$metricFields = @{
  LogicalBytes   = 'Logical Bytes'
  ProvisionedSize = 'Provisioned Size'
  UsedSize       = 'Used Size'
  DataStored     = 'Data Stored'
  LocalStorage   = 'Local Storage'
  ArchiveStorage = 'Archive Storage'
  ReplicaStorage = 'Replica Storage'
}

# The 5 metrics we track (after backfill, these are the canonical names)
$trackedMetrics = @('LogicalBytes', 'UsedSize', 'DataStored', 'ArchiveStorage', 'ReplicaStorage')

# HTML colors
$rubrikColor = '#00B2A9'
$changePositiveColor = '#D4870F'
$changeNegativeColor = '#2E8B57'
$changeZeroColor = '#999999'
$zebraColor = '#f9f9f9'
### VARIABLES - END ###

### FUNCTIONS - BEGIN ###

# Parse a capacity value from CSV — handles numeric, empty, "N/A", "-", etc.
function Parse-CapacityValue {
  param([string]$value)
  if ([string]::IsNullOrWhiteSpace($value) -or $value -eq 'N/A' -or $value -eq '-') {
    return [double]0
  }
  $parsed = 0.0
  if ([double]::TryParse($value, [ref]$parsed)) {
    return [math]::Max($parsed, 0)
  }
  return [double]0
}

# Format a number with comma separators and specified decimal places
function Format-Number {
  param(
    [double]$value,
    [int]$decimals = 2
  )
  return $value.ToString("N$decimals")
}

# Get conditional color for a change value
function Get-ChangeColor {
  param([double]$value)
  if ($value -gt 0) { return $changePositiveColor }
  elseif ($value -lt 0) { return $changeNegativeColor }
  else { return $changeZeroColor }
}

# Convert bytes to GB
function ConvertTo-GB {
  param([double]$bytes)
  return [math]::Round($bytes / $bytesPerGB, 2)
}

# Convert bytes to TB
function ConvertTo-TB {
  param([double]$bytes)
  return [math]::Round($bytes / $bytesPerTB, 3)
}

# Get paginated list of all custom reports from RSC
Function Get-RSCReports {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$false)]
    [string]$afterCursor = ''
  )
  $variables = @{
    "first"     = 200
    "sortBy"    = "NAME"
    "sortOrder" = "ASC"
  }
  if ($afterCursor -ne '') {
    $variables.after = $afterCursor
  }
  $query = "query CustomReportsListQuery(`$first: Int!, `$after: String, `$sortBy: CustomReportSortByField, `$sortOrder: SortOrder) {
  customReports(
    first: `$first
    after: `$after
    sortBy: `$sortBy
    sortOrder: `$sortOrder
  ) {
    edges {
      cursor
      node {
        id
        name
        reportViewType
        reportCategory
        room
        createdAt
        updatedAt
        createdBy
        updatedBy
        scheduledReportsCount
        reportFilters {
          name
          values
        }
      }
    }
    pageInfo {
      endCursor
      hasNextPage
    }
    count
  }
}"
  $payload = @{
    "query"     = $query
    "variables" = $variables
  }
  $result = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-Json -Depth 100) -Headers $headers
  if ($result.errors) {
    Write-Error "GraphQL error: $($result.errors | ConvertTo-Json -Compress)"
    return $null
  }
  return $result.data.customReports
}

# Trigger generating a CSV for a report (async)
Function Generate-ReportCSV {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [int]$reportID
  )
  $variables = @{
    "id" = $reportID
  }
  $query = "mutation (`$id: Int!, `$config: CustomReportCreate) {
    downloadReportCsvAsync(input: {id: `$id, config: `$config}) {
      jobId
      referenceId
      __typename
    }
  }"
  $payload = @{
    "query"     = $query
    "variables" = $variables
  }
  $response = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-Json -Depth 100) -Headers $headers
  if ($response.errors) {
    Write-Error "GraphQL error: $($response.errors | ConvertTo-Json -Compress)"
    return $null
  }
  return $response.data.downloadReportCsvAsync
}

# Get the CSV download status
Function Get-DownloadStatus {
  $query = "query DownloadBarQuery {
  getUserDownloads {
    id
    name
    status
    progress
    identifier
    createTime
    completeTime
    __typename
  }
  allUserFiles {
    downloads {
      externalId
      createdAt
      expiresAt
      completedAt
      creator
      filename
      type
      state
      __typename
    }
    __typename
  }
}"
  $payload = @{
    "query" = $query
  }
  $response = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-Json -Depth 100) -Headers $headers
  return $response.data.allUserFiles.downloads
}

# Get report name by ID using the report list
Function Get-ReportNameByID {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [int]$reportID,
    [Parameter(Mandatory=$false)]
    [object[]]$reportList = @()
  )
  # Check local list first
  $match = $reportList | Where-Object { $_.id -eq $reportID } | Select-Object -First 1
  if ($null -ne $match) { return $match.name }
  # Fall back to querying RSC
  $variables = @{
    "polarisReportsFilters" = @(
      @{
        "field" = "FILTER_UNSPECIFIED"
        "reportRooms" = @("REPORT_ROOM_NONE")
      }
    )
  }
  $query = "query (`$polarisReportsFilters: [PolarisReportsFilterInput!]) {
    allRscReportConfigs(polarisReportsFilters: `$polarisReportsFilters) {
      id
      name
      reportViewType
    }
  }"
  $payload = @{
    "query"     = $query
    "variables" = $variables
  }
  $result = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-Json -Depth 100) -Headers $headers
  $reportName = ($result.data.allRscReportConfigs | Where-Object { $_.id -eq $reportID }).name
  return $reportName
}

# Trigger CSV download and return the download URL
Function Get-ReportCSVLink {
  param (
    [CmdletBinding()]
    [Parameter(Mandatory=$true)]
    [int]$reportID,
    [Parameter(Mandatory=$false)]
    [string]$reportName = ''
  )
  # Get the report name if not provided
  if ($reportName -eq '') {
    $reportName = Get-ReportNameByID -reportID $reportID
    if ($null -eq $reportName -or $reportName -eq '') {
      Write-Error "No report found for report ID: $reportID"
      return $null
    }
  }
  Write-Host "Generating CSV for report: $reportName (ID: $reportID)" -ForegroundColor Green
  # Trigger async CSV generation
  $csvJob = Generate-ReportCSV -reportID $reportID
  if ($null -eq $csvJob) {
    Write-Error "Failed to trigger CSV generation."
    return $null
  }
  # Poll for download readiness
  $downloadStatus = Get-DownloadStatus
  $matchingReports = $downloadStatus | Where-Object { $_.filename -match [regex]::Escape($reportName) }
  $jobToMonitor = $matchingReports[-1]
  Write-Host "Waiting for CSV to be ready, current status: $($jobToMonitor.state)"
  $maxAttempts = 60
  $attempt = 0
  do {
    Start-Sleep -Seconds 10
    $downloadStatus = Get-DownloadStatus | Where-Object { $_.externalId -eq $jobToMonitor.externalId }
    $attempt++
    Write-Host "Waiting for CSV to be ready, current status: $($downloadStatus.state) (attempt $attempt/$maxAttempts)"
  } while ($downloadStatus.state -notmatch 'READY' -and $attempt -lt $maxAttempts)
  if ($downloadStatus.state -notmatch 'READY') {
    Write-Error "CSV generation timed out after $maxAttempts attempts."
    return $null
  }
  $downloadURL = $rubrikURL + '/file-downloads/' + $jobToMonitor.externalId
  return $downloadURL
}

### FUNCTIONS - END ###

###### RSC AUTHENTICATION ######

if ($RscServiceAccountJson) {
  Write-Host "`nReading Service Account file: $RscServiceAccountJson"
  try {
    $serviceAccountFile = Get-Content -Path "$RscServiceAccountJson" -ErrorAction Stop | ConvertFrom-Json
  } catch {
    Write-Error "Failed to read Service Account JSON at '$RscServiceAccountJson': $($_.Exception.Message)"
    exit 1
  }

  # Validate required fields
  $missingFields = @()
  if ($null -eq $serviceAccountFile.client_id) { $missingFields += 'client_id' }
  if ($null -eq $serviceAccountFile.client_secret) { $missingFields += 'client_secret' }
  if ($null -eq $serviceAccountFile.access_token_uri) { $missingFields += 'access_token_uri' }

  if ($missingFields.Count -gt 0) {
    Write-Error "Service Account JSON is missing required fields: $($missingFields -join ', ')"
    exit 1
  }

  # Exchange credentials for bearer token
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
}

###### RSC REPORT LIST MODE ######

if ($getRscReportList) {
  Write-Host "`nQuerying RSC reports list..."

  $allReports = @()
  $afterCursor = ''
  do {
    $reportPage = Get-RSCReports -afterCursor $afterCursor
    if ($null -eq $reportPage) {
      Write-Error "Failed to retrieve reports list."
      exit 1
    }
    $allReports += $reportPage.edges.node
    $afterCursor = $reportPage.pageInfo.endCursor
  } while ($reportPage.pageInfo.hasNextPage)

  # Filter to Capacity Over Time reports
  $capacityReports = @()
  foreach ($r in $allReports) {
    $viewType = if ($r.reportViewType) { $r.reportViewType -replace '_REPORT$', '' -replace '_', ' ' } else { '' }
    if ($viewType -like '*capacity*time*') {
      $capacityReports += [PSCustomObject]@{
        ID       = $r.id
        Name     = $r.name
        ViewType = $viewType
        Category = if ($r.reportCategory) { $r.reportCategory -replace '_', ' ' } else { '' }
      }
    }
  }

  if ($capacityReports.Count -eq 0) {
    Write-Host "`nNo Capacity Over Time reports found." -ForegroundColor Yellow
    exit 0
  }

  Write-Host "`nCapacity Over Time reports are shown below. Use -reportID <ID> to run the script with that report." -ForegroundColor Cyan
  Write-Host ""

  $wID     = [Math]::Max(2, ($capacityReports | ForEach-Object { "$($_.ID)".Length } | Measure-Object -Maximum).Maximum)
  $wName   = [Math]::Max(4, [Math]::Min(60, ($capacityReports | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum))
  $wView   = [Math]::Max(9, [Math]::Min(40, ($capacityReports | ForEach-Object { $_.ViewType.Length } | Measure-Object -Maximum).Maximum))
  $wCat    = [Math]::Max(8, [Math]::Min(30, ($capacityReports | ForEach-Object { $_.Category.Length } | Measure-Object -Maximum).Maximum))

  $hdr = "{0,-$wID}  {1,-$wName}  {2,-$wView}  {3,-$wCat}" -f 'ID','Name','View Type','Category'
  Write-Host $hdr
  Write-Host ('-' * $hdr.Length)

  foreach ($row in $capacityReports) {
    $nameDisplay = if ($row.Name.Length -gt $wName) { $row.Name.Substring(0, $wName - 3) + '...' } else { $row.Name }
    Write-Host ("{0,-$wID}  " -f $row.ID) -NoNewline
    Write-Host ("{0,-$wName}  " -f $nameDisplay) -NoNewline -ForegroundColor Cyan
    Write-Host ("{0,-$wView}  {1,-$wCat}" -f $row.ViewType, $row.Category)
  }

  Write-Host ""
  exit 0
}

###### RSC REPORT PULL MODE ######

if ($RscServiceAccountJson -and $PSBoundParameters.ContainsKey('reportID')) {
  Write-Host "`nPulling report ID: $reportID from RSC..." -ForegroundColor Cyan

  $csvLink = Get-ReportCSVLink -reportID $reportID
  if ($null -eq $csvLink) {
    Write-Error "Failed to get CSV download link for report ID: $reportID"
    exit 1
  }

  $outputTimestampRsc = $date.ToString('yyyy-MM-dd_HHmm')
  $rscCsvOutputPath = "${rscReportCSVOutputPrefix}${outputTimestampRsc}.csv"

  Write-Host "Downloading CSV..."
  try {
    Invoke-WebRequest -Uri $csvLink -OutFile $rscCsvOutputPath -Headers $headers -SkipCertificateCheck
  } catch {
    Write-Error "Failed to download CSV: $($_.Exception.Message)"
    exit 1
  }

  $rowCount = (Get-Content $rscCsvOutputPath | Measure-Object -Line).Lines - 1
  Write-Host "RSC report CSV saved to: $rscCsvOutputPath ($rowCount rows)" -ForegroundColor Green

  # Set csvPath to the downloaded file and continue to processing
  $csvPath = $rscCsvOutputPath
}

###### PHASE 1: LOAD, FILTER & DETECT GRANULARITY ######

Write-Host "`nLoading CSV: $csvPath" -ForegroundColor Cyan

if (!(Test-Path -Path $csvPath)) {
  Write-Error "CSV file not found: $csvPath"
  exit 1
}

$rawData = Import-Csv -Path $csvPath
$totalRawRows = $rawData.Count
Write-Host "Loaded $totalRawRows rows"

# Validate required columns
$requiredColumns = @(
  'Time', 'Cluster Name', 'Object Name', 'Location', 'Object Type',
  'Logical Bytes', 'Data Stored', 'Local Storage', 'Archive Storage', 'Replica Storage',
  'Used Size', 'Provisioned Size'
)
$csvColumns = $rawData[0].PSObject.Properties.Name
$missingColumns = $requiredColumns | Where-Object { $_ -notin $csvColumns }
if ($missingColumns.Count -gt 0) {
  Write-Host "`nERROR: CSV is missing required columns: $($missingColumns -join ', ')" -ForegroundColor Red
  Write-Host ""
  Write-Host "The RSC report must include these columns. To fix this, edit the report in RSC and ensure"
  Write-Host "the following table columns are selected:"
  Write-Host "  - Identity: Object Name, Cluster Name, Location, Object Type"
  Write-Host "  - Capacity: Logical Bytes, Data Stored, Local Storage, Used Size, Provisioned Size,"
  Write-Host "              Archive Storage, Replica Storage"
  Write-Host "  - Time: Time (date column)"
  exit 1
}

# Filter out rows where all capacity fields are zero/empty
$filteredData = @()
foreach ($row in $rawData) {
  $hasCapacity = $false
  foreach ($field in $metricFields.Values) {
    $val = Parse-CapacityValue $row.$field
    if ($val -gt 0) {
      $hasCapacity = $true
      break
    }
  }
  if ($hasCapacity) {
    $filteredData += $row
  }
}
Write-Host "Filtered to $($filteredData.Count) rows with capacity data (removed $($totalRawRows - $filteredData.Count) zero-capacity rows)"

if ($filteredData.Count -eq 0) {
  Write-Error "No rows with capacity data found in CSV."
  exit 1
}

# Detect granularity from the Time field
$sampleTime = $filteredData[0].Time
$isMonthly = $false
$isDaily = $false

# Monthly format: "MMM YYYY" (e.g. "Feb 2026")
# Daily format: "MMM DD, YYYY" (e.g. "Apr 01, 2026")
if ($sampleTime -match '^\w{3} \d{4}$') {
  $isMonthly = $true
  $reportType = 'Monthly'
  if (-not $compDates) { $compDates = @(-1, -3, -6, -12) }
  Write-Host "Detected report type: Monthly" -ForegroundColor Green
} elseif ($sampleTime -match '^\w{3} \d{2}, \d{4}$') {
  $isDaily = $true
  $reportType = 'Daily'
  if (-not $compDates) { $compDates = @(-7, -14, -30) }
  Write-Host "Detected report type: Daily" -ForegroundColor Green
} else {
  Write-Error "Unrecognized Time format: '$sampleTime'. Expected 'MMM DD, YYYY' (daily) or 'MMM YYYY' (monthly)."
  exit 1
}

# Parse all dates and get sorted distinct list
$dateMap = @{}  # string -> datetime
foreach ($row in $filteredData) {
  $timeStr = $row.Time
  if (-not $dateMap.ContainsKey($timeStr)) {
    if ($isMonthly) {
      $dateMap[$timeStr] = [datetime]::ParseExact("01 $timeStr", "dd MMM yyyy", $null)
    } else {
      $dateMap[$timeStr] = [datetime]::ParseExact($timeStr, "MMM dd, yyyy", $null)
    }
  }
}

$distinctDates = $dateMap.Values | Sort-Object
$baselineDate = $distinctDates[-1]
$oldestDate = $distinctDates[0]

Write-Host "Date range: $($oldestDate.ToString('yyyy-MM-dd')) to $($baselineDate.ToString('yyyy-MM-dd')) ($($distinctDates.Count) distinct dates)"

# Edge case: only one date
if ($distinctDates.Count -eq 1) {
  Write-Host "`nWARNING: Only one date found in CSV — no comparisons possible, outputting summary only." -ForegroundColor Yellow
  $compDates = @()
}

###### PHASE 2: RESOLVE COMPARISON DATES ######

$resolvedCompDates = @()  # Array of hashtables: @{ Label = "-7 Days"; Date = [datetime]; LookbackValue = -7 }

foreach ($comp in $compDates) {
  if ($isDaily) {
    $targetDate = $baselineDate.AddDays($comp)
    $label = "$comp Days"
  } else {
    $targetDate = $baselineDate.AddMonths($comp)
    $label = "$comp Months"
  }

  # Find the exact date or clamp to oldest
  $matchedDate = $null
  foreach ($d in $distinctDates) {
    if ($d.Date -eq $targetDate.Date) {
      $matchedDate = $d
      break
    }
  }

  if ($null -eq $matchedDate) {
    # Target date not in CSV — use oldest and stop adding further lookbacks
    $matchedDate = $oldestDate
    $daysDiff = [math]::Round(($baselineDate - $oldestDate).TotalDays)

    if ($isDaily) {
      $label = "-$daysDiff Days"
    } else {
      $monthsDiff = (($baselineDate.Year - $oldestDate.Year) * 12) + ($baselineDate.Month - $oldestDate.Month)
      $label = "-$monthsDiff Months"
    }

    # Check if this date is already in resolved list
    $alreadyExists = $false
    foreach ($existing in $resolvedCompDates) {
      if ($existing.Date.Date -eq $matchedDate.Date) {
        $alreadyExists = $true
        break
      }
    }

    if (-not $alreadyExists) {
      $resolvedCompDates += @{
        Label = $label
        Date = $matchedDate
        LookbackValue = $comp
      }
    }
    # Stop — all further lookbacks would be even older
    break
  }

  # Check for duplicates
  $alreadyExists = $false
  foreach ($existing in $resolvedCompDates) {
    if ($existing.Date.Date -eq $matchedDate.Date) {
      $alreadyExists = $true
      break
    }
  }

  if (-not $alreadyExists) {
    $resolvedCompDates += @{
      Label = $label
      Date = $matchedDate
      LookbackValue = $comp
    }
  }
}

Write-Host "`nBaseline date: $($baselineDate.ToString('yyyy-MM-dd'))"
foreach ($rc in $resolvedCompDates) {
  Write-Host "  Comparison: $($rc.Label) -> $($rc.Date.ToString('yyyy-MM-dd'))"
}

###### PHASE 3: BUILD UNIQUE IDS, BACKFILL & STORE IN HASHTABLE ######

Write-Host "`nBuilding object hashtable..." -ForegroundColor Cyan

$objectData = @{}
$duplicates = [System.Collections.ArrayList]::new()
$processedRows = 0
$totalRows = $filteredData.Count

foreach ($row in $filteredData) {
  $processedRows++
  if ($processedRows % 5000 -eq 0) {
    $pct = [math]::Round(($processedRows / $totalRows) * 100)
    Write-Host "  Loading... $pct% ($processedRows / $totalRows)"
  }

  # Build unique key (4-part: Cluster+Name+Location+Type to avoid collisions across object types)
  $uniqueKey = "$($row.'Cluster Name')+$($row.'Object Name')+$($row.Location)+$($row.'Object Type')"

  # Parse the date for this row
  $rowDate = $dateMap[$row.Time]

  # Parse and backfill capacity values
  $logicalBytes = Parse-CapacityValue $row.$($metricFields.LogicalBytes)
  $provisionedSize = Parse-CapacityValue $row.$($metricFields.ProvisionedSize)
  $usedSize = Parse-CapacityValue $row.$($metricFields.UsedSize)
  $dataStored = Parse-CapacityValue $row.$($metricFields.DataStored)
  $localStorage = Parse-CapacityValue $row.$($metricFields.LocalStorage)
  $archiveStorage = Parse-CapacityValue $row.$($metricFields.ArchiveStorage)
  $replicaStorage = Parse-CapacityValue $row.$($metricFields.ReplicaStorage)

  # Backfill: take the max of equivalent pairs
  $logicalBytesBackfilled = [math]::Max($logicalBytes, $provisionedSize)
  $dataStoredBackfilled = [math]::Max($dataStored, $localStorage)

  $capacityValues = @{
    LogicalBytes   = $logicalBytesBackfilled
    UsedSize       = $usedSize
    DataStored     = $dataStoredBackfilled
    ArchiveStorage = $archiveStorage
    ReplicaStorage = $replicaStorage
  }

  # Initialize object entry if it doesn't exist
  if (-not $objectData.ContainsKey($uniqueKey)) {
    $objectData[$uniqueKey] = @{
      ObjectName         = $row.'Object Name'
      ClusterName        = $row.'Cluster Name'
      Location           = $row.Location
      ObjectType         = $row.'Object Type'
      SLADomain          = $row.'SLA Domain'
      ProtectedOn        = $row.'Protected On'
      LocalDataReduction = $row.'Local Data Reduction'
      LocalDedupRatio    = $row.'Local Dedup Ratio'
      MostRecentDate     = $rowDate
      Dates              = @{}
    }
  }

  # Update metadata if this row is more recent
  if ($rowDate -gt $objectData[$uniqueKey].MostRecentDate) {
    $objectData[$uniqueKey].MostRecentDate = $rowDate
    $objectData[$uniqueKey].ObjectType = $row.'Object Type'
    $objectData[$uniqueKey].SLADomain = $row.'SLA Domain'
    $objectData[$uniqueKey].ProtectedOn = $row.'Protected On'
    $objectData[$uniqueKey].LocalDataReduction = $row.'Local Data Reduction'
    $objectData[$uniqueKey].LocalDedupRatio = $row.'Local Dedup Ratio'
  }

  # Check for duplicate key + date
  $dateKey = $rowDate.ToString('yyyy-MM-dd')
  if ($objectData[$uniqueKey].Dates.ContainsKey($dateKey)) {
    # Keep the one with higher DataStored
    $existingDS = $objectData[$uniqueKey].Dates[$dateKey].DataStored
    if ($dataStoredBackfilled -gt $existingDS) {
      $objectData[$uniqueKey].Dates[$dateKey] = $capacityValues
    }
    [void]$duplicates.Add(@{
      UniqueKey = $uniqueKey
      Date = $dateKey
      ExistingDataStored = $existingDS
      NewDataStored = $dataStoredBackfilled
    })
  } else {
    $objectData[$uniqueKey].Dates[$dateKey] = $capacityValues
  }
}

Write-Host "Built hashtable: $($objectData.Count) unique objects"
if ($duplicates.Count -gt 0) {
  Write-Host "  Duplicates found: $($duplicates.Count) (kept higher Data Stored value)" -ForegroundColor Yellow
}

###### PHASE 4: CALCULATE DIFFS ######

Write-Host "`nCalculating capacity changes..." -ForegroundColor Cyan

$baselineDateKey = $baselineDate.ToString('yyyy-MM-dd')
$results = [System.Collections.ArrayList]::new()
$processedObjs = 0
$totalObjs = $objectData.Count

foreach ($entry in $objectData.GetEnumerator()) {
  $processedObjs++
  if ($processedObjs % 500 -eq 0) {
    $pct = [math]::Round(($processedObjs / $totalObjs) * 100)
    Write-Host "  Processing... $pct% ($processedObjs / $totalObjs)"
  }

  $key = $entry.Key
  $obj = $entry.Value

  # Determine status
  $existsAtBaseline = $obj.Dates.ContainsKey($baselineDateKey)
  $status = if ($existsAtBaseline) { 'Active' } else { 'Deleted' }

  # Baseline values (0 if deleted)
  if ($existsAtBaseline) {
    $baselineValues = $obj.Dates[$baselineDateKey]
  } else {
    $baselineValues = @{
      LogicalBytes = [double]0; UsedSize = [double]0; DataStored = [double]0
      ArchiveStorage = [double]0; ReplicaStorage = [double]0
    }
  }

  # Build result object
  $resultObj = @{
    UniqueKey          = $key
    ObjectName         = $obj.ObjectName
    ClusterName        = $obj.ClusterName
    Location           = $obj.Location
    ObjectType         = $obj.ObjectType
    Status             = $status
    SLADomain          = $obj.SLADomain
    ProtectedOn        = $obj.ProtectedOn
    LocalDataReduction = $obj.LocalDataReduction
    LocalDedupRatio    = $obj.LocalDedupRatio
    Baseline           = $baselineValues
    Comparisons        = @{}
  }

  # Calculate diffs for each comparison date
  foreach ($rc in $resolvedCompDates) {
    $compDateKey = $rc.Date.ToString('yyyy-MM-dd')
    $label = $rc.Label

    if ($obj.Dates.ContainsKey($compDateKey)) {
      $compValues = $obj.Dates[$compDateKey]
    } else {
      $compValues = @{
        LogicalBytes = [double]0; UsedSize = [double]0; DataStored = [double]0
        ArchiveStorage = [double]0; ReplicaStorage = [double]0
      }
    }

    $changes = @{}
    foreach ($metric in $trackedMetrics) {
      $changes[$metric] = @{
        OldValue = $compValues[$metric]
        Change   = $baselineValues[$metric] - $compValues[$metric]
      }
    }

    $resultObj.Comparisons[$label] = $changes
  }

  [void]$results.Add($resultObj)
}

Write-Host "Calculated changes for $($results.Count) objects"
$activeCount = ($results | Where-Object { $_.Status -eq 'Active' }).Count
$deletedCount = ($results | Where-Object { $_.Status -eq 'Deleted' }).Count
Write-Host "  Active: $activeCount | Deleted: $deletedCount"

###### PHASE 5: BUILD SUMMARY TABLE ######

Write-Host "`nBuilding summary..." -ForegroundColor Cyan

# Collect all object types dynamically
$allObjectTypes = $results | ForEach-Object { $_.ObjectType } | Sort-Object -Unique

# Build summary for each date (baseline + comparison dates)
$summaryDates = @(@{ Label = "Baseline $($baselineDate.ToString('yyyy-MM-dd'))"; DateKey = $baselineDateKey })
foreach ($rc in $resolvedCompDates) {
  $summaryDates += @{
    Label = "$($rc.Date.ToString('yyyy-MM-dd')) ($($rc.Label))"
    DateKey = $rc.Date.ToString('yyyy-MM-dd')
  }
}

$summaryArray = @()
foreach ($sd in $summaryDates) {
  $dateKey = $sd.DateKey

  # Sum capacities across all objects that have data on this date
  $totalLogical = [double]0
  $totalDataStored = [double]0
  $totalArchive = [double]0
  $totalReplica = [double]0
  $typeCounts = @{}
  $totalObjects = 0

  foreach ($obj in $objectData.Values) {
    if ($obj.Dates.ContainsKey($dateKey)) {
      $vals = $obj.Dates[$dateKey]
      $totalLogical += $vals.LogicalBytes
      $totalDataStored += $vals.DataStored
      $totalArchive += $vals.ArchiveStorage
      $totalReplica += $vals.ReplicaStorage

      $objType = $obj.ObjectType
      if (-not $typeCounts.ContainsKey($objType)) {
        $typeCounts[$objType] = 0
      }
      $typeCounts[$objType]++
      $totalObjects++
    }
  }

  $summaryEntry = @{
    Label           = $sd.Label
    LogicalTB       = ConvertTo-TB $totalLogical
    DataStoredTB    = ConvertTo-TB $totalDataStored
    ArchiveTB       = ConvertTo-TB $totalArchive
    ReplicaTB       = ConvertTo-TB $totalReplica
    TotalObjects    = $totalObjects
    TypeCounts      = $typeCounts
  }

  $summaryArray += $summaryEntry
}

###### PHASE 6: TOP N SELECTION ######

Write-Host "Selecting top $topNum objects per comparison period..." -ForegroundColor Cyan

$topResultsPerPeriod = @{}
foreach ($rc in $resolvedCompDates) {
  $label = $rc.Label

  # Sort by DataStored change descending (largest growth first)
  $sorted = $results | Where-Object { $_.Comparisons.ContainsKey($label) } |
    Sort-Object { $_.Comparisons[$label].DataStored.Change } -Descending

  $topN = @()
  $count = 0
  foreach ($item in $sorted) {
    if ($count -ge $topNum) { break }
    $topN += $item
    $count++
  }

  $topResultsPerPeriod[$label] = $topN
}

###### PHASE 7: GENERATE OUTPUTS ######

Write-Host "`nGenerating outputs..." -ForegroundColor Cyan

$csvFilename = Split-Path -Leaf $csvPath
$outputTimestamp = $date.ToString('yyyy-MM-dd_HHmm')
$htmlOutputPath = "${htmlOutputPrefix}capacity_change_report-${outputTimestamp}.html"
$csvOutputPath = "${csvOutputPrefix}capacity_change_report-${outputTimestamp}.csv"

### BUILD HTML ###

$baseFont = "font-family:Arial,sans-serif;"
$headerBarStyle = "background-color:$rubrikColor;color:white;font-size:20px;padding:16px;$baseFont"
$infoStyle = "font-size:13px;color:#333333;padding:4px 0;$baseFont"
$thStyle = "text-align:center;padding:8px;border-bottom:1px solid #ddd;background-color:white;color:$rubrikColor;font-size:12px;font-weight:bold;$baseFont"
$thLeftStyle = "text-align:left;padding:8px;border-bottom:1px solid #ddd;background-color:white;color:$rubrikColor;font-size:12px;font-weight:bold;$baseFont"
$tdStyle = "text-align:center;padding:6px 8px;border-bottom:1px solid #ddd;font-size:12px;$baseFont"
$tdLeftStyle = "text-align:left;padding:6px 8px;border-bottom:1px solid #ddd;font-size:12px;$baseFont"
$sectionHeaderStyle = "text-align:left;padding:12px;font-size:15px;font-weight:bold;color:#333333;background-color:#f5f5f5;$baseFont"

$html = [System.Text.StringBuilder]::new()

# HTML start
[void]$html.AppendLine("<!DOCTYPE html><html><body style=`"margin:0;padding:0;$baseFont`">")

# Header bar
[void]$html.AppendLine("<table width=`"100%`" cellpadding=`"0`" cellspacing=`"0`"><tr><td style=`"$headerBarStyle`">Rubrik Capacity Change Report</td></tr></table>")

# Report info
[void]$html.AppendLine("<div style=`"padding:12px 16px;`">")
[void]$html.AppendLine("<p style=`"$infoStyle`"><b>Report Generated:</b> $($date.ToString('yyyy-MM-dd HH:mm'))</p>")
[void]$html.AppendLine("<p style=`"$infoStyle`"><b>Source CSV:</b> $csvFilename</p>")
[void]$html.AppendLine("<p style=`"$infoStyle`"><b>Report Type:</b> $reportType ($($distinctDates.Count) data points)</p>")
[void]$html.AppendLine("<p style=`"$infoStyle`"><b>Baseline Date:</b> $($baselineDate.ToString('yyyy-MM-dd'))</p>")
[void]$html.AppendLine("<p style=`"$infoStyle`"><b>Total Objects:</b> $($objectData.Count) (Active: $activeCount, Deleted: $deletedCount)</p>")
[void]$html.AppendLine("</div>")

# Summary table
[void]$html.AppendLine("<div style=`"padding:0 16px;`">")
[void]$html.AppendLine("<table width=`"100%`" cellpadding=`"0`" cellspacing=`"0`" style=`"border-collapse:collapse;`">")

# Summary header row
[void]$html.Append("<tr>")
[void]$html.Append("<td style=`"$thStyle`">Date</td>")
[void]$html.Append("<td style=`"$thStyle`">Logical (TB)</td>")
[void]$html.Append("<td style=`"$thStyle`">Local Storage (TB)</td>")
[void]$html.Append("<td style=`"$thStyle`">Archive (TB)</td>")
[void]$html.Append("<td style=`"$thStyle`">Replica (TB)</td>")
[void]$html.Append("<td style=`"$thStyle`">Objects</td>")
foreach ($objType in $allObjectTypes) {
  [void]$html.Append("<td style=`"$thStyle`">$objType</td>")
}
[void]$html.AppendLine("</tr>")

# Summary data rows
$rowIndex = 0
foreach ($sumEntry in $summaryArray) {
  $bgColor = if ($rowIndex % 2 -eq 1) { "background-color:$zebraColor;" } else { "" }
  $rowIndex++

  [void]$html.Append("<tr>")
  [void]$html.Append("<td style=`"$tdStyle$bgColor`">$($sumEntry.Label)</td>")
  [void]$html.Append("<td style=`"$tdStyle$bgColor`">$(Format-Number $sumEntry.LogicalTB 3)</td>")
  [void]$html.Append("<td style=`"$tdStyle$bgColor font-weight:bold;`">$(Format-Number $sumEntry.DataStoredTB 3)</td>")
  [void]$html.Append("<td style=`"$tdStyle$bgColor`">$(Format-Number $sumEntry.ArchiveTB 3)</td>")
  [void]$html.Append("<td style=`"$tdStyle$bgColor`">$(Format-Number $sumEntry.ReplicaTB 3)</td>")
  [void]$html.Append("<td style=`"$tdStyle$bgColor font-weight:bold;`">$($sumEntry.TotalObjects)</td>")
  foreach ($objType in $allObjectTypes) {
    $typeCount = if ($sumEntry.TypeCounts.ContainsKey($objType)) { $sumEntry.TypeCounts[$objType] } else { 0 }
    [void]$html.Append("<td style=`"$tdStyle$bgColor`">$typeCount</td>")
  }
  [void]$html.AppendLine("</tr>")
}

[void]$html.AppendLine("</table>")
[void]$html.AppendLine("</div><br>")

# Top N tables per comparison period
foreach ($rc in $resolvedCompDates) {
  $label = $rc.Label
  $compDateStr = $rc.Date.ToString('yyyy-MM-dd')
  $topN = $topResultsPerPeriod[$label]

  [void]$html.AppendLine("<div style=`"padding:0 16px;`">")

  # Section header
  [void]$html.AppendLine("<table width=`"100%`" cellpadding=`"0`" cellspacing=`"0`" style=`"border-collapse:collapse;`">")
  [void]$html.AppendLine("<tr><td style=`"$sectionHeaderStyle`">Top $topNum — Local Storage Change: <span style=`"color:$changePositiveColor;`">$label</span> ($compDateStr)</td></tr>")
  [void]$html.AppendLine("</table>")

  # Data table
  [void]$html.AppendLine("<table width=`"100%`" cellpadding=`"0`" cellspacing=`"0`" style=`"border-collapse:collapse;`">")

  # Header row
  [void]$html.Append("<tr>")
  [void]$html.Append("<td style=`"$thLeftStyle`">Object</td>")
  [void]$html.Append("<td style=`"$thLeftStyle`">Location</td>")
  [void]$html.Append("<td style=`"$thStyle`">Type</td>")
  [void]$html.Append("<td style=`"$thStyle`">Status</td>")
  [void]$html.Append("<td style=`"$thStyle`">Local Storage Change (GB)</td>")
  [void]$html.Append("<td style=`"$thStyle`">Local Storage: Baseline (GB)</td>")
  [void]$html.Append("<td style=`"$thStyle`">Local Storage: $label (GB)</td>")
  [void]$html.Append("<td style=`"$thStyle`">Archive: Baseline (GB)</td>")
  [void]$html.Append("<td style=`"$thStyle`">Archive: $label (GB)</td>")
  [void]$html.Append("<td style=`"$thStyle`">Replica: Baseline (GB)</td>")
  [void]$html.AppendLine("</tr>")

  # Data rows
  $rowIndex = 0
  foreach ($item in $topN) {
    $bgColor = if ($rowIndex % 2 -eq 1) { "background-color:$zebraColor;" } else { "" }
    $rowIndex++

    $comp = $item.Comparisons[$label]
    $dsChange = $comp.DataStored.Change
    $dsChangeGB = ConvertTo-GB $dsChange
    $dsBaselineGB = ConvertTo-GB $item.Baseline.DataStored
    $dsOldGB = ConvertTo-GB $comp.DataStored.OldValue
    $arBaselineGB = ConvertTo-GB $item.Baseline.ArchiveStorage
    $arOldGB = ConvertTo-GB $comp.ArchiveStorage.OldValue
    $repBaselineGB = ConvertTo-GB $item.Baseline.ReplicaStorage

    $changeColor = Get-ChangeColor $dsChange

    [void]$html.Append("<tr>")
    [void]$html.Append("<td style=`"$tdLeftStyle$bgColor`">$($item.ObjectName)</td>")
    [void]$html.Append("<td style=`"$tdLeftStyle$bgColor`">$($item.Location)</td>")
    [void]$html.Append("<td style=`"$tdStyle$bgColor`">$($item.ObjectType)</td>")
    [void]$html.Append("<td style=`"$tdStyle$bgColor`">$($item.Status)</td>")
    [void]$html.Append("<td style=`"$tdStyle$bgColor color:$changeColor;font-weight:bold;`">$(Format-Number $dsChangeGB)</td>")
    [void]$html.Append("<td style=`"$tdStyle$bgColor`">$(Format-Number $dsBaselineGB)</td>")
    [void]$html.Append("<td style=`"$tdStyle$bgColor`">$(Format-Number $dsOldGB)</td>")
    [void]$html.Append("<td style=`"$tdStyle$bgColor`">$(Format-Number $arBaselineGB)</td>")
    [void]$html.Append("<td style=`"$tdStyle$bgColor`">$(Format-Number $arOldGB)</td>")
    [void]$html.Append("<td style=`"$tdStyle$bgColor`">$(Format-Number $repBaselineGB)</td>")
    [void]$html.AppendLine("</tr>")
  }

  [void]$html.AppendLine("</table>")
  [void]$html.AppendLine("</div><br>")
}

# HTML end
[void]$html.AppendLine("</body></html>")

# Write HTML
$html.ToString() | Out-File -FilePath $htmlOutputPath -Encoding UTF8
Write-Host "HTML report: $htmlOutputPath" -ForegroundColor Green

### BUILD CSV ###

$csvResults = [System.Collections.ArrayList]::new()

foreach ($item in $results) {
  $csvObj = [ordered]@{
    'Object Name'         = $item.ObjectName
    'Cluster Name'        = $item.ClusterName
    'Location'            = $item.Location
    'UniqueKey'           = $item.UniqueKey
    'Object Type'         = $item.ObjectType
    'Status'              = $item.Status
    'SLA Domain'          = $item.SLADomain
    'Protected On'        = $item.ProtectedOn
  }

  # Add baseline values for each metric
  foreach ($metric in $trackedMetrics) {
    $displayName = switch ($metric) {
      'LogicalBytes'   { 'Logical Bytes' }
      'UsedSize'       { 'Used Size' }
      'DataStored'     { 'Data Stored' }
      'ArchiveStorage' { 'Archive Storage' }
      'ReplicaStorage' { 'Replica Storage' }
    }
    $csvObj["$displayName (GB)"] = ConvertTo-GB $item.Baseline[$metric]
  }

  # Add comparison values and changes
  foreach ($rc in $resolvedCompDates) {
    $label = $rc.Label
    if ($item.Comparisons.ContainsKey($label)) {
      $comp = $item.Comparisons[$label]
      foreach ($metric in $trackedMetrics) {
        $displayName = switch ($metric) {
          'LogicalBytes'   { 'Logical Bytes' }
          'UsedSize'       { 'Used Size' }
          'DataStored'     { 'Data Stored' }
          'ArchiveStorage' { 'Archive Storage' }
          'ReplicaStorage' { 'Replica Storage' }
        }
        $csvObj["$displayName (GB) $label"] = ConvertTo-GB $comp[$metric].OldValue
        $csvObj["$displayName Change (GB) $label"] = ConvertTo-GB $comp[$metric].Change
      }
    }
  }

  $csvObj['Local Data Reduction (%)'] = $item.LocalDataReduction
  $csvObj['Local Dedup Ratio (x)'] = $item.LocalDedupRatio

  [void]$csvResults.Add([PSCustomObject]$csvObj)
}

$csvResults | Export-Csv -NoTypeInformation -Path $csvOutputPath
Write-Host "CSV report: $csvOutputPath" -ForegroundColor Green

### EMAIL ###

if ($sendEmail) {
  $emailSubject = "Rubrik Capacity Change Report - $($baselineDate.ToString('yyyy-MM-dd'))"
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject `
    -BodyAsHtml -Body $html.ToString() -SmtpServer $SMTPServer -Port $SMTPPort `
    -Attachments $csvOutputPath
  Write-Host "Email sent to: $($emailTo -join ', ')" -ForegroundColor Green
}

Write-Host "`nDone.`n" -ForegroundColor Green
