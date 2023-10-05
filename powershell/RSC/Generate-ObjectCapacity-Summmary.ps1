# https://www.rubrik.com/api
<#
.SYNOPSIS
This script summrizes information from a Rubrik Object Capacity report.

.DESCRIPTION
This script summrizes information from a Rubrik Object Capacity report.

Users will need to create a custom report in Rubrik Security Cloud and
provide access to those reports via a RSC service account w/read-only permissions.

The script can be scheduled to run on a server daily in order to generate
the html report.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 10/5/23

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only reporting role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath

An "Object Capacity" report should be created with whatever filters you want:
- Note: Should only contain on prem workloads

For each report, grab the report ID. This can be seen as the # in the URL
when you have the report open.

Fill out the report ID in these two variables:
- $reportIDObjectCapacity

If you want the report to be emails, fill out the SMTP information and set
the variable $sendEmail to $true.

.EXAMPLE
./Generate-ObjectCapacity-Summary.ps1
Runs the script to generate the summary
#>

### Variables section - please fill out as needed


# File location of the RSC service account json
$serviceAccountPath = "./rsc-service-account-rr.json"

# The report ID for the custom report
$reportIDObjectCapacity = 102

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# Whether save the report CSV for each run or not
$saveCSV = $true
$csvFileName = "./csvReports/rubrik_objectcapacity_csv-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# SMTP configuration if you want to send an email at the end of this script
# $emailTo = @('')
# $emailFrom = ''
# $SMTPServer = ''
# $SMTPPort = '25'
# $emailSubject = "Rubrik Protection Summary - " + $date.ToString("yyyy-MM-dd HH:MM")

# Set to $true to send out email at the end of this script
# $sendEmail = $false

# Define the capacity metric conversions
$GB = 1000000000
$GiB = 1073741824
$TB = 1000000000000
$TiB = 1099511627776

# Set which capacity metric to use
$capacityMetric = $GB
$capacityDisplay = 'GB'

