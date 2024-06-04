# https://www.rubrik.com/api
<#
.SYNOPSIS
This script summrizes information from a Rubrik Object Capacity report.

.DESCRIPTION
This script summrizes information from a Rubrik Object Capacity report.

Users will need to create a custom report in Rubrik Security Cloud and
provide access to those reports via a RSC service account w/read-only permissions.

The script can be scheduled to run on a server daily in order to generate a CSV report.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 10/5/23
Updated: 6/4/24 - updated to use new NG report framework

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only reporting role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath

An "Object Capacity" report should be created with whatever filters you want:
- Note: Should only contain on prem workloads

For each report, grab the report ID. This can be seen as the # in the URL
when you have the report open.

Fill out the report ID in this variable:
- $reportIDObjectCapacity

If you want the RSC source report CSV and generated summary saved as a CSV, fill
these variables with a filename:
- $csvFileName = Location to save the RSC report CSV
- $csvResultsFilename = Location to save the generated report CSV

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
$reportIDObjectCapacity = 123

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# Whether save the report CSV for each run or not
$saveCSV = $true
# Location to save the RSC report CSVs
$csvFileName = "./csvReports/rubrik_objectcapacity_csv-$($date.ToString("yyyy-MM-dd_HHmm")).csv"
# Location to save the calculated report
$csvResultsFilename = "./csvResults/rubrik_objectcapacity_report-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# SMTP configuration if you want to send an email at the end of this script
# $emailTo = @('')
# $emailFrom = ''
# $SMTPServer = ''
# $SMTPPort = '25'
# $emailSubject = "Rubrik Object Capacity Summary - " + $date.ToString("yyyy-MM-dd HH:MM")

# Set to $true to send out email at the end of this script
# $sendEmail = $false

# Define the capacity metric conversions
$GB = 1000000000
$GiB = 1073741824
$TB = 1000000000000
$TiB = 1099511627776

# Set which capacity metric to use
$capacityMetric = $TB
$capacityDisplay = 'TB'

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


