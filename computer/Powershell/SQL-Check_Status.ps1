# https://www.rubrik.com/api
<#
.SYNOPSIS
Checks the status of the latest SQL database backup jobs and polls until
they reach a terminal state (SUCCEEDED, FAILED, CANCELED).

.DESCRIPTION
Checks the status of one or more SQL database backup jobs using the CDM
REST API. For each database, finds the latest non-queued backup event and
polls its event series until it reaches a terminal state.

Supports two modes for identifying databases:
1. Direct UUID mode - provide one or more CDM database UUIDs via -sqlDbId
2. Name lookup mode - provide -sqlHost, -sqlInstance, and one or more
   -sqlDBName values

This script is designed to be used after SQL-Take_OnDemand_Backup.ps1
when that script exits at the 'Retrieved' stage. Run this script with the
same database identifiers to monitor the remaining backup progress.

Authentication uses a RSC Service Account JSON file against the CDM cluster
REST API (POST /api/v1/service_account/session).

.PARAMETER serviceAccountPath
File path to the RSC Service Account JSON file containing client_id and
client_secret.

.PARAMETER cluster
Hostname or IP address of the Rubrik CDM cluster.

.PARAMETER sqlDbId
One or more CDM database UUIDs (e.g. 'MssqlDatabase:::xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx').
Use this for direct mode. Mutually exclusive with sqlHost/sqlInstance/sqlDBName.

.PARAMETER sqlHost
SQL Server hostname for name lookup mode. Used with -sqlInstance and -sqlDBName.

.PARAMETER sqlInstance
SQL Server instance name for name lookup mode (e.g. 'MSSQLSERVER').

.PARAMETER sqlDBName
One or more SQL database names for name lookup mode.

.PARAMETER secondsToCheck
How often to poll job status in seconds. Default: 15.

.PARAMETER timeoutSeconds
Maximum time to wait for all jobs to complete in seconds. Default: 5400.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 8/3/26
Updated: 8/3/26

Requires PowerShell 7+.

For authentication, use a RSC Service Account:
** RSC Settings -> Users -> Service Account -> Create one and assign it an appropriate role
** Download the service account JSON
** Define the service account JSON path via -serviceAccountPath

.EXAMPLE
./SQL-Check_Status.ps1 -serviceAccountPath ./rsc-sa.json
  -cluster 10.8.49.104
  -sqlDbId 'MssqlDatabase:::459ed96c-c70a-4fdd-b7be-dfc0560ccba0'
Check status of a single database backup by UUID.

.EXAMPLE
./SQL-Check_Status.ps1 -serviceAccountPath ./rsc-sa.json
  -cluster 10.8.49.104
  -sqlDbId @('MssqlDatabase:::459ed96c-xxxx', 'MssqlDatabase:::fef964ed-xxxx')
Check status of multiple database backups by UUID.

.EXAMPLE
./SQL-Check_Status.ps1 -serviceAccountPath ./rsc-sa.json
  -cluster 10.8.49.104
  -sqlHost sh1-sql22ag-1a.rubrikdemo.com -sqlInstance MSSQLSERVER
  -sqlDBName 'MLB'
Check status of a single database backup by name.

.EXAMPLE
./SQL-Check_Status.ps1 -serviceAccountPath ./rsc-sa.json
  -cluster 10.8.49.104
  -sqlHost sh1-sql22ag-1a.rubrikdemo.com -sqlInstance MSSQLSERVER
  -sqlDBName 'MLB','F1','AdventureWorks'
Check status of multiple database backups by name.
#>

param (
  [CmdletBinding()]
  # File path to the RSC Service Account JSON
  [Parameter(Mandatory=$false)]
  [string]$serviceAccountPath = '',
  # Rubrik CDM cluster hostname or IP
  [Parameter(Mandatory=$false)]
  [string]$cluster = '',
  # CDM database UUID(s) - direct mode
  [Parameter(Mandatory=$false)]
  [array]$sqlDbId = @(),
  # SQL Server hostname - name lookup mode
  [Parameter(Mandatory=$false)]
  [string]$sqlHost = '',
  # SQL Server instance name - name lookup mode
  [Parameter(Mandatory=$false)]
  [string]$sqlInstance = '',
  # SQL database name(s) - name lookup mode
  [Parameter(Mandatory=$false)]
  [array]$sqlDBName = @(),
  # Poll interval in seconds
  [Parameter(Mandatory=$false)]
  [int]$secondsToCheck = 15,
  # Timeout in seconds
  [Parameter(Mandatory=$false)]
  [int]$timeoutSeconds = 5400
)

### VARIABLES - BEGIN ###
### VARIABLES - END ###

