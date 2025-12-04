# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will download a reports CSV from a specific report ID.

.DESCRIPTION
This script will download a reports CSV from a specific report ID.

Users will need to create four custom reports in RSC and provide access
to those reports via a RSC service account w/read-only permissions.

This script requires the corresponding .psd1 file that contains the variables
for this script: Create-Rubrik-Exec-Report.psd1.

This script requires communication to RSC via outbound HTTPS (TCP 443).

This script requires PowerShell v7+.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 12/4/25

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only reporting role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath

For Service Account custom role:
** Create a role with 'View' permission for Reports

Create your custom report and grab the report ID. The report ID number in the URL of ther report.


.EXAMPLE
./Get-Reports-CSV.ps1 -reportID <reportID>
Runs the script to download the reports CSV.
#>

### Variables section - please fill out as needed

param (
  [CmdletBinding()]
  # Report ID - find in the URL of the report
  [Parameter(Mandatory=$false)]
  [int]$reportID = 5
)

$date = Get-Date
$dateString = $date.ToString("yyyy-MM-dd_HHmm")
$utcDate = $date.ToUniversalTime()

# Filepath for the RSC Service Account json creds
$serviceAccountPath = './rsc-service-account-rr.json'

# Filename for the report to be saved
$csvReport = "rubrik_report_csv-$dateString.csv"

### End Variables section

if ($PSVersionTable.PSVersion.Major -le 5) {
  Write-Error "Current PS version: $PSVersionTable.PSVersion.Major"
  Write-Error "Script requires PS version 7+"
  Write-Error "This script may have errors running"
}

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
  if ($response.errors) {
    Write-Error $response.errors.message
  }
  return $response.data.downloadReportCsvAsync
} ### Function Generate-ReportCSV

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
  $query = "query DownloadBarQuery {
  getUserDownloads {
    id
    name
    status
    progress
    identifier
    createTime
    completeTime
    __typename
  }
  allUserFiles {
    downloads {
      externalId
      createdAt
      expiresAt
      completedAt
      creator
      filename
      type
      state
      __typename
    }
    __typename
  }
}"
  $payload = @{
    "query" = $query
  }
  $response = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $response.data.allUserFiles.downloads
} ### Get-DownloadStatus

# Trigger downloading a CSV for a report and return the download link
Function Get-ReportCSVLink {
  param (
    [CmdletBinding()]
    # Report ID to get CSV for
    [Parameter(Mandatory=$true)]
    [int]$reportID
  )
  # Get the report name to check that it exists
  $reportName = Get-NGReportName -reportID $reportID
  if ($reportName -eq $null) {
    Write-Error "No report found for report ID: $reportID, exiting..."
    exit
  }
  Write-Host "Generating CSV for report: $reportName (report ID: $reportID)" -foregroundcolor green
  # Trigger creation of report CSV
  $responseCreateCSV = Generate-ReportCSV -reportID $reportID
  # Get all the recent file download requests
  $downloadStatus = Get-DownloadStatus
  # Filter by file downloads matching the report name we want
  $matchingReports = $downloadStatus | Where-Object { $_.filename -match $reportName }
  # File download job we want should be last one in the array (most recent request)
  $jobToMonitor = $matchingReports[-1]
  # Submitted job will likely be in a PENDING state - grab job ID
  # $jobToMonitor = $downloadStatus | Where-Object { $_.filename -match $reportName -and ($_.state -match 'PENDING' -or $_.status -match 'IN_PROGRESS') }
  Write-Host "Waiting for CSV to be ready, current status: $($jobToMonitor.state)"
  do {
    Start-Sleep -seconds 10
    $downloadStatus = Get-DownloadStatus | Where { $_.externalId -eq $jobToMonitor.externalId }
    Write-Host "Waiting for CSV to be ready, current status: $($jobToMonitor.state)"
  } while ( $downloadStatus.state -notmatch 'READY' )
  # $downloadURL = Get-CSVDownloadLink -downloadID $jobToMonitor.externalId
  $downloadURL = $rubrikURL + '/file-downloads/' + $jobToMonitor.externalId
  return $downloadURL
}  ### Function Get-ReportCSVLink

###### FUNCTIONS - END ######

# Download the report CSV
$reportCSVLink = Get-ReportCSVLink -reportID $reportID
Write-Host "Downloaded report CSV from link: $reportCSVLink" -foregroundcolor green
$reportTable = $(Invoke-WebRequest -Uri $reportCSVLink -Headers $headers -SkipCertificateCheck).content | ConvertFrom-CSV
if ($saveCSV) {
  $reportTable | Export-CSV -path $csvReportTasks -NoTypeInformation
}

