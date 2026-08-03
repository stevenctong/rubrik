# https://www.rubrik.com/api
<#
.SYNOPSIS
Takes an on demand backup of one or more SQL databases using the CDM REST API.

.DESCRIPTION
Takes an on demand backup of one or more SQL databases using the CDM REST API.

Supports two modes for identifying databases:
1. Direct UUID mode - provide one or more CDM database UUIDs via -sqlDbId
2. Name lookup mode - provide -sqlHost, -sqlInstance, and one or more -sqlDBName values

Supports three modes for specifying the SLA:
1. Direct SLA ID - provide -slaId
2. SLA name lookup - provide -slaName (auto-appends " (Managed by RSC)")
3. No SLA specified - each database uses its currently assigned SLA

After triggering snapshots, the script tracks progress via event series
(stage-level detail). Use -exitOn to control when the script exits:
'Retrieved' (default) exits once all databases reach the retrieval stage,
'Completed' polls until all jobs reach a terminal state.

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

.PARAMETER slaId
SLA Domain ID to associate the on demand backup with. If neither -slaId
nor -slaName is provided, each database uses its currently assigned SLA.

.PARAMETER slaName
SLA Domain name to look up. The script appends " (Managed by RSC)" and
searches via the CDM /v2/sla_domain API. If neither -slaId nor -slaName
is provided, each database uses its currently assigned SLA.

.PARAMETER exitOn
When to exit the script. Default: 'Retrieved'.
- 'Retrieved' - exit once all databases reach the 'Retrieving SQL Server'
  stage (Mssql.BeginFetchBackup event). The backup is still in progress.
- 'Completed' - wait until all jobs reach a terminal state (SUCCEEDED,
  FAILED, CANCELED).

.PARAMETER secondsToCheck
How often to poll job status in seconds. Default: 15.

.PARAMETER timeoutSeconds
Maximum time to wait for all jobs to complete in seconds. Default: 5400.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 7/29/26
Updated: 8/2/26

Requires PowerShell 7+.

For authentication, use a RSC Service Account:
** RSC Settings -> Users -> Service Account -> Create one and assign it an appropriate role
** Download the service account JSON
** Define the service account JSON path via -serviceAccountPath

.EXAMPLE
./SQL-Take_OnDemand_Backup.ps1 -serviceAccountPath ./rsc-sa.json
  -cluster 10.8.49.104
  -sqlDbId 'MssqlDatabase:::459ed96c-c70a-4fdd-b7be-dfc0560ccba0'
  -slaId '506fcfba-10f3-4c2e-8181-0f877ee538cb'
Take an on demand backup using a specific CDM database UUID and SLA ID.

.EXAMPLE
./SQL-Take_OnDemand_Backup.ps1 -serviceAccountPath ./rsc-sa.json
  -cluster 10.8.49.104
  -sqlDbId @('MssqlDatabase:::459ed96c-xxxx', 'MssqlDatabase:::fef964ed-xxxx')
  -slaId '506fcfba-10f3-4c2e-8181-0f877ee538cb'
Take on demand backups for multiple databases using UUIDs.

.EXAMPLE
./SQL-Take_OnDemand_Backup.ps1 -serviceAccountPath ./rsc-sa.json
  -cluster 10.8.49.104
  -sqlHost sh1-sql22ag-1a.rubrikdemo.com -sqlInstance MSSQLSERVER
  -sqlDBName 'MLB'
  -slaName 'MSSQL-1d-30d-NoArchive'
Look up a single database by hostname/instance/name and SLA by name.

.EXAMPLE
./SQL-Take_OnDemand_Backup.ps1 -serviceAccountPath ./rsc-sa.json
  -cluster 10.8.49.104
  -sqlHost sh1-sql22ag-1a.rubrikdemo.com -sqlInstance MSSQLSERVER
  -sqlDBName 'MLB','F1','AdventureWorks'
  -slaName 'MSSQL-1d-30d-NoArchive'
Back up multiple databases on the same host/instance by name.

.EXAMPLE
./SQL-Take_OnDemand_Backup.ps1 -serviceAccountPath ./rsc-sa.json
  -cluster 10.8.49.104
  -sqlDbId 'MssqlDatabase:::459ed96c-c70a-4fdd-b7be-dfc0560ccba0'
