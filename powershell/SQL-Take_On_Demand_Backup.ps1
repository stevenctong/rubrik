# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will take an on demand backup of a SQL database.

.DESCRIPTION
This script will take an on demand backup of a SQL database.

Provide the following ID's in the script or as a parameter:
1. $serviceAccountPath - Location of the RSC Service Account json
2. $cluster - Hostname/IP of a Rubrik cluster node for REST API calls
3. $sqlDbId - CDM UUID of the DB to take an on demand backup of
    This can be found by going to the local UI, browsing to the SQL DB
    and looking at the URL. Eg MssqlDatabase:::459ed96c-c70a-4fdd-b7be-dfc0560ccba0
4. $slaID - SLA ID that you want to associate the on demand backup with
    This can be found by going to the local UI, browsing to the SLA
    and looking att he URL. Eg 506fcfba-10f3-4c2e-8181-0f877ee538cb

$sqlDbID and $slaId should be an array, eg: @('<value1>', '<value2>')
Match the array positions of both together in order to take a specific SQL DB
with a specific SLA ID.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 7/20/25
Updated: 8/12/25

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a custom role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath

.EXAMPLE
./SQL-TakeOnDemadBackup.ps1
Takes an on demand backup with all the variables defined in the script.
#>

### Variables section - please fill out as needed

param (
  [CmdletBinding()]
  # Filepath to the RSC Service Account json
  [Parameter(Mandatory=$false)]
  [string]$serviceAccountPath = '',
  # Rubrik Cluster Hostname/IP for REST API
  [Parameter(Mandatory=$false)]
  [string]$cluster = '',
  # SQL DB UUID from CDM
  # Put one or more into the PowerShell array format
  [Parameter(Mandatory=$false)]
  [array]$sqlDbId = @('MssqlDatabase:::459ed96c-c70a-4fdd-b7be-dfc0560ccba0',
    'MssqlDatabase:::fef964ed-c450-4ede-ade3-24ccfd98e686'),
  # SLA ID to associate the backup with
  # Put one or more into the PowerShell array format
  # The number of SLA IDs should match and be ordered with the SQL DBs
  [Parameter(Mandatory=$false)]
  [array]$slaID = @('506fcfba-10f3-4c2e-8181-0f877ee538cb',
    '506fcfba-10f3-4c2e-8181-0f877ee538cb')
)

### End Variables section

###### RUBRIK AUTHENTICATION - BEGIN ######

# $cluster = ’10.8.49.104’
# $serviceAccountPath = './rsc-service-account-rr.json'

# How often to check the status of the backup job, in seconds
$secondsToCheck = 30

# How long to timeout the script
$timeoutSeconds = 5400

if ($psversiontable.PSVersion.Major -lt 6) {
  Write-Error "Script requires PowerShell 7+, current version: $psversiontable.PSVersion.Major"
  Write-Error "Exiting..."
  exit 500
}

if ($cluster -eq '' -or $sqlDbId -eq '' -or $slaID -eq '') {
  Write-Error "Missing a required parameter, exiting..."
  exit 200
}

if ( $sqlDbId.count -ne $slaID.count) {
  Write-Error "SQL DB IDs must equal SLA IDs."
  Write-Error "Put them in the matching order for each SQL DB ID to SLA ID pair."
  Write-Error "Exiting..."
  exit 210
}

Write-Host "Attempting to read the Service Account file: $serviceAccountPath"
try {
  $serviceAccountFile = Get-Content -Path "$serviceAccountPath" -ErrorAction Stop | ConvertFrom-Json
} catch {
  $errorMessage = $_.Exception | Out-String
  if($errorMessage.Contains('because it does not exist')) {
    Write-Error "The Service Account JSON secret file was not found. Ensure the file is location at $serviceAccountPath."
    exit 100
  }
  Write-Error $_.Exception
  exit 100
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
  Write-Error "The Service Account JSON secret file is missing the required paramaters: $missingServiceAccount"
  Exit 101
}

$RestSplat = @{
    Method = 'Post'
    ContentType = "application/json"
    URI = "https://$cluster/api/v1/service_account/session"
    Body = @{
        serviceAccountId = "$($serviceAccountFile.client_id)"
        secret = "$($serviceAccountFile.client_secret)"
    } | ConvertTo-Json
}

