# https://www.rubrik.com/api
<#
.SYNOPSIS
Reusable CDM authentication block. Dot-source this script to authenticate
against a Rubrik CDM cluster REST API using a RSC Service Account JSON file.

.DESCRIPTION
Reads a RSC Service Account JSON file, validates required fields, exchanges
credentials for a bearer token via the CDM session API, and sets the following
variables in the caller's scope:

  $global:rubrikConnection  - @{ accessToken; bearer; rubrikURL; sessionId }
  $rubrikURL                - Base URL of the CDM cluster (https://<ClusterIP>)
  $endpoint                 - CDM REST API base (https://<ClusterIP>/api/v1)
  $headers                  - Headers hashtable with Authorization bearer token
  $sessionId                - Session ID for cleanup via Remove-RubrikSession

Also defines the function Remove-RubrikSession in the caller's scope, which
deletes the CDM session via DELETE /api/v1/session/{id}. Call it before exiting.

Can be used two ways:
1. Pass parameters when dot-sourcing
2. Set $RscServiceAccountJson and $ClusterIP before dot-sourcing

.PARAMETER RscServiceAccountJson
File path to the RSC Service Account JSON file. The JSON must contain:
client_id and client_secret.
Can also be set as a variable before dot-sourcing instead of passing as a parameter.

.PARAMETER ClusterIP
IP address or hostname of the Rubrik CDM cluster to authenticate against.
Can also be set as a variable before dot-sourcing instead of passing as a parameter.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 4/18/26
Updated: 4/18/26

Requires PowerShell 7+.
Authentication uses POST /api/v1/service_account/session on the CDM cluster.

.EXAMPLE
. ./core/CDM-Authentication.ps1 -RscServiceAccountJson "./rsc-sa.json" -ClusterIP "10.8.49.104"

$reports = Invoke-RestMethod -Method GET -Uri "$endpoint/report" -Headers $headers -SkipCertificateCheck
Remove-RubrikSession

.EXAMPLE
$RscServiceAccountJson = "./rsc-sa.json"
$ClusterIP = "10.8.49.104"
. ./core/CDM-Authentication.ps1
#>

param (
  [CmdletBinding()]
  # File path to the RSC Service Account JSON
  [Parameter(Mandatory=$false)]
  [string]$RscServiceAccountJson = $RscServiceAccountJson,
  # IP address or hostname of the Rubrik CDM cluster
  [Parameter(Mandatory=$false)]
  [string]$ClusterIP = $ClusterIP
)

# Validate parameters
if ([string]::IsNullOrEmpty($RscServiceAccountJson)) {
  throw "`$RscServiceAccountJson must be passed as a parameter or defined before dot-sourcing CDM-Authentication.ps1"
}
if ([string]::IsNullOrEmpty($ClusterIP)) {
  throw "`$ClusterIP must be passed as a parameter or defined before dot-sourcing CDM-Authentication.ps1"
}

# Require PowerShell 7+
if ($PSVersionTable.PSVersion.Major -lt 7) {
  throw "PowerShell 7+ is required. Current version: $($PSVersionTable.PSVersion)"
}

###### RUBRIK AUTHENTICATION - BEGIN ######

Write-Host "Reading Service Account file: $RscServiceAccountJson"
try {
  $serviceAccountFile = Get-Content -Path "$RscServiceAccountJson" -ErrorAction Stop | ConvertFrom-Json
} catch {
  throw "Failed to read Service Account JSON at '$RscServiceAccountJson': $($_.Exception.Message)"
}

# Validate required fields
$missingFields = @()
if ($null -eq $serviceAccountFile.client_id) { $missingFields += 'client_id' }
if ($null -eq $serviceAccountFile.client_secret) { $missingFields += 'client_secret' }

if ($missingFields.Count -gt 0) {
  throw "Service Account JSON is missing required fields: $($missingFields -join ', ')"
}

# Exchange credentials for bearer token via CDM session API
try {
  $response = Invoke-RestMethod -Method POST -ContentType 'application/json' -SkipCertificateCheck `
    -Uri "https://$ClusterIP/api/v1/service_account/session" `
    -Body (@{ serviceAccountId = $serviceAccountFile.client_id; secret = $serviceAccountFile.client_secret } | ConvertTo-Json) `
    -ErrorAction Stop
} catch {
  throw "CDM authentication failed: $($_.Exception.Message)"
}

if ([string]::IsNullOrEmpty($response.token)) {
  throw "CDM returned a response but no bearer token was included."
}

# Set connection variables accessible to the calling script
$rubrikURL = "https://$ClusterIP"
$sessionId = $response.sessionId

$global:rubrikConnection = @{
  accessToken = $response.token
  bearer      = "Bearer $($response.token)"
  rubrikURL   = $rubrikURL
  sessionId   = $sessionId
}

$endpoint = "$rubrikURL/api/v1"

$headers = @{
  'Content-Type'  = 'application/json'
  'Accept'        = 'application/json'
  'Authorization' = "Bearer $($response.token)"
}

Write-Host "Connected to CDM cluster: $ClusterIP" -ForegroundColor Green

###### RUBRIK AUTHENTICATION - END ######

###### SESSION CLEANUP FUNCTION ######

# Call Remove-RubrikSession before exiting to delete the CDM session
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