###### PARAMETER VALIDATION - BEGIN ######

if ($PSVersionTable.PSVersion.Major -lt 7) {
  Write-Error "PowerShell 7+ is required. Current version: $($PSVersionTable.PSVersion)"
  exit 1
}

# Show usage if no parameters provided
if ($serviceAccountPath -eq '' -and $cluster -eq '' -and $sqlDbId.Count -eq 0 -and
    $sqlHost -eq '' -and $sqlInstance -eq '' -and $sqlDBName.Count -eq 0) {
  Write-Host ""
  Write-Host "Usage: ./SQL-Check_Status.ps1 -serviceAccountPath <path> -cluster <host>"
  Write-Host ""
  Write-Host "Database identification (choose one):"
  Write-Host "  -sqlDbId <uuid[]>                              CDM database UUID(s)"
  Write-Host "  -sqlHost <host> -sqlInstance <inst> -sqlDBName <name[]>  Lookup by name"
  Write-Host ""
  Write-Host "Optional:"
  Write-Host "  -secondsToCheck <int>          Poll interval (default: 15)"
  Write-Host "  -timeoutSeconds <int>          Timeout (default: 5400)"
  exit 0
}

if ($serviceAccountPath -eq '') {
  Write-Error "Missing required parameter: -serviceAccountPath"
  exit 1
}
if ($cluster -eq '') {
  Write-Error "Missing required parameter: -cluster"
  exit 1
}

# Validate DB identification
$useUuidMode = $sqlDbId.Count -gt 0
$useNameMode = $sqlHost -ne '' -or $sqlInstance -ne '' -or $sqlDBName.Count -gt 0

if ($useUuidMode -and $useNameMode) {
  Write-Error "Cannot use both -sqlDbId and -sqlHost/-sqlInstance/-sqlDBName. Choose one mode."
  exit 2
}
if (-not $useUuidMode -and -not $useNameMode) {
  Write-Error "Must provide either -sqlDbId or -sqlHost/-sqlInstance/-sqlDBName."
  exit 2
}
if ($useNameMode -and ($sqlHost -eq '' -or $sqlInstance -eq '' -or $sqlDBName.Count -eq 0)) {
  Write-Error "Name lookup mode requires all of: -sqlHost, -sqlInstance, -sqlDBName."
  exit 2
}

###### PARAMETER VALIDATION - END ######

###### RUBRIK AUTHENTICATION - BEGIN ######

Write-Host "Reading Service Account file: $serviceAccountPath"
try {
  $serviceAccountFile = Get-Content -Path "$serviceAccountPath" -ErrorAction Stop | ConvertFrom-Json
} catch {
  throw "Failed to read Service Account JSON at '$serviceAccountPath': $($_.Exception.Message)"
}

$missingFields = @()
if ($null -eq $serviceAccountFile.client_id) { $missingFields += 'client_id' }
if ($null -eq $serviceAccountFile.client_secret) { $missingFields += 'client_secret' }
if ($missingFields.Count -gt 0) {
  throw "Service Account JSON is missing required fields: $($missingFields -join ', ')"
}

try {
  $response = Invoke-RestMethod -Method POST -ContentType 'application/json' -SkipCertificateCheck `
    -Uri "https://$cluster/api/v1/service_account/session" `
    -Body (@{ serviceAccountId = $serviceAccountFile.client_id; secret = $serviceAccountFile.client_secret } | ConvertTo-Json) `
    -ErrorAction Stop
} catch {
  throw "CDM authentication failed: $($_.Exception.Message)"
}

if ([string]::IsNullOrEmpty($response.token)) {
  throw "CDM returned a response but no bearer token was included."
}

$rubrikURL = "https://$cluster"
$sessionId = $response.sessionId
$baseUrl = "$rubrikURL/api"
$headers = @{
  'Content-Type'  = 'application/json'
  'Accept'        = 'application/json'
  'Authorization' = "Bearer $($response.token)"
}

$global:rubrikConnection = @{
  accessToken = $response.token
  bearer      = "Bearer $($response.token)"
  rubrikURL   = $rubrikURL
  sessionId   = $sessionId
}

Write-Host "Connected to CDM cluster: $cluster" -ForegroundColor Green

###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

function Remove-RubrikSession {
  $conn = $global:rubrikConnection
  if ($null -eq $conn -or [string]::IsNullOrEmpty($conn.sessionId)) {
    Write-Warning "No active CDM session to delete."
    return
  }
  $deleteHeaders = @{
    'Content-Type'  = 'application/json'
    'Accept'        = 'application/json'
    'Authorization' = $conn.bearer
  }
  try {
    Invoke-RestMethod -Method DELETE -SkipCertificateCheck -Headers $deleteHeaders `
      -Uri "$($conn.rubrikURL)/api/v1/session/$([Uri]::EscapeDataString($conn.sessionId))" | Out-Null
    Write-Host "CDM session deleted." -ForegroundColor DarkGray
  } catch {
    Write-Warning "Failed to delete CDM session: $($_.Exception.Message)"
  }
}

