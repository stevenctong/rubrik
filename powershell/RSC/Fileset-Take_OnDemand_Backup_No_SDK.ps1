<#
.SYNOPSIS
This script take an on demand Fileset backup using the local REST API.

.DESCRIPTION
This script take an on demand Fileset backup using the local REST API.

The script will check and exit if it finds that the last backup event for the
Fileset is not in a completed job state.

There is an option for the script to continue looping and checking for status.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 3/7/25

For authentication, provide a RSC Service Account JSON defined at variable $serviceAccountPath.

This script uses the local cluster (CDM) Fileset ID and SLA ID as parameters.
To find those IDs, login to the local cluster UI.

Fileset ID - you can find the Fileset ID by browsing to the Fileset under
the Host and the Filset ID will be in the URL like: Fileset:::9b603ba0-5964-476d-8eb6-e6c85b4d4663.

SLA ID - you can find the SLA ID by browsing to the SLA and the SLA ID
will be in the URL like: 60819dff-8436-4aa1-b299-90afb81c34a9.

Update the the PARAM and VARIABLES section as needed.

.EXAMPLE
./Fileset-Take_OnDemand_Backup_No_SDK.ps1 -serviceAccountPath ./rsc_svc.json
  -cluster <rubrik_hostname_or_IP> -filesetID <fileset_ID>
  -slaID <sla_ID>
Take an on demand backup of a Fileset.
#>

param (
  [CmdletBinding()]
  # Rubrik cluster hostname or IP
  [Parameter(Mandatory=$false)]
  [string]$cluster = '',
  # RSC Service Account json
  [Parameter(Mandatory=$false)]
  [string]$serviceAccountPath = '',
  # Local Cluster (CDM) Fileset ID
  [Parameter(Mandatory=$false)]
  [string]$filesetID = '',
  # Local Cluster (CDM) SLA ID
  [Parameter(Mandatory=$false)]
  [string]$slaID = '',
  # Whether to loop and check status
  [Parameter(Mandatory=$false)]
  [bool]$loopStatusCheck = $false
)

$date = Get-Date

$jobFinishedStatuses = @('SUCC', 'FAIL', 'CANCELED')

# SMTP configuration if you want to send an email at the end of this script
# $emailTo = @('')
# $emailFrom = ''
# $SMTPServer = ''
# $SMTPPort = '25'
# $emailSubject = "On Demand Fileset Backup - " + $date.ToString("yyyy-MM-dd HH:MM")

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
  Write-Host "Connected to Rubrik cluster: $cluster" -foregroundcolor green
} else {
  Write-Error "Could not connect to Rubrik cluster: $cluster"
}

###### RUBRIK AUTHENTICATION - END ######

# Get Fileset info
$filesetInfo = Invoke-RestMethod -Method GET -Headers $headers -contentType $contentType `
  -Uri "https://$cluster/api/v1/fileset/$filesetID" -SkipCertificateCheck

if ($filesetInfo.count -eq 1) {
  $filesetName = $filesetInfo.name
  Write-Host "Found fileset: $filesetName, with Fileset ID: $filesetID" -foregroundcolor green
} else {
  if ($filesetInfo.count -gt 1) {
    Write-Error "Found multiple Filesets with ID: $filesetID"
    $filesetInfo
    exit
  } else {
    Write-Error "Could not find Fileset ID: $filesetID"
    exit
  }
}

# Get last few backup events for the Fileset
$eventInfo = Invoke-RestMethod -Method GET -Headers $headers -contentType $contentType `
  -Uri "https://$cluster/api/v1/event/latest?event_type=Backup&object_ids=$filesetID" -SkipCertificateCheck

$lastBackupEvent = $eventInfo.data[0].latestEvent
Write-Host ""
Write-Host "Last backup time: $($lastBackupEvent.time)" -foregroundcolor green
Write-Host "Last backup status: $($lastBackupEvent.eventStatus)" -foregroundcolor green
Write-Host ""
# Check if the latest backup event has fully completed or not
# $activeJob is set as $true, then loop and check all the completed
# job statuses against the last backup event.
# If a completed job status is found, set $activeJob to $false
$activeJob = $true
foreach ($status in $jobFinishedStatuses) {
  if ($($lastBackupEvent.eventStatus) -match $status) {
    $activeJob = $false
  }
}

if ($activeJob) {
  Write-Host "Previous backup event is still active, exiting..."
  exit
}


if ($filesetInfo.count -eq 1) {
  $filesetName = $filesetInfo.name
  Write-Host "Found fileset: $filesetName, with Fileset ID: $filesetID" -foregroundcolor green
} else {
  if ($filesetInfo.count -gt 1) {
    Write-Error "Found multiple Filesets with ID: $filesetID"
    $filesetInfo
    exit
  } else {
    Write-Error "Could not find Fileset ID: $filesetID"
    exit
  }
}

# Get SLA info
$slaInfo = Invoke-RestMethod -Method GET -Headers $headers -contentType $contentType `
  -Uri "https://$cluster/api/v2/sla_domain/$slaID" -SkipCertificateCheck

if ($slaInfo.count -eq 1) {
  $slaName = $slaInfo.name
  Write-Host "Found SLA: $slaName, with SLA ID: $slaID" -foregroundcolor green
} else {
  if ($slaInfo.count -gt 1) {
    Write-Error "Found multiple SLAs with ID: $slaID"
    $slaInfo
    exit
  } else {
    Write-Error "Could not find SLA ID: $slaID"
    exit
  }
}

Write-Host "Attempting on demand Fileset backup of Fileset: $filesetName ($filesetID) with SLA: $slaName ($slaID)." -foregroundcolor green

$filesetBody = [PSCustomObject] @{
  "slaId" = $slaID
}

$response = Invoke-RestMethod -Method POST -Headers $headers -contentType $contentType `
  -Uri "https://$cluster/api/v1/fileset/$filesetID/snapshot" -Body $filesetBody `
  -SkipCertificateCheck

Write-Host $response

if ($loopStatusCheck -eq $true) {
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
  $finalStatus = $response.status
  $startTime = $response.startTime
  $endTime = $response.endTime
  # Send an email when completed
  if ($sendEmail) {
    $htmlReport = ""
    $htmlReport += "Status: $finalStatus"
    $htmlReport += "Fileset: $filesetName ($filesetID)"
    $htmlReport += "Start time: $startTime"
    $htmlReport += "End time: $endTime"
    Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $HTMLReport -SmtpServer $SMTPServer -Port $SMTPPort
  }
} # if loopStatusCheck
