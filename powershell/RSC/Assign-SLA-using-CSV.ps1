# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will read in a CSV with backup IDs and assign a new SLA to them.

.DESCRIPTION
This script will read in a CSV with backup IDs and assign a new SLA to them.

If a SLA ID is provided in the CSV, it will be used. Otherwise, a default SLA ID
can be provided as an argument and used. The SLA ID can be found by browsing to
a SLA, looking at the URL, and grabbing it from there.

This script can be used with the 'Get-RubrikBackups.ps1' script to get a list
of backup IDs to assign a new SLA to. That script can be run after this one
to valdate that the new SLA was assigned.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 6/29/25

The script requires communication to RSC via outbound HTTPS (TCP 443).

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath

Update this variable to point to your RSC Service Account JSON:
- $serviceAccountPath

.EXAMPLE
./Assign-SLA-using_CSV.ps1 -inputCSV './rubrik_backup_list-2025-06-30.csv' -slaID '<sla ID>'
Runs the script with the provided CSV and assigns all backup IDs to the SLA ID if not defined in the CSV.

#>

### VARIABLES - BEGIN ###

param (
  [CmdletBinding()]
  # CSV containing list of backup (snapshot) IDs to set a new SLA to
  [string]$inputCSV = '',
  # SLA ID to use as the default SLA if no SLA ID is provided in the CSV
  [string]$slaID = ''
)

# $inputCSV = './assignlist.csv'
# $slaID = '739484ea-c05e-4231-978e-302f34bd304e'

# File location of the RSC service account json
$serviceAccountPath = "./rsc-gaia.json"

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# CSV output of backups matching criteria
$csvOutput = "./rubrik_backup_list-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

### VARIABLES - END ###

if ($psversiontable.psversion -lt 7) {
  Write-Error "PowerShell version is: $($psversiontable.psversion)"
  Write-Error "Please use PowerShell version 7+"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls12, [Net.SecurityProtocolType]::Ssl3
  [Net.ServicePointManager]::SecurityProtocol = "Tls, Tls11, Tls12, Ssl3"
}

###### RUBRIK AUTHENTICATION - BEGIN ######
Write-information -Message "Info: Attempting to read the Service Account file located at $serviceAccountPath"
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
if ($null -eq $serviceAccountFile.client_id) {
  $missingServiceAccount += "'client_id'"
}

if ($null -eq $serviceAccountFile.client_secret) {
  $missingServiceAccount += "'client_secret'"
}

if ($null -eq $serviceAccountFile.access_token_uri) {
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
###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# Assign a SLA to a specific backup retention ID
Function Assign-SLA-to-BackupID {
  param (
    [CmdletBinding()]
    # Backup ID to assign a SLA to
    [Parameter(Mandatory=$true)]
    [string]$backupID,
    # SLA ID
    [Parameter(Mandatory=$true)]
    [string]$slaID
  )
  $variables = @{
    "userNote" = ""
    "globalSlaAssignType" = "protectWithSlaId"
    "snapshotFids" = @(
      $backupID
    )
    "globalSlaOptionalFid" = $slaID
  }
  $query = 'mutation ChangeSnapshotsRetentionMutation($globalSlaAssignType: SlaAssignTypeEnum!, $snapshotFids: [UUID!]!, $globalSlaOptionalFid: UUID, $userNote: String) {
    assignRetentionSLAToSnapshots(globalSlaAssignType: $globalSlaAssignType, snapshotFids: $snapshotFids, globalSlaOptionalFid: $globalSlaOptionalFid, userNote: $userNote) {
      success
      __typename
    }
  }'
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $status = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $status
}  ### Function Assign-SLA-to-BackupID


###### FUNCTIONS - END ######

if ($inputCSV -eq '') {
  Write-Error "Please provide a CSV with a list of backup IDs to re-assign, existing..."
  exit
}

$backupList = Import-CSV -Path $inputCSV
$backupCount = $backupList.count
Write-Host "Found $backupCount items" -foregroundcolor green

$count = 1

foreach ($backup in $backupList) {
  $aSLAid = ''
  if (![string]::IsNullOrWhiteSpace($backup.'Assign SLA ID')) {
    $aSLAid = $backup.'Assign SLA ID'
  } else {
    if ($slaID -ne '') {
      $aSLAid = $slaID
    } else {
      Write-Host "[$count / $backupCount] Skipping $($backup.name) ($($backup.Workload)) - No SLA ID provided..."
    }
  }
  if ($aSLAid -ne '') {
    Write-Host "[$count / $backupCount] Assigning SLA ($aSLAid) to $($backup.name) ($($backup.Workload)) for $($backup.'Backup Date EST')"
    $status = Assign-SLA-to-BackupID -backupID $($backup.'Snapshot ID') -slaID $aSLAid
    if ($status.data.assignRetentionSLAToSnapshots.success -ne $true) {
      Write-Error "There may have been an error with this assignment"
      $status.errors.message
    }
  }
  $count++
}