function Format-ByteSize {
  param ([long]$bytes)
  if ($bytes -ge 1TB) { return "{0:N2} TB" -f ($bytes / 1TB) }
  if ($bytes -ge 1GB) { return "{0:N2} GB" -f ($bytes / 1GB) }
  if ($bytes -ge 1MB) { return "{0:N2} MB" -f ($bytes / 1MB) }
  if ($bytes -ge 1KB) { return "{0:N2} KB" -f ($bytes / 1KB) }
  return "$bytes B"
}

###### FUNCTIONS - END ######

###### RESOLVE DATABASES - BEGIN ######

$dbList = @()

if ($useUuidMode) {
  foreach ($dbId in $sqlDbId) {
    Write-Host "Getting info for UUID: $dbId"
    try {
      $encodedId = [Uri]::EscapeDataString($dbId)
      $sqlDetail = Invoke-RestMethod -Method GET -Headers $headers -SkipCertificateCheck `
        -Uri "$baseUrl/v1/mssql/db/$encodedId"
    } catch {
      Write-Error "Failed to get DB details for $dbId : $($_.Exception.Message)"
      Remove-RubrikSession
      exit 4
    }
    $dbList += [PSCustomObject]@{
      sqlID    = $sqlDetail.id
      name     = $sqlDetail.name
      instance = $sqlDetail.instanceName
      host     = $sqlDetail.rootProperties.rootName
    }
    Write-Host "Found: $($sqlDetail.name) on $($sqlDetail.rootProperties.rootName)\$($sqlDetail.instanceName)" -ForegroundColor Cyan
  }
} else {
  foreach ($dbName in $sqlDBName) {
    Write-Host "Looking up DB: $dbName on $sqlHost\$sqlInstance"
    $encodedName = [Uri]::EscapeDataString($dbName)
    try {
      $searchResponse = Invoke-RestMethod -Method GET -Headers $headers -SkipCertificateCheck `
        -Uri "$baseUrl/v1/mssql/db?name=$encodedName&is_relic=false"
    } catch {
      Write-Error "Failed to search for DB '$dbName': $($_.Exception.Message)"
      Remove-RubrikSession
      exit 4
    }

    $matched = $searchResponse.data | Where-Object {
      $_.name -eq $dbName -and
      $_.rootProperties.rootName -eq $sqlHost -and
      $_.instanceName -eq $sqlInstance
    }

    if ($null -eq $matched -or @($matched).Count -eq 0) {
      Write-Error "No DB found for '$dbName' on $sqlHost\$sqlInstance."
      Remove-RubrikSession
      exit 4
    }
    if (@($matched).Count -gt 1) {
      Write-Error "Multiple matches for '$dbName' on $sqlHost\$sqlInstance. Use -sqlDbId instead."
      Remove-RubrikSession
      exit 4
    }

    $dbList += [PSCustomObject]@{
      sqlID    = $matched.id
      name     = $matched.name
      instance = $matched.instanceName
      host     = $matched.rootProperties.rootName
    }
    Write-Host "Found: $($matched.name) [$($matched.id)]" -ForegroundColor Cyan
  }
}

Write-Host ""
Write-Host "Databases to check: $($dbList.Count)" -ForegroundColor Green
$dbList | ForEach-Object {
  Write-Host "  $($_.host)\$($_.instance)\$($_.name)"
}
Write-Host ""

###### RESOLVE DATABASES - END ######

###### FIND LATEST BACKUP EVENT - BEGIN ######

Write-Host "Finding latest backup event for each database..."

$resultList = @()