if ($PSVersiontable.PSVersion.Major -gt 5) {$RestSplat.SkipCertificateCheck = $true} else {
# Ignore invalid/self-signed SSL certificates (for this script/session only):
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}
$response = Invoke-RestMethod @RestSplat -Verbose
$token = $response.token
$contentType = "application/json"
$headers = @{'Authorization' = "Bearer $($Token)"}
$global:rubrikConnection = @{
    id      = $response.sessionId
    userId  = $null
    token   = $Token
    server  = $Server
    header  = $head
    time    = (Get-Date)
    # api     = Get-RubrikAPIVersion -Server $Server
    # version = Get-RubrikSoftwareVersion -Server $Server
    authType = 'ServiceAccount'
}
if ($token -ne '') {
  Write-Host "Successfully connected to Rubrik cluster: $cluster" -foregroundcolor green
  Write-Host "Bearer token for cluster REST API is below" -foregroundcolor green
  Write-Host "Bearer $token"
} else {
  Write-Error "Error getting CDM REST API Bearer token, exiting..."
  exit 110
}

###### RUBRIK AUTHENTICATION - END ######

# Disable SSL certificate checks, if your server uses self-signed certificates (optional)
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

$headers = @{
    "accept" = "application/json"
    "Authorization" = "Bearer $token"
    "ContentType" = 'application/json'
}

$baseUrl = "https://$cluster/api"

# Holds list of on demand backup results
$resultList = @()

# Since we are looping through two arrays, we need to manually reference them together
$count = 0
$total = $sqlDbId.count
foreach ($database in $sqlDbId) {
  Write-Host "Getting info for: $sqlDbId[$count]"
  $getSqlDetailsUrl = $baseUrl + "/v1/mssql/db/$($sqlDbId[$count])"
  $takeOnDemandUrl = $baseUrl + "/v1/mssql/db/$($sqlDbId[$count])/snapshot"
  $takeOnDemandBody = @{
      slaId = $slaID[$count]
  }
  try {
    if ($PSVersiontable.PSVersion.Major -gt 5) {
      $sqlDetail = Invoke-RestMethod -Uri $getSqlDetailsUrl -Method GET -Headers $headers -SkipCertificateCheck
      Write-Host "Found: $($sqlDetail.name) on $($sqlDetail.rootProperties.rootName)"
      $result = Invoke-RestMethod -Uri $takeOnDemandUrl -Method POST `
        -Body $($takeOnDemandBody | ConvertTo-JSON -Depth 100) -Headers $headers -SkipCertificateCheck
    } else {
      $sqlDetail = Invoke-RestMethod -Uri $getSqlDetailsUrl -Method GET -Headers $headers
      $result = Invoke-RestMethod -Uri $takeOnDemandUrl -Method POST `
        -Body $($takeOnDemandBody | ConvertTo-JSON -Depth 100) -Headers $headers
    }
  } catch {
    Write-Error $_.Exception
    exit 300
  }
  $result
  $resultDetail = [PSCustomObject] @{
    "sqlID" = $sqlDbId[$count]
    "href" = $result.links.href
    "status" = ''
    "name" = $sqlDetail.name
    "instance" = $sqlDetail.instanceName
    "host" = $sqlDetail.rootProperties.rootName
  }
  $resultList += $resultDetail
  $count += 1
}

# Job states where the job is still running
$runningStates = @('QUEUED','ACQUIRING','RUNNING','FINISHING','TO_CANCEL')

$totalCount = $timeoutSeconds / $secondsToCheck
$currentCount = 0

# Wait until task completes and return state
do {
  # Contains state information, starts false.
  # Sets to $true if we detect any non-terminating state
  $reqState = $false
  foreach ($db in $resultList) {
    if ($PSVersiontable.PSVersion.Major -gt 5) {
      $req = Invoke-RestMethod -Uri $db.href -Method Get -Headers $headers -SkipCertificateCheck
    } else {
      $req = Invoke-RestMethod -Uri $db.href -Method Get -Headers $headers
    }
    $db.status = $req.status
    Write-Host "Current status for $($db.name) / $($db.host): $($req.status), checking again in $secondsToCheck seconds..."
    if ($runningStates -contains $req.status) {
      $reqState = $true
    }
  }
  # Check if we are greater than the timeout, if so exit
  $currentCount += 1
  if ($currentCount -gt $totalCount) {
    Write-Error "Timeout of $timeoutSeconds seconds reached, exiting..."
    exit 300
  }
  if ($reqState) { Start-Sleep -Seconds $secondsToCheck }
} while ( $reqState )

$fullySuccessful = $true
foreach ($res in $resultList) {
  if ($res.status -match 'SUCC') {
    Write-Host "Successful On Demand Backup for: $($db.name) / $($db.host)"
  } elseif ($res.status -match 'CANCEL') {
    Write-Host "Canceled On Demand Backup for: $($db.name) / $($db.host)"
  } elseif ($res.status -match 'FAIL') {
    Write-Error "Failed On Demand Backup for: $($db.name) / $($db.host)"
    $fullySuccessful = $false
  } else {
    Write-Error "Non-terminal state for: $($db.name) / $($db.host), $($res.status)"
    $fullySuccessful = $false
  }
}

if ($fullySuccessful) {
  exit 0
} else {
  exit 500
}