# Get the report name with NG framework via report ID
Function Get-NGReportName {
  param (
    [CmdletBinding()]
    # Report ID
    [Parameter(Mandatory=$true)]
    [int]$reportID
  )
  $variables = @{
    "polarisReportsFilters" = @(
      @{
        "field" = "FILTER_UNSPECIFIED"
        "reportRooms" = @(
          "REPORT_ROOM_NONE"
        )
      }
    )
  }
  $query = "query (`$polarisReportsFilters: [PolarisReportsFilterInput!]) {
    allRscReportConfigs(polarisReportsFilters: `$polarisReportsFilters) {
      id
      name
      reportViewType
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $reportList = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  $reportName = $($reportList.data.allRscReportConfigs | Where-Object -Property 'id' -eq $reportID).name
  return $reportName
} ### Get-NGReportName

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
    $reportName = Get-NGReportName -reportID $reportID
    if ($reportName -eq $null) {
      Write-Error "No report found for report ID: $reportID, exiting..."
      exit
    }
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
    Write-Host "Saving RSC report CSV to: $csvFileName" -foregroundcolor green
    $rubrikObjCapacity | Export-CSV -path $csvFileName -NoTypeInformation
  }
} else {
  $rubrikObjCapacity = $(Invoke-WebRequest -Uri $dailyTaskCSVLink -SkipCertificateCheck).content | ConvertFrom-CSV
  if ($saveCSV) {
    Write-Host "Saving RSC report CSV to: $csvFileName" -foregroundcolor green
    $rubrikObjCapacity | Export-CSV -path $csvFileName -NoTypeInformation
  }
}
Write-Host "Downloaded the Protection Task Report CSV: $($RubrikObjCapacity.count) tasks" -foregroundcolor green

# Holds all the calculated stats
$statsArray = @()

# Generate a list of clusters to calculate stats for
$clusterList = $rubrikObjCapacity | select -expandProperty 'Cluster' -Unique

# Loop through each cluster and calculate stats
foreach ($cluster in $clusterList)
{
  # Get a sorted list of workloads per cluster
  $clusterWorkloadList = $rubrikObjCapacity | Where { $_.'Cluster' -match $cluster } |
    select -expandProperty 'Object Type' -Unique | Sort
  # Contains the totals for each cluster
  $clusterTotals = [PSCustomObject] @{
    "Cluster" = $cluster
    "Object Type" = 'Total'
    "Object Count" = 0
    "Bytes Transferred ($capacityDisplay)" = 0
    "Local Storage ($capacityDisplay)" = 0
    "Archival Storage ($capacityDisplay)" = 0
  }
  # For each workload, calculate the stats
  foreach ($clusterWorkload in $clusterWorkloadList)
  {
    # Get all objects that match the cluster name and workload we are interested in
    $clusterWorkloadStatsList = @($rubrikObjCapacity |
      Where { $_.'Object Type' -eq $clusterWorkload -and $_.'Cluster' -eq $cluster })
    # Calculate each stat - Data Transferred, Stored, and Archived
    # Each time, also add to the cluster totals
    $clusterDataTransSumMetric = ($clusterWorkloadStatsList | Measure -Property 'Bytes transferred' -sum).sum / $capacityMetric
    $clusterDataTransSumMetric = [math]::Round($clusterDataTransSumMetric, 3)
    $clusterTotals."Bytes Transferred ($capacityDisplay)" += $clusterDataTransSumMetric
    $clusterDataStoredSumMetric = ($clusterWorkloadStatsList | Measure -Property 'Local Storage' -sum).sum / $capacityMetric
    $clusterDataStoredSumMetric = [math]::Round($clusterDataStoredSumMetric, 3)
    $clusterTotals."Local Storage ($capacityDisplay)" += $clusterDataStoredSumMetric
    $clusterDataArchivalSumMetric = ($clusterWorkloadStatsList | Measure -Property 'Archival Storage' -sum).sum / $capacityMetric
    $clusterDataArchivalSumMetric = [math]::Round($clusterDataArchivalSumMetric, 3)
    $clusterTotals."Archival Storage ($capacityDisplay)" += $clusterDataArchivalSumMetric
    $clusterTotals."Object Count" += $clusterWorkloadStatsList.count
    # Object to hold the per cluster, per workload stats
    $clusterWorkloadItem = [PSCustomObject] @{
      "Cluster" = $cluster
      "Object Type" = $clusterWorkload
      "Object Count" = $clusterWorkloadStatsList.count
      "Bytes Transferred ($capacityDisplay)" = $clusterDataTransSumMetric
      "Local Storage ($capacityDisplay)" = $clusterDataStoredSumMetric
      "Archival Storage ($capacityDisplay)" = $clusterDataArchivalSumMetric
    }
    # Add the per cluster, per workload totals to the stats array
    $statsArray += $clusterWorkloadItem
  }
  # Add the per cluster totals to the stats array
  $statsArray += $clusterTotals
}

# Get a sorted list of the workloads across all clusters
$workloadList = $rubrikObjCapacity | select -expandProperty 'Object Type' -Unique | Sort

# Contains the totals across all clusters
$allTotals = [PSCustomObject] @{
  "Cluster" = 'All'
  "Object Type" = 'Total'
  "Object Count" = 0
  "Bytes Transferred ($capacityDisplay)" = 0
  "Local Storage ($capacityDisplay)" = 0
  "Archival Storage ($capacityDisplay)" = 0
}

# For each workload across all clusters, calculate the stats
foreach ($workload in $workloadList)
{
  # Get all objects that match the workload we are interested in
  $workloadStatsList = @($rubrikObjCapacity | Where 'Object Type' -eq $workload)
  # Calculate each stat - Data Transferred, Stored, and Archived
  # Each time, also add to the totals
  $dataTransSumMetric = ($workloadStatsList | Measure -Property 'Bytes transferred' -sum).sum / $capacityMetric
  $dataTransSumMetric = [math]::Round($dataTransSumMetric, 3)
  $allTotals."Bytes Transferred ($capacityDisplay)" += $dataTransSumMetric
  $dataStoredSumMetric = ($workloadStatsList | Measure -Property 'Local Storage' -sum).sum / $capacityMetric
  $dataStoredSumMetric = [math]::Round($dataStoredSumMetric, 3)
  $allTotals."Local Storage ($capacityDisplay)" += $dataStoredSumMetric
  $dataArchivalSumMetric = ($workloadStatsList | Measure -Property 'Archival Storage' -sum).sum / $capacityMetric
  $dataArchivalSumMetric = [math]::Round($dataArchivalSumMetric, 3)
  $allTotals."Archival Storage ($capacityDisplay)" += $dataArchivalSumMetric
  $allTotals."Object Count" += $workloadStatsList.count
  # Object to hold the per workload stats across all clusters
  $workloadItem = [PSCustomObject] @{
    "Cluster" = "All"
    "Object Type" = $workload
    "Object Count" = $workloadStatsList.count
    "Bytes Transferred ($capacityDisplay)" = $dataTransSumMetric
    "Local Storage ($capacityDisplay)" = $dataStoredSumMetric
    "Archival Storage ($capacityDisplay)" = $dataArchivalSumMetric
  }
  # Add the per workload totals across all clusters to the stats array
  $statsArray += $workloadItem
}
# Add the totals across all clusters to the array of all calculated stats
$statsArray += $allTotals

Write-Host ""
Write-Host "Current date: $date" -foregroundcolor green
Write-Host ""
$statsArray | format-table

if ($saveCSV) {
  Write-Host "Saving report to: $csvResultsFilename" -foregroundcolor green
  $statsArray | Export-CSV -path $csvResultsFilename -NoTypeInformation
}

# Send an email with CSV attachment
if ($sendEmail) {
  $htmlReport = ""
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $HTMLReport -SmtpServer $SMTPServer -Port $SMTPPort -Attachments $csvResultsFilename
}