foreach ($db in $dbList) {
  $encodedObjId = [Uri]::EscapeDataString($db.sqlID)
  try {
    $events = Invoke-RestMethod -Method GET -Headers $headers -SkipCertificateCheck `
      -Uri "$baseUrl/v1/event/latest?object_ids=$encodedObjId&event_type=Backup&limit=10"
  } catch {
    Write-Warning "[$($db.name)] Failed to query events: $($_.Exception.Message)"
    continue
  }

  $latestEvent = $events.data | Where-Object {
    $_.latestEvent.eventStatus -ne 'Queued'
  } | Select-Object -First 1

  if (-not $latestEvent) {
    Write-Warning "[$($db.name)] No active or recent backup events found, skipping."
    continue
  }

  Write-Host "[$($db.name)] Event series: $($latestEvent.latestEvent.eventSeriesId) / Status: $($latestEvent.latestEvent.eventStatus)" -ForegroundColor Cyan

  $resultList += [PSCustomObject]@{
    sqlID           = $db.sqlID
    name            = $db.name
    instance        = $db.instance
    host            = $db.host
    eventSeriesId   = $latestEvent.latestEvent.eventSeriesId
    status          = $latestEvent.latestEvent.eventStatus
    duration        = ''
    logicalSize     = ''
    dataTransferred = ''
  }
}

if ($resultList.Count -eq 0) {
  Write-Warning "No backup events found for any database."
  Remove-RubrikSession
  exit 0
}

Write-Host ""

###### FIND LATEST BACKUP EVENT - END ######

###### POLL FOR COMPLETION - BEGIN ######

Write-Host "Polling job status until completion..."

$runningStates = @('QUEUED', 'ACQUIRING', 'RUNNING', 'FINISHING', 'TO_CANCEL')
$startTime = Get-Date

do {
  $anyRunning = $false
  $elapsed = (Get-Date) - $startTime
  $elapsedStr = "$([math]::Round($elapsed.TotalSeconds))s"

  foreach ($result in $resultList) {
    if ([string]::IsNullOrEmpty($result.eventSeriesId)) { continue }

    $latestMsg = ''
    try {
      $encodedSeriesId = [Uri]::EscapeDataString($result.eventSeriesId)
      $eventSeries = Invoke-RestMethod -Method GET -Headers $headers -SkipCertificateCheck `
        -Uri "$baseUrl/v1/event_series/$encodedSeriesId"
    } catch {
      Write-Warning "[$($result.name)] Failed to query event series: $($_.Exception.Message)"
      $anyRunning = $true
      continue
    }

    $result.status = $eventSeries.eventSeriesStatus
    $result.duration = if ($eventSeries.duration) { $eventSeries.duration } else { '' }
    $result.logicalSize = if ($null -ne $eventSeries.logicalSize) { Format-ByteSize $eventSeries.logicalSize } else { '' }
    $result.dataTransferred = if ($null -ne $eventSeries.dataTransferred) { Format-ByteSize $eventSeries.dataTransferred } else { '' }
    $latestEvent = $eventSeries.eventDetailList | Select-Object -First 1
    if ($latestEvent) {
      try {
        $eventInfoObj = $latestEvent.eventInfo | ConvertFrom-Json
        $latestMsg = $eventInfoObj.message
      } catch {
        $latestMsg = $latestEvent.eventName
      }
    }

    if ($latestMsg -ne '') {
      Write-Host "[$($result.name) / Elapsed: $elapsedStr] Status: $($result.status) - Current stage: $latestMsg"
    } else {
      Write-Host "[$($result.name) / Elapsed: $elapsedStr] Status: $($result.status)"
    }

    if ($runningStates -contains $result.status) {
      $anyRunning = $true
    }
  }

  if ($elapsed.TotalSeconds -gt $timeoutSeconds) {
    Write-Error "Timeout of $timeoutSeconds seconds reached."
    break
  }

  if ($anyRunning) {
    Start-Sleep -Seconds $secondsToCheck
  }
} while ($anyRunning)

###### POLL FOR COMPLETION - END ######

###### RESULTS + CLEANUP ######

Write-Host ""
Write-Host "===== Final Results =====" -ForegroundColor Yellow

$fullySuccessful = $true
foreach ($res in $resultList) {
  if ($res.status -match 'SUCC') {
    Write-Host "[SUCCESS] $($res.host)\$($res.instance)\$($res.name)" -ForegroundColor Green
  } elseif ($res.status -match 'CANCEL') {
    Write-Host "[CANCELED] $($res.host)\$($res.instance)\$($res.name)" -ForegroundColor Yellow
    $fullySuccessful = $false
  } elseif ($res.status -match 'FAIL') {
    Write-Host "[FAILED] $($res.host)\$($res.instance)\$($res.name)" -ForegroundColor Red
    $fullySuccessful = $false
  } else {
    Write-Host "[UNKNOWN: $($res.status)] $($res.host)\$($res.instance)\$($res.name)" -ForegroundColor Red
    $fullySuccessful = $false
  }
}

Write-Host ""
$resultList | Format-Table -Property name, instance, host, status, duration, logicalSize, dataTransferred -AutoSize

Remove-RubrikSession

if ($fullySuccessful) {
  Write-Host "All backups completed successfully." -ForegroundColor Green
  exit 0
} else {
  Write-Error "One or more backups did not complete successfully."
  exit 500
}
