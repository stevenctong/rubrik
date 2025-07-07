# https://www.rubrik.com/api
<#
.SYNOPSIS
This script gets and displays a Bearer token using a RSC Service Account.

.DESCRIPTION
This script gets and displays a Bearer token using a RSC Service Account.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 7/7/25

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only reporting role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath

.EXAMPLE
./Get-RSC_Token.ps1 -serviceAccountPath <filepath to RSC json>
Runs the script to output the RSC GraphQL API bearer token.

.EXAMPLE
./Get-RSC_Token.ps1 -cluster <cluster IP or host> -serviceAccountPath <filepath to RSC json>
Runs the script to output the cluster REST API bearer token.
#>

### Variables section - please fill out as needed

param (
  [CmdletBinding()]
  # Filepath to the RSC Service Account json
  [Parameter(Mandatory=$false)]
  [string]$serviceAccountPath = '',
  # Rubrik Cluster Hostname/IP if wanting to get REST API token
  [Parameter(Mandatory=$false)]
  [string]$cluster = ''
)

### End Variables section

###### RUBRIK AUTHENTICATION - BEGIN ######

Write-Host "Attempting to read the Service Account file: $serviceAccountPath"
try {
  $serviceAccountFile = Get-Content -Path "$serviceAccountPath" -ErrorAction Stop | ConvertFrom-Json
} catch {
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

if ($clusterIP -eq '') {
  $headers = @{
    'Content-Type' = 'application/json';
    'Accept' = 'application/json';
  }

  $payload = @{
    grant_type = "client_credentials";
    client_id = $serviceAccountFile.client_id;
    client_secret = $serviceAccountFile.client_secret
  }

  $rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")

  Write-Host "Connecting to RSC to get an auth token: $rubrikURL"
  $response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers

  $global:rubrikConnection = @{
    accessToken = $response.access_token;
    rubrikURL = $rubrikURL
  }

  if ($null -eq $rubrikConnection.accessToken) {
    throw "Error getting access token, exiting..."
  }

  # Rubrik GraphQL API URL
  $endpoint = $rubrikConnection.rubrikURL + "/api/graphql"

  $headers = @{
    'Content-Type'  = 'application/json';
    'Accept' = 'application/json';
    'Authorization' = $('Bearer ' + $rubrikConnection.accessToken);
  }

  Write-Host "Successfully connected to: $rubrikURL" -foregroundcolor green
  Write-Host "Bearer token for RSC GraphQL API is below" -foregroundcolor green
  Write-Host "Bearer $($rubrikConnection.accessToken)"
} else {
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
    Write-Host "Successfully connected to Rubrik cluster: $cluster" -foregroundcolor green
    Write-Host "Bearer token for cluster REST API is below" -foregroundcolor green
    Write-Host "Bearer $token"
  }
}

###### RUBRIK AUTHENTICATION - END ######