Back up a database using its currently assigned SLA (no -slaId or -slaName).
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
  # SLA Domain ID - direct mode
  [Parameter(Mandatory=$false)]
  [string]$slaId = '',
  # SLA Domain name - looked up, "(Managed by RSC)" appended
  [Parameter(Mandatory=$false)]
  [string]$slaName = '',
  # Exit after 'Retrieved' stage or wait for 'Completed' terminal state
  [Parameter(Mandatory=$false)]
  [ValidateSet('Retrieved', 'Completed')]
  [string]$exitOn = 'Retrieved',
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
  Write-Host "Usage: ./SQL-Take_OnDemand_Backup.ps1 -serviceAccountPath <path> -cluster <host>"
  Write-Host ""
  Write-Host "Database identification (choose one):"
  Write-Host "  -sqlDbId <uuid[]>                              CDM database UUID(s)"
  Write-Host "  -sqlHost <host> -sqlInstance <inst> -sqlDBName <name[]>  Lookup by name"
  Write-Host ""
  Write-Host "SLA (optional - defaults to each database's currently assigned SLA):"
  Write-Host "  -slaId <id>       SLA Domain ID"
  Write-Host "  -slaName <name>   SLA name lookup"
  Write-Host ""
  Write-Host "Optional:"
  Write-Host "  -exitOn <Retrieved|Completed>  Exit after retrieval stage or terminal state (default: Retrieved)"
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

