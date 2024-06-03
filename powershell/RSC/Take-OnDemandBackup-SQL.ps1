<#
.SYNOPSIS
This script take an on demand snapshot of a SQL DB.

.DESCRIPTION
This script take an on demand snapshot of a SQL DB.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 12/15/23
Updated: 5/3/24

For authentication, provide a RSC Service Account JSON defined at variable $serviceAccountPath.

Update the the PARAM and VARIABLES section as needed.

.EXAMPLE
./Take-OnDemandBackup-SQL.ps1
Take an On Demand Backup of a SQL DB.

#>

param (
  [CmdletBinding()]
  # SQL DB ID
  [Parameter(Mandatory=$false)]
  [string]$sqlDBID,
  # SLA ID
  [Parameter(Mandatory=$false)]
  [string]$slaID,
  # Rubrik Cluster hostname/IP
  [Parameter(Mandatory=$false)]
  [string]$server,
  # User Note (optional)
  [Parameter(Mandatory=$false)]
  [string]$userNote
)

$date = Get-Date

# CSV file output
$csvOutput = "./file_$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# SMTP configuration if you want to send an email at the end of this script
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'

$emailSubject = "Rubrik ($server) - " + $date.ToString("yyyy-MM-dd HH:MM")
$html = "Body<br><br>"

# Set to $true to send out email at the end of this script
$sendEmail = $false

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

Connect-Rubrik -server $server -id $serviceAccountFile.client_id -secret $serviceAccountFile.client_secret

###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# Take On Demand Backup (SQL)
Function Take-OnDemandBackup-SQL {
  param (
    [CmdletBinding()]
    # SQL DB ID
    [Parameter(Mandatory=$false)]
    [string]$sqlDBID,
    # SLA ID
    [Parameter(Mandatory=$false)]
    [string]$slaID,
    # User Note
    [Parameter(Mandatory=$false)]
    [string]$userNote = ""
  )
  $variables = @{
    "input" = @{
      "config" = @{
        "baseOnDemandSnapshotConfig" = @{
          "slaId" = $slaID
        }
      }
      "id" = $sqlDBID
      "userNote" = $userNote
    }
  }
  $query = "mutation (`$input: CreateOnDemandMssqlBackupInput!) {
    createOnDemandMssqlBackup(input: `$input) {
      links {
        href
        __typename
      }
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $result = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $result
}  ### Function Take-OnDemandBackup-SQL

$result = Take-OnDemandBackup-SQL -sqlDBID $sqlDBID -slaID $slaID -userNote $userNote

if ($result.errors) {
  Write-Error "Error in taking on demand backup"
  Write-Error "Error message: $($result.errors.message)"
  Write-Error "Error message: $($result.errors.extensions)"
  exit
}

Write-Host "Successfully triggered On Demand Snapshot of SQL DB ID: $sqlDBID"

$resultURL = $result.data.createOnDemandMssqlBackup.links.href
$splitURL = $resultURL -split "v1/"
Invoke-RubrikRESTCall -Method GET -Api '1' -Endpoint "$($splitURL[1])"

# Send an email with CSV attachment
if ($sendEmail) {
  $htmlReport = ""
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $HTMLReport -SmtpServer $SMTPServer -Port $SMTPPort -Attachments $csvResultsFilename
}
