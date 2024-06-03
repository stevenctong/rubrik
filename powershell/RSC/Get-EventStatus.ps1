<#
.SYNOPSIS
This script returns the status of a RSC job.

.DESCRIPTION
This script returns the status of a RSC job.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 6/3/24

For authentication, provide a RSC Service Account JSON defined at variable $serviceAccountPath.

Update the the PARAM and VARIABLES section as needed.

.EXAMPLE
./Get-EventStatus-SQL.ps1
Get the event status of a RSC job.

#>

param (
  [CmdletBinding()]
  # RSC URL, without 'my.rubrik.com'
  [Parameter(Mandatory=$false)]
  [string]$rscName,
  # Cluster UUID
  [Parameter(Mandatory=$false)]
  [string]$clusterUUID,
  # Event request URL - we will split it in this script
  [Parameter(Mandatory=$false)]
  [string]$requestURL,
  # Request type, eg = 'MSSQL_SNAPSHOT'
  [Parameter(Mandatory=$false)]
  [string]$requestType
)

$date = Get-Date

# JSON of RSC authentication
$serviceAccountPath = "./rsc-service-account-rr.json"

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

$payload = @{
  grant_type = "client_credentials";
  client_id = $serviceAccountFile.client_id;
  client_secret = $serviceAccountFile.client_secret
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

$headers = @{
  'Content-Type' = 'application/json';
  'Accept' = 'application/json';
}

Write-Verbose -Message "Connecting to the RSC GraphQL API using the Service Account JSON file."
$response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers

$rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")
$global:rubrikConnection = @{
  accessToken = $response.access_token;
  rubrikURL = $rubrikURL
}

# Rubrik GraphQL API URL
$endpoint = $rubrikConnection.rubrikURL + "/api/graphql"

$headers = @{
  'Content-Type'  = 'application/json';
  'Accept' = 'application/json';
  'Authorization' = $('Bearer ' + $rubrikConnection.accessToken);
}

Write-Host "Successfully connected to: $rubrikURL."

Connect-Rubrik -server $server -id $serviceAccountFile.client_id -secret $serviceAccountFile.client_secret -RedirectToRSC

###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# Get Event Progress
Function Get-EventProgress {
  param (
    [CmdletBinding()]
    # RSC account Name
    [Parameter(Mandatory=$false)]
    [string]$rscName,
    # Cluster UUID
    [Parameter(Mandatory=$false)]
    [string]$clusterUUID,
    # Event request ID (href)
    [Parameter(Mandatory=$false)]
    [string]$requestID,
    # Request type
    [Parameter(Mandatory=$false)]
    [string]$requestType
  )
  $variables = @{
    "input" = @{
      "accountName" = $rscName
      "additionalInfo" = @{
        "mssqlDbInfo" = $null
      }
      "clusterUuid" = $clusterUUID
      "requestId" = $requestID
      "type" = $requestType
    }
  }
  $query = "query (`$input: JobInfoRequest!) {
    jobInfo(input: `$input) {
      status
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result
}  ### Function Get-EventProgress

$splitURL = $requestURL -split "request/"
$requestID = $splitURL[1]

$result = Get-EventProgress -rscName $rscName -clusterUUID $clusterUUID -requestID $requestID -requestType $requestType

if ($result.errors) {
  Write-Error "Error getting request"
  Write-Error "Error message: $($result.errors.message)"
  Write-Error "Error message: $($result.errors.extensions)"
  exit
}

$requestStatus = $result.data.jobInfo.status

Write-Host "Job status: $requestStatus" -foregroundcolor green