# Validate SLA identification
if ($slaId -ne '' -and $slaName -ne '') {
  Write-Error "Cannot use both -slaId and -slaName. Choose one."
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

###### FUNCTIONS - END ######

###### RESOLVE SLA - BEGIN ######

if ($slaName -ne '') {
  Write-Host "Looking up SLA: $slaName"
  $encodedSlaName = [Uri]::EscapeDataString($slaName)
  try {
    $slaResponse = Invoke-RestMethod -Method GET -Headers $headers -SkipCertificateCheck `
      -Uri "$baseUrl/v2/sla_domain?name=$encodedSlaName&primary_cluster_id=local"
  } catch {
    Write-Error "Failed to query SLA domains: $($_.Exception.Message)"
    Remove-RubrikSession
    exit 3
  }

  $matchedSla = $slaResponse.data | Where-Object {
    $_.name -eq $slaName -or
    $_.name -eq "$slaName (Managed by RSC)" -or
    $_.name -eq "$slaName (Managed by Polaris)"
  }
  if ($null -eq $matchedSla -or @($matchedSla).Count -eq 0) {
    Write-Error "SLA not found: '$slaName'"
    Write-Error "Verify the SLA name and that it exists on this cluster."
    Remove-RubrikSession
    exit 3
  }
  if (@($matchedSla).Count -gt 1) {
    Write-Error "Multiple SLAs matched '$slaName'. Use -slaId instead."
    Remove-RubrikSession
    exit 3
  }
  $slaId = $matchedSla.id
  $slaResolvedName = $matchedSla.name
  Write-Host "Resolved SLA: $slaName -> $($matchedSla.name) [$slaId]" -ForegroundColor Cyan
}

###### RESOLVE SLA - END ######

###### RESOLVE DATABASES - BEGIN ######

# $dbList holds resolved DB info: each entry has sqlID, name, instance, host, slaId, slaName
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
    $dbSlaId = if ($slaId -ne '') { $slaId } else { $sqlDetail.effectiveSlaDomainId }
    $dbSlaName = if ($slaId -ne '') { if ($slaResolvedName) { $slaResolvedName } else { '' } } else { $sqlDetail.effectiveSlaDomainName }
    if ($dbSlaId -eq 'UNPROTECTED' -or [string]::IsNullOrEmpty($dbSlaId)) {
      Write-Error "DB '$($sqlDetail.name)' has no SLA assigned. Specify -slaId or -slaName, or assign an SLA to the database first."
      Remove-RubrikSession
      exit 3
    }
    $dbList += [PSCustomObject]@{
      sqlID    = $sqlDetail.id
      name     = $sqlDetail.name
      instance = $sqlDetail.instanceName
      host     = $sqlDetail.rootProperties.rootName
      slaId    = $dbSlaId
      slaName  = $dbSlaName
    }
    $slaDisplay = if ($dbSlaName -ne '') { "$dbSlaName [$dbSlaId]" } else { $dbSlaId }
    Write-Host "Found: $($sqlDetail.name) on $($sqlDetail.rootProperties.rootName)\$($sqlDetail.instanceName) [SLA: $slaDisplay]" -ForegroundColor Cyan
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

    $dbSlaId = if ($slaId -ne '') { $slaId } else { $matched.effectiveSlaDomainId }
    $dbSlaName = if ($slaId -ne '') { '' } else { $matched.effectiveSlaDomainName }
    if ($dbSlaId -eq 'UNPROTECTED' -or [string]::IsNullOrEmpty($dbSlaId)) {
      Write-Error "DB '$($matched.name)' has no SLA assigned. Specify -slaId or -slaName, or assign an SLA to the database first."
      Remove-RubrikSession
      exit 3
    }
    $dbList += [PSCustomObject]@{
      sqlID    = $matched.id
      name     = $matched.name
      instance = $matched.instanceName
      host     = $matched.rootProperties.rootName
      slaId    = $dbSlaId
      slaName  = $dbSlaName
    }
    $slaDisplay = if ($dbSlaName -ne '') { "$dbSlaName [$dbSlaId]" } else { $dbSlaId }
    Write-Host "Found: $($matched.name) [$($matched.id)] [SLA: $slaDisplay]" -ForegroundColor Cyan
  }
}

Write-Host ""
Write-Host "Databases to back up: $($dbList.Count)" -ForegroundColor Green
$dbList | ForEach-Object {
  $slaDisplay = if ($_.slaName -ne '') { "$($_.slaName) [$($_.slaId)]" } else { $_.slaId }
  Write-Host "  $($_.host)\$($_.instance)\$($_.name) -> SLA: $slaDisplay"
}
Write-Host ""

###### RESOLVE DATABASES - END ######

###### TRIGGER SNAPSHOTS - BEGIN ######

$resultList = @()

foreach ($db in $dbList) {
  $slaDisplay = if ($db.slaName -ne '') { "$($db.slaName) [$($db.slaId)]" } else { $db.slaId }
  Write-Host "Triggering on demand backup for: $($db.host)\$($db.instance)\$($db.name) - SLA: $slaDisplay"
  $encodedId = [Uri]::EscapeDataString($db.sqlID)
  $snapshotBody = @{ slaId = $db.slaId }
  try {
    $result = Invoke-RestMethod -Method POST -Headers $headers -SkipCertificateCheck `
      -Uri "$baseUrl/v1/mssql/db/$encodedId/snapshot" `
      -Body ($snapshotBody | ConvertTo-Json)
  } catch {
    Write-Error "Failed to trigger backup for $($db.name): $($_.Exception.Message)"
    Remove-RubrikSession
    exit 5
  }
  Write-Host "  Job ID: $($result.id) / Status: $($result.status)" -ForegroundColor DarkGray

  $resultDetail = [PSCustomObject]@{
    sqlID         = $db.sqlID
    href          = $result.links.href
    jobID         = $result.id
    status        = $result.status
    name          = $db.name
    instance      = $db.instance
    host          = $db.host
    eventSeriesId = ''
  }
  $resultList += $resultDetail
}

Write-Host ""
Write-Host "All snapshots triggered." -ForegroundColor Green

###### TRIGGER SNAPSHOTS - END ######

###### EVENT SERIES RESOLUTION - BEGIN ######

Write-Host "Resolving event series IDs..."

foreach ($result in $resultList) {
  $retryCount = 0
  $encodedObjId = [Uri]::EscapeDataString($result.sqlID)
  do {
    $retryCount++
    Start-Sleep -Seconds 2
    Write-Host "[$($result.name)] Getting event series ID (attempt $retryCount)..."
    try {
      $events = Invoke-RestMethod -Method GET -Headers $headers -SkipCertificateCheck `
        -Uri "$baseUrl/v1/event/latest?object_ids=$encodedObjId&event_type=Backup&limit=10"
    } catch {
      Write-Warning "[$($result.name)] Failed to query events: $($_.Exception.Message)"
      continue
    }
    $matchedEvent = $events.data | Where-Object { $_.latestEvent.jobInstanceId -eq $result.jobID } | Select-Object -First 1
    if ($matchedEvent) {
      $result.eventSeriesId = $matchedEvent.latestEvent.eventSeriesId
      Write-Host "[$($result.name)] Event series ID: $($matchedEvent.latestEvent.eventSeriesId)" -ForegroundColor Cyan
    }
  } while ([string]::IsNullOrEmpty($result.eventSeriesId) -and $retryCount -lt 15)

  if ([string]::IsNullOrEmpty($result.eventSeriesId)) {
    Write-Warning "[$($result.name)] Could not resolve event series ID after $retryCount attempts. Stage tracking unavailable for this DB."
  }
}

###### EVENT SERIES RESOLUTION - END ######

###### EVENT SERIES STAGE TRACKING - BEGIN ######

$startTime = Get-Date
Write-Host ""
Write-Host "Tracking event series for 'Retrieving SQL Server' stage..."