### End Variables section

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
###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# Trigger generating a CSV for a report
Function Generate-ReportCSV {
  param (
    [CmdletBinding()]
    # Report ID
    [Parameter(Mandatory=$true)]
    [int]$reportID
  )
  $variables = @{
    "id" = $reportID
  }
  $query = "mutation (`$id: Int!, `$config: CustomReportCreate) {
    downloadReportCsvAsync(input: {id: `$id, config: `$config}) {
      jobId
      referenceId
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $response = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers
  return $response.data.downloadReportCsvAsync
} ### Function Generate-ReportCSV

# Get the report name via report ID
Function Get-ReportName {
  param (
    [CmdletBinding()]
    # Report ID
    [Parameter(Mandatory=$true)]
    [int]$reportID
  )
  $variables = @{
    "filter" = @{
      "focus" = $null
      "searchTerm" = ""
      "isHidden" = $false
    }
  }
  $query = "query (`$filter: CustomReportFilterInput) {
    reportConnection(filter: `$filter) {
      nodes {
        id
        name
        focus
        updatedAt
      }
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $reportList = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers).data.ReportConnection.nodes
  $reportName = $($reportList | Where-Object -Property 'id' -eq $reportID).name
  return $reportName
} ### Get-ReportName

# Get the CSV download status
Function Get-DownloadStatus {
  $query = "query {
    getUserDownloads {
      id
      name
      status
      progress
      identifier
      createTime
      completeTime
    }
  }"
  $payload = @{
    "query" = $query
  }
  $response = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $response.data.getUserDownloads
} ### Get-DownloadStatus

# Get the CSV link for a report that is ready to be downloaded
Function Get-CSVDownloadLink {
  param (
    [CmdletBinding()]
    # Download ID
    [Parameter(Mandatory=$true)]
    [int]$downloadID
  )
  $variables = @{
    "downloadId" = $downloadID
  }
  $query = "mutation generateDownloadUrlMutation(`$downloadId: Long!) {
    getDownloadUrl(downloadId: `$downloadId) {
      url
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $response = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $response.data.getDownloadUrl.url
} ### Get-CSVDownloadLink

# Trigger downloading a CSV for a report and return the download link
Function Get-ReportCSVLink {
  param (
    [CmdletBinding()]
    # Report ID to get CSV for
    [Parameter(Mandatory=$true)]
    [int]$reportID
  )
  $reportName = Get-ReportName -reportID $reportID
  if ($reportName -eq $null) {
    Write-Error "No report found for report ID: $reportID, exiting..."
    exit
  }
  Write-Host "Generating CSV for report: $reportName (report ID: $reportID)" -foregroundcolor green
  # First trigger creation of the CSV
  $responseCreateCSV = Generate-ReportCSV -reportID $reportID
  # Then monitor for when the CSV is ready and then download it
  $downloadStatus = Get-DownloadStatus
  $jobToMonitor = $downloadStatus | Where { $_.name -match $reportName -and ($_.status -match 'PENDING' -or $_.status -match 'IN_PROGRESS') }
  Write-Host "Waiting for CSV to be ready, current status: $($jobToMonitor.status)"
  do {
    Start-Sleep -seconds 10
    $downloadStatus = Get-DownloadStatus | Where { $_.id -eq $jobToMonitor.id }
    Write-Host "Waiting for CSV to be ready, current status: $($downloadStatus.status)"
  } while ( $downloadStatus.status -notmatch 'COMPLETED' )
  $downloadURL = Get-CSVDownloadLink -downloadID $jobToMonitor.id
  return $downloadURL
}  ### Function Get-ReportCSVLink

###### FUNCTIONS - END ######

# Download the current daily protection task report
$dailyTaskCSVLink = Get-ReportCSVLink -reportID $reportIDObjectCapacity
if ($PSVersionTable.PSVersion.Major -le 5) {
  $rubrikObjCapacity = $(Invoke-WebRequest -Uri $dailyTaskCSVLink).content | ConvertFrom-CSV
  if ($saveCSV) {
    $rubrikObjCapacity | Export-CSV -path $csvFileName
  }
} else {
  $rubrikObjCapacity = $(Invoke-WebRequest -Uri $dailyTaskCSVLink -SkipCertificateCheck).content | ConvertFrom-CSV
  if ($saveCSV) {
    $rubrikObjCapacity | Export-CSV -path $csvFileName
  }
}
Write-Host "Downloaded the Protection Task Report CSV: $($RubrikObjCapacity.count) tasks" -foregroundcolor green

# Getting object types in the report
$objectTypes = $RubrikObjCapacity | select -expandProperty 'Object Type' -Unique

# For each type of object, calculate the total data transferred and data stored
$objectSummary = @()

# For each object type, calculate data transferred and data stored
# Note: we will exclude MV and AD at this time for data stored since it does not have values
foreach ($obj in $objectTypes)
{
  $objRubrikObjCapacity = $RubrikObjCapacity | Where 'Object Type' -eq $obj
  $dataTransSumMetric = ($objRubrikObjCapacity | Measure -Property 'Bytes transferred' -sum).sum / $capacityMetric
  $dataTransSumMetric = [math]::Round($dataTransSumMetric, 3)
  $dataStoredSumMetric = ($objRubrikObjCapacity | Measure -Property 'Local Storage' -sum).sum / $capacityMetric
  $dataStoredSumMetric = [math]::Round($dataStoredSumMetric, 3)
  $dataArchivalSumMetric = ($objRubrikObjCapacity | Measure -Property 'Archival Storage' -sum).sum / $capacityMetric
  $dataArchivalSumMetric = [math]::Round($dataArchivalSumMetric, 3)
  $objItem = [PSCustomObject] @{
    "Object Type" = $obj
    "Object Count" = $objRubrikObjCapacity.count
    "Sum Bytes Transferred ($capacityDisplay)" = $dataTransSumMetric
    "Sum Local Storage ($capacityDisplay)" = $dataStoredSumMetric
    "Sum Archival Storage ($capacityDisplay)" = $dataArchivalSumMetric
  }
  $objectSummary += $objItem
}

# Calculate total number of objects
$sumObjectCount = $RubrikObjCapacity.count

# Calculate all data transferred across all objects
$sumAllDataTransferredMetric = ($RubrikObjCapacity | Measure -Property 'Bytes transferred' -sum).sum / $capacityMetric
$sumAllDataTransferredMetric = [math]::Round($sumAllDataTransferredMetric, 3)

# Calculate all data stored across all objects
# $rubrikStoredObjects = $RubrikObjCapacity | Where { $_.'Object Type' -ne 'ManagedVolume' -and $_.'Object Type' -ne 'ActiveDirectoryDomainController' }
$sumAllDataStoredMetric = ($RubrikObjCapacity | Measure -Property 'Local Storage' -sum).sum / $capacityMetric
$sumAllDataStoredMetric = [math]::Round($sumAllDataStoredMetric, 3)

# Calculate all arhival stored across all jobs
$sumAllArchivalStoredMetric = ($RubrikObjCapacity | Measure -Property 'Archival Storage' -sum).sum / $capacityMetric
$sumAllArchivalStoredMetric = [math]::Round($sumAllArchivalStoredMetric, 3)

Write-Host ""
Write-Host "Current date: $date" -foregroundcolor green
Write-Host ""
Write-Host "Sum of capacity per object type" -foregroundcolor green
Write-Host ""
$objectSummary | format-table
Write-Host ""
Write-Host "Sum of Object Count: $sumObjectCount" -foregroundcolor green
Write-Host "Sum of Bytes Transferred ($capacityDisplay): $sumAllDataTransferredMetric" -foregroundcolor green
Write-Host "Sum of Local Storage ($capacityDisplay): $sumAllDataStoredMetric" -foregroundcolor green
Write-Host "Sum of Archival Stored ($capacityDisplay): $sumAllDataStoredMetric" -foregroundcolor green

# Send an email with CSV attachment
if ($sendEmail) {
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $HTMLReport -SmtpServer $SMTPServer -Port $SMTPPort
}
