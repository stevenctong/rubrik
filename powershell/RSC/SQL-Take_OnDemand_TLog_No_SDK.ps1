<#
.SYNOPSIS
This script take an on demand T-Log of a SQL DB using the local REST API.

.DESCRIPTION
This script take an on demand T-Log of a SQL DB using the local REST API.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 11/28/24

For authentication, provide a RSC Service Account JSON defined at variable $serviceAccountPath.

Update the the PARAM and VARIABLES section as needed.

.EXAMPLE
./SQL-Take_OnDemand_TLog_No_SDK.ps1 -serviceAccountPath ./rsc_svc.json
  -cluster pa-cluster.rubrikdemo.com -sqlHost pa-host.rubrikdemo.com
  - sqlInstance MSSQLSERVER -sqlDBName F1db
Take an On Demand Backup T-Log backup of a SQL DB.

#>

param (
  [CmdletBinding()]
  # Rubrik cluster hostname or IP
  [Parameter(Mandatory=$false)]
  [string]$cluster = '',
  # RSC Service Account json
  [Parameter(Mandatory=$false)]
  [string]$serviceAccountPath = '',
  # SQL Hostname
  [Parameter(Mandatory=$false)]
  [string]$sqlHost = '',
  # SQL Instance Name
  [Parameter(Mandatory=$false)]
  [string]$sqlInstance = '',
  # SQL Database Name
  [Parameter(Mandatory=$false)]
  [string]$sqlDBName = ''
)

$date = Get-Date

$jobFinishedStatuses = @('SUCC', 'FAIL', 'CANCEL')

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
# $headers = @{
#   'Content-Type' = 'application/json';
#   'Accept' = 'application/json';
# }
#
# Write-Verbose -Message "Connecting to the RSC GraphQL API using the Service Account JSON file."
# $response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers
#
# $rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")
# $global:rubrikConnection = @{
#   accessToken = $response.access_token;
#   rubrikURL = $rubrikURL
# }
#
# $uri = "https://$($global:rubrikConnection.Server)/api/internal/cluster/me/global_manager"
#
# $headers = $global:rubrikConnection.header
# $method = "GET"

$RestSplat = @{
    Method = 'Post'
    ContentType = "application/json"
    URI = "https://$cluster/api/v1/service_account/session"
    Body = @{
        serviceAccountId = "$($serviceAccountFile.client_id)"
        secret = "$($serviceAccountFile.client_secret)"
    } | ConvertTo-Json
}

if ($PSVersiontable.PSVersion.Major -gt 5) {$RestSplat.SkipCertificateCheck = $true}
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
  Write-Host "Connected to Rubrik cluster: $cluster"
}

###### RUBRIK AUTHENTICATION - END ######

# Get SQL databases matching the DB name
$response = Invoke-RestMethod -Method GET -Headers $headers -contentType $contentType `
  -Uri "https://$cluster/api/v1/mssql/db?name=$sqlDBName" -SkipCertificateCheck

$sqlDB = $response.data | where { $_.name -eq $sqlDBName -and
  $_.rootProperties.rootname -eq $sqlHost -and
  $_.instanceName -eq $sqlInstance}

if ($sqlDB.count -eq 0) {
  Write-Error "No DB found for $sqlDBName on $sqlHost\$sqlInstance."
  exit
} elseif ($sqlDB.count -gt 1) {
  Write-Error "Found too many matches ($($sqlDB.count) for $sqlDBName on $sqlHost\$sqlInstance.)"
  exit
}

Write-Host "Attempting T-Log backup of $sqlDBName on $sqlHost\$sqlInstance."
$sqlID = $sqlDB.id
$response = Invoke-RestMethod -Method POST -Headers $headers -contentType $contentType `
  -Uri "https://$cluster/api/v1/mssql/db/$sqlID/log_backup" -SkipCertificateCheck

$href = $response.links.href

Write-Host "Getting the status of the task."
$jobFinished = $false
do {
  # Get the task status
  $response = Invoke-RestMethod -Method GET -Headers $headers -contentType $contentType `
    -Uri "$href" -SkipCertificateCheck
  Write-Host "Current status: $($response.status). Waiting 10 seconds..."
  # Check if the job status matches one of the finished job statuses
  foreach ($status in $jobFinishedStatuses) {
    if ($response.status -match $status) {
      $jobFinished = $true
    }
  }
  Start-Sleep -Seconds 10
} while ($jobFinished -eq $false)