do {
  $allRetrieving = $true
  $elapsed = (Get-Date) - $startTime
  $elapsedStr = "$([math]::Round($elapsed.TotalSeconds))s"

  foreach ($result in $resultList) {
    if ([string]::IsNullOrEmpty($result.eventSeriesId)) { continue }

    try {
      $encodedSeriesId = [Uri]::EscapeDataString($result.eventSeriesId)
      $eventSeries = Invoke-RestMethod -Method GET -Headers $headers -SkipCertificateCheck `
        -Uri "$baseUrl/v1/event_series/$encodedSeriesId"
    } catch {
      Write-Warning "[$($result.name)] Failed to query event series: $($_.Exception.Message)"
      $allRetrieving = $false
      continue
    }

    $result.status = $eventSeries.eventSeriesStatus
    $latestEvent = $eventSeries.eventDetailList | Select-Object -First 1
    $latestMsg = 'Waiting...'
    if ($latestEvent) {
      try {
        $eventInfoObj = $latestEvent.eventInfo | ConvertFrom-Json
        $latestMsg = $eventInfoObj.message
      } catch {
        $latestMsg = $latestEvent.eventName
      }
    }
    $hasRetrieving = $eventSeries.eventDetailList | Where-Object {
      $_.eventName -eq 'Mssql.BeginFetchBackup'
    }

    if ($hasRetrieving) {
      Write-Host "[$($result.name) / Elapsed: $elapsedStr] Status: $($result.status) - Current stage: $latestMsg" -ForegroundColor Green
    } else {
      Write-Host "[$($result.name) / Elapsed: $elapsedStr] Status: $($result.status) - Current stage: $latestMsg"
      $allRetrieving = $false
    }
  }

  if (-not $allRetrieving -and $elapsed.TotalSeconds -lt $timeoutSeconds) {
    Start-Sleep -Seconds $secondsToCheck
  }
} while (-not $allRetrieving -and $elapsed.TotalSeconds -lt $timeoutSeconds)

if (-not $allRetrieving) {
  Write-Warning "Timed out waiting for all DBs to reach 'Retrieving SQL Server' stage."
} else {
  Write-Host "`nAll DBs have reached 'Retrieving SQL Server' stage." -ForegroundColor Green
}

###### EVENT SERIES STAGE TRACKING - END ######

if ($exitOn -eq 'Retrieved') {
  Write-Host ""
  Write-Host "===== Results (exitOn=Retrieved) =====" -ForegroundColor Yellow
  $resultList | ForEach-Object {
    Write-Host "[$($_.status)] $($_.host)\$($_.instance)\$($_.name)" -ForegroundColor Cyan
  }
  Write-Host ""
  $resultList | Format-Table -Property name, instance, host, status, jobID -AutoSize
  Remove-RubrikSession
  if ($allRetrieving) {
    Write-Host "All DBs reached 'Retrieving SQL Server' stage. Backups still in progress." -ForegroundColor Green
    exit 0
  } else {
    Write-Error "One or more DBs did not reach 'Retrieving SQL Server' stage before timeout."
    exit 500
  }
}

###### POLL FOR COMPLETION - BEGIN ######

Write-Host ""
Write-Host "Polling job status until completion..."

$runningStates = @('QUEUED', 'ACQUIRING', 'RUNNING', 'FINISHING', 'TO_CANCEL')

do {
  $anyRunning = $false
  $elapsed = (Get-Date) - $startTime
  $elapsedStr = "$([math]::Round($elapsed.TotalSeconds))s"

  foreach ($result in $resultList) {
    try {
      $req = Invoke-RestMethod -Method GET -Headers $headers -SkipCertificateCheck `
        -Uri $result.href
    } catch {
      Write-Warning "[$($result.name)] Failed to poll status: $($_.Exception.Message)"
      $anyRunning = $true
      continue
    }
    $result.status = $req.status

    $latestMsg = ''
    if (-not [string]::IsNullOrEmpty($result.eventSeriesId)) {
      try {
        $encodedSeriesId = [Uri]::EscapeDataString($result.eventSeriesId)
        $eventSeries = Invoke-RestMethod -Method GET -Headers $headers -SkipCertificateCheck `
          -Uri "$baseUrl/v1/event_series/$encodedSeriesId"
        $latestEvent = $eventSeries.eventDetailList | Select-Object -First 1
        if ($latestEvent) {
          try {
            $eventInfoObj = $latestEvent.eventInfo | ConvertFrom-Json
            $latestMsg = $eventInfoObj.message
          } catch {
            $latestMsg = $latestEvent.eventName
          }
        }
      } catch { }
    }

    if ($latestMsg -ne '') {
      Write-Host "[$($result.name) / Elapsed: $elapsedStr] Status: $($req.status) - Current stage: $latestMsg"
    } else {
      Write-Host "[$($result.name) / Elapsed: $elapsedStr] Status: $($req.status)"
    }

    if ($runningStates -contains $req.status) {
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
$resultList | Format-Table -Property name, instance, host, status, jobID -AutoSize

Remove-RubrikSession

if ($fullySuccessful) {
  Write-Host "All backups completed successfully." -ForegroundColor Green
  exit 0
} else {
  Write-Error "One or more backups did not complete successfully."
  exit 500
}
