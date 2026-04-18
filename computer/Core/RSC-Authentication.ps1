# https://www.rubrik.com/api
<#
.SYNOPSIS
Reusable RSC authentication block. Dot-source this script to authenticate
against the RSC GraphQL API using a Service Account JSON file.

.DESCRIPTION
Reads a RSC Service Account JSON file, validates required fields, exchanges
credentials for a bearer token, and sets the following variables in the
caller's scope:

  $global:rubrikConnection  - @{ accessToken; bearer; rubrikURL }
  $rubrikURL                - Base URL of the RSC instance
  $endpoint                 - RSC GraphQL API endpoint ($rubrikURL/api/graphql)
  $headers                  - Headers hashtable with Authorization bearer token

Can be used two ways:
1. Pass the path as a parameter when dot-sourcing
2. Set $RscServiceAccountJson before dot-sourcing

.PARAMETER RscServiceAccountJson
File path to the RSC Service Account JSON file. The JSON must contain:
client_id, client_secret, and access_token_uri.
Can also be set as a variable before dot-sourcing instead of passing as a parameter.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 4/18/26
Updated: 4/18/26

Requires PowerShell 7+.

.EXAMPLE
. ./core/RSC-Authentication.ps1 -RscServiceAccountJson "./rsc-service-account.json"

$query = '{ "query": "{ clusterConnection { nodes { name id } } }" }'
$result = Invoke-RestMethod -Method POST -Uri $endpoint -Body $query -Headers $headers

.EXAMPLE
$RscServiceAccountJson = "./rsc-service-account.json"
. ./core/RSC-Authentication.ps1
#>

param (
  [CmdletBinding()]
  # File path to the RSC Service Account JSON
  [Parameter(Mandatory=$false)]
  [string]$RscServiceAccountJson = $RscServiceAccountJson
)

# Validate that $RscServiceAccountJson is set via parameter or caller variable
if ([string]::IsNullOrEmpty($RscServiceAccountJson)) {
  throw "`$RscServiceAccountJson must be passed as a parameter or defined before dot-sourcing RSC-Authentication.ps1"
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
if ($null -eq $serviceAccountFile.access_token_uri) { $missingFields += 'access_token_uri' }

if ($missingFields.Count -gt 0) {
  throw "Service Account JSON is missing required fields: $($missingFields -join ', ')"
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
  throw "RSC authentication failed: $($_.Exception.Message)"
}

if ($null -eq $response.access_token) {
  throw "RSC returned a response but no access token was included."
}

# Set connection variables accessible to the calling script
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
