# https://www.rubrik.com/api
<#
.SYNOPSIS
This script creates a custom html report for Rubrik object compliance and
Rubrik tasks. The html can be emailed if SMTP details are provided.

.DESCRIPTION
This script creates a custom html report for Rubrik object compliance and
Rubrik tasks. The html can be emailed if SMTP details are provided.

Users will need to create two custom reports in Rubrik Security Cloud and
provide access to those reports via a RSC service account w/read-only permissions.

The script can be scheduled to run on a server daily in order to generate
the html report.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 3/13/23
Updated: 9/13/23

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only reporting role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath

Two RSC custom reports will need to be created:
1. Object Compliance Report - Filters: Past 24 hours
2. Protection Task Details Report - Filter: Past 24 hours, backup jobs

For each report, grab the report ID. This can be seen as the # in the URL
when you have the report open.

Fill out the report ID in these two variables:
- $reportIDdailyComplianceReport
- reportIDdailyTaskReport

If you want the report to be emails, fill out the SMTP information and set
the variable $sendEmail to $true.


.EXAMPLE
./Generate-Rubrik-Custom_Compliance_Report.ps1
Runs the script to generate the custom html report.
#>

### Variables section - please fill out as needed

param (
  [CmdletBinding()]

  # Sort order options: "Start time", "End time", "Duration", "Data transferred"
  [Parameter(Mandatory=$false)]
  [string]$sortOrder = 'Start time'
)

# File location of the RSC service account json
$serviceAccountPath = "./rsc-service-account-rr.json"

# The report IDs for the two custom reports that are created
$reportIDdailyComplianceReport = 53
$reportIDdailyTaskReport = 52

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# Whether to list successful tasks or not in the report
$showSuccess = $true

# Whether to export the html as a file along with file path
$exportHTML = $true
$htmlOutput = "./Rubrik-Daily_Object_Report-$($date.ToString("yyyy-MM-dd_HHmm")).html"

# SMTP configuration if you want to send an email at the end of this script
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'
$emailSubject = "Rubrik Daily Compliance and Task Report - " + $date.ToString("yyyy-MM-dd HH:MM")

# Set to $true to send out email at the end of this script
$sendEmail = $false

# Debug output
$debug = $false

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
$dailyTaskCSVLink = Get-ReportCSVLink -reportID $reportIDdailyTaskReport
if ($PSVersionTable.PSVersion.Major -le 5) {
  $rubrikTasks = $(Invoke-WebRequest -Uri $dailyTaskCSVLink).content | ConvertFrom-CSV
} else {
  $rubrikTasks = $(Invoke-WebRequest -Uri $dailyTaskCSVLink -SkipCertificateCheck).content | ConvertFrom-CSV
}
Write-Host "Downloaded the Daily Task Report CSV: $($rubrikTasks.count) tasks" -foregroundcolor green

# Download the current object compliance report
$complianceCSVLink = Get-ReportCSVLink -reportID $reportIDdailyComplianceReport
if ($PSVersionTable.PSVersion.Major -le 5) {
  $rubrikCompliance = $(Invoke-WebRequest -Uri $complianceCSVLink).content | ConvertFrom-CSV
} else {
  $rubrikCompliance = $(Invoke-WebRequest -Uri $complianceCSVLink -SkipCertificateCheck).content | ConvertFrom-CSV
}
Write-Host "Downloaded the Object Compliance CSV: $($rubrikCompliance.count) objects" -foregroundcolor green


# Get unique cluster names
$clusterList = $rubrikTasks | Select-Object 'Cluster Name' -unique -expandProperty 'Cluster Name'

# Create a hash table to keep the task status and compliance counts for each cluster
$clusterCountHash = @{}
foreach ($cluster in $clusterList)
{
  $clusterObj = [PSCustomObject] @{
    "SuccessCount" = 0
    "PartiallySucceededCount" = 0
    "CanceledCount" = 0
    "FailedCount" = 0
    "TotalCount" = 0
    "SuccessRate" = [float]0
    "InCompliance" = 0
    "OutCompliance" = 0
    "TotalCompliance" = 0
    "ComplianceRate" = [float]0
  }
  $clusterCountHash.add($($cluster),$clusterObj)
}

# PSCustomObject to keep track of all counts for all clusters
$clusterTotal = [PSCustomObject] @{
  "SuccessCount" = 0
  "PartiallySucceededCount" = 0
  "CanceledCount" = 0
  "FailedCount" = 0
  "TotalCount" = 0
  "PartiallySucceededRate" = [float]0
  "SuccessRate" = [float]0
  "InCompliance" = 0
  "OutCompliance" = 0
  "TotalCompliance" = 0
  "ComplianceRate" = [float]0
}

$rubrikTasksCount = $rubrikTasks.count
Write-Host "Processing $rubrikTasksCount tasks" -foregroundcolor green
$count = 1

# Process each task and calculate some values
foreach ($i in $rubrikTasks)
{
  if (($count % 500) -eq 0) {
    Write-Host "Processing tasks: $count of $rubrikTasksCount"
  }
  $count += 1
  # Track the task status counts for each cluster
  $clusterCountHash[$i.'Cluster Name'].'TotalCount' += 1
  if ($i.'Task Status' -match 'Success') {
    $clusterCountHash[$i.'Cluster Name'].'SuccessCount' += 1
  } elseif ($i.'Task Status' -match 'Partially Succeeded') {
    $clusterCountHash[$i.'Cluster Name'].'PartiallySucceededCount' += 1
  } elseif ($i.'Task Status' -match 'Failed') {
    $clusterCountHash[$i.'Cluster Name'].'FailedCount' += 1
  } elseif ($i.'TaskStatus' -match 'Canceled') {
    $clusterCountHash[$i.'Cluster Name'].'CanceledCount' += 1
  }
  # Update the timestamps to Powershell 'datetime' format so we can do comparisons
  $i.'Start Time' = ([datetime]($i.'Start Time'.replace("UTC", "GMT"))).ToUniversalTime()
  $i.'End Time' = ([datetime]($i.'End Time'.replace("UTC", "GMT"))).ToUniversalTime()
  # Duration is in milliseconds. Calculate out the hours, min, and seconds.
  # Create a field that returns the duration as a string with hours, min, and seconds.
  $i.duration = [int]$i.duration
  $durationSeconds = $i.Duration / 1000
  $durationHours =  [math]::Floor($durationSeconds / 3600)
  $durationMinutes =  [math]::Floor(($durationSeconds / 60) - ($durationHours * 60))
  $durationSeconds = [math]::Floor($durationSeconds - ($durationHours * 3600) - ($durationMinutes * 60))
  $durationText = [string]$durationHours + " Hours " + [string]$durationMinutes + " Minutes " + [string]$durationSeconds + " Seconds"
  Add-Member -InputObject $i -MemberType NoteProperty -name 'Duration Text' -value $durationText -Force
  # Data transferred is in bytes. Calculate out the GB and store as a field.
  if ($i.'Data transferred' -ne '' -and $i.'Data transferred' -notmatch 'N/A') {
    $DataTransGB = [math]::Round([float]$i.'Data transferred' / 1000000000, 1)
    Add-Member -InputObject $i -MemberType NoteProperty -name 'Data Trans GB' -value $DataTransGB -Force
  } else {
    Add-Member -InputObject $i -MemberType NoteProperty -name 'Data Trans GB' -value 'N/A' -Force
  }
  # Data stored is in bytes. Calculate out the GB and store as a field.
  if ($i.'Data stored' -ne '' -and $i.'Data stored' -notmatch 'N/A') {
    $DataStoredGB = [math]::Round([float]$i.'Data Stored' / 1000000000, 1)
    Add-Member -InputObject $i -MemberType NoteProperty -name 'Data Stored GB' -value $DataStoredGB -Force
  } else {
    Add-Member -InputObject $i -MemberType NoteProperty -name 'Data Stored GB' -value 'N/A' -Force
  }
}

foreach ($clusterStatus in $clusterCountHash.GetEnumerator())
{
  $value = $($clusterStatus.Value)
  $value.SuccessRate = [math]::round(($value.SuccessCount + $value.PartiallySucceededCount) /
    ($value.SuccessCount + $value.PartiallySucceededCount + $value.FailedCount) * 100, 1)
}

# Create a table of tasks, with Failed tasks followed by Canceled, followed by Successul taks
# Within each grouping, sorted by "Duration" in descending order
Write-Host "Sorting tasks" -foreground green

# Need to initialize array in case there are no failed tasks to start with
$rubrikTasksSorted = @()

$rubrikTasksSorted += $rubrikTasks | Where { $_.'Task status' -match 'Fail' } |
  Sort-Object -property $sortOrder -Descending

$rubrikTasksSorted += $rubrikTasks | Where { $_.'Task status' -match 'Cancel' } |
  Sort-Object -property $sortOrder -Descending

$rubrikTasksSorted += $rubrikTasks | Where { $_.'Task status' -match 'Partially Succeeded' } |
  Sort-Object -property $sortOrder -Descending

$rubrikTasksSorted += $rubrikTasks | Where { $_.'Task status' -match 'Success' } |
  Sort-Object -property $sortOrder -Descending

# Calculate cluster totals for tasks
$clusterTotal.SuccessCount = $($rubrikTasks | Where { $_.'Task status' -match 'Success' }).count
$clusterTotal.PartiallySucceededCount = $($rubrikTasks | Where { $_.'Task status' -match 'Partially Succeeded' }).count
$clusterTotal.CanceledCount = $($rubrikTasks | Where { $_.'Task status' -match 'Cancel' }).count
$clusterTotal.FailedCount = $($rubrikTasks | Where { $_.'Task status' -match 'Fail' }).count
$clusterTotal.TotalCount = $clusterTotal.SuccessCount + $clusterTotal.PartiallySucceededCount + $clusterTotal.CanceledCount + $clusterTotal.FailedCount
$clusterTotal.SuccessRate = [math]::round(($clusterTotal.SuccessCount + $clusterTotal.PartiallySucceededCount) / ($clusterTotal.SuccessCount + $clusterTotal.PartiallySucceededCount + $clusterTotal.FailedCount) * 100, 1)

# Filter for objects that are In Compliance and separately, Out of Compliance
$objectsInCompliance = $rubrikCompliance | Where { $_.'Compliance Status' -match 'In compliance' }
$objectsOutCompliance = $rubrikCompliance | Where { $_.'Compliance Status' -match 'Out of compliance' }

# Calculate cluster totals for compliance
$clusterTotal.InCompliance = $objectsInCompliance.count
$clusterTotal.OutCompliance = $objectsOutCompliance.count
$clusterTotal.TotalCompliance = $clusterTotal.InCompliance + $clusterTotal.OutCompliance
$clusterTotal.ComplianceRate = [math]::round($clusterTotal.InCompliance / $clusterTotal.TotalCompliance * 100, 1)

if ($debug) {
  Write-Host "Compliance Objects" -foregroundcolor yellow
  $rubrikCompliance
  Write-Host ""
  Write-Host "Objects out of compliance list" -foregroundcolor yellow
  $objectsOutCompliance
  Write-Host ""
  Write-Host "Var: clusterTotal.OutCompliance" -foregroundcolor yellow
  $clusterTotal.OutCompliance
  Write-Host ""
  Write-Host "Var: clusterTotal.TotalCompliance" -foregroundcolor yellow
  $clusterTotal.TotalCompliance
}

# For each cluster, get the compliance summary details
foreach ($clusterStatus in $clusterCountHash.GetEnumerator())
{
  $value = $($clusterStatus.Value)
  $value.InCompliance = $($objectsInCompliance | Where { $_ -match $clusterStatus.Name }).count
  $value.OutCompliance = $($objectsOutCompliance | Where { $_ -match $clusterStatus.Name }).count
  $value.TotalCompliance = $value.InCompliance + $value.OutCompliance
  $value.ComplianceRate = [math]::round($value.InCompliance / $value.TotalCompliance * 100, 1)
}

# Process each object out of compliance
foreach ($j in $objectsOutCompliance)
{
  try {
    $j.'Last local snapshot' = ([datetime]($j.'Last local snapshot'.replace("UTC", "GMT"))).ToUniversalTime()
    $j.'Last replication snapshot' = ([datetime]($j.'Last replication snapshot'.replace("UTC", "GMT"))).ToUniversalTime()
    $j.'Last archival snapshot' = ([datetime]($j.'Last archival snapshot'.replace("UTC", "GMT"))).ToUniversalTime()
  } catch {
    # Most likely there is no value here so ignoring the error
  }
  if ($j.'Last local snapshot' -ne '') {
    $localDaysBehind = [math]::round($($utcDate - $j.'Last local snapshot').totalDays, 2)
    Add-Member -InputObject $j -MemberType NoteProperty -name 'Local Days Behind' -value $localDaysBehind -Force
  } else {
    Add-Member -InputObject $j -MemberType NoteProperty -name 'Local Days Behind' -value 'All' -Force
  }
}

$objectsOutCompliance = $objectsOutCompliance | Sort-Object -Property 'Local Days Behind' -Descending

Write-Host "Creating HTML tables" -foregroundcolor green

### Creating HTML table styles ###
### HTML formatting borrowed from: @joshuastenhouse

$HTMLHighlightColor="#FFC000"
$HTMLRubrikColor="#00B2A9"
$HTMLRedColor="#FF3355"
$HTMLGreenColor="#2ED51A"

$HTMLStart = @"
  <!DOCTYPE html>
  <html>
  <head>
  <style>
  table.table2 {
    align: center;
    border: 1px solid black;
  }
  table.table2 th {
    text-align: center;
    border: 1px solid black;
    padding: 8px;
    background-color: white;
    color: $HTMLRubrikColor;
    font-size:14px
  }
  table.table2 td {
    text-align: center;
    border: 1px solid black;
    padding: 5px;
    font-size:14px
  }
  table.table2 tr#failed {
    color: white;
    background-color: $HTMLRedColor;
  }
  table.table2 tr#canceled {
    color: black;
    background-color: yellow;
  }
  table.table2 tr#success {
    color: black;
    background-color: $HTMLGreenColor;
  }
  </style>
  </head>
  <body>
  <center>
  <div style="overflow-x:auto;">
  <br><br>
"@

$HTMLEnd = @"
  </div>
  </body>
  </html>
"@
### End HTML table styles ###

### Create HTML header info
$HTMLHeader = @"
  <b>Rubrik Daily Object Report</b>
  <br>
  <b>Date:</b> $date
  <br><br>
"@
### End HTML header info


### Create HTML Compliance Summary Table
$HTMLComplianceSummaryTable = $null
$HTMLComplianceSummaryTableMiddle = $null

$HTMLComplianceSummaryTableStart = @"
  <table class="table2">
    <tr>
      <th colspan="5">Daily Compliance Summary</th>
    </tr>
    <tr>
      <th>Cluster</th>
      <th>Total</th>
      <th>In Compliance</th>
      <th>Out of Compliance</th>
      <th>Compliance Rate</th>
    </tr>
"@

$HTMLComplianceSummaryTableEnd = @"
  </table>
  <br>
"@

foreach ($clusterStatus in $clusterCountHash.GetEnumerator() | Sort-Object -Property 'name')
{
  $value = $($clusterStatus.Value)
  $HTMLComplianceSummaryTableRow = @"
  <tr>
    <td style=text-align:right>$($clusterStatus.Name)</td>
    <td style=color:$HTMLRubrikColor><b>$($value.'TotalCompliance')</b></td>
    <td style=color:black;background:$HTMLGreenColor>$($value.'InCompliance')</td>
    <td style=color:white;background:$HTMLRedColor>$($value.'OutCompliance')</td>
    <td style=color:$HTMLRubrikColor><b>$($value.'ComplianceRate')</b></td>
  </tr>
"@
  $HTMLComplianceSummaryTableMiddle += $HTMLComplianceSummaryTableRow
}

$HTMLComplianceSummaryTableMiddle += @"
  <tr style=color:white;background:blue>
    <td>Total</td>
    <td>$($clusterTotal.TotalCompliance)</td>
    <td>$($clusterTotal.InCompliance)</td>
    <td>$($clusterTotal.OutCompliance)</td>
    <td>$($clusterTotal.ComplianceRate)</td>
  </tr>
"@

$HTMLComplianceSummaryTable += $HTMLComplianceSummaryTableStart + $HTMLComplianceSummaryTableMiddle + $HTMLComplianceSummaryTableEnd + "<br><br>"
### End HTML Compliance Summary Table


### Create HTML Task Summary Table
$HTMLTaskSummaryTable = $null
$HTMLTaskSummaryTableMiddle = $null

$HTMLTaskSummaryTableStart = @"
  <table class="table2">
    <tr>
      <th colspan="7">Daily Backup Task Summary</th>
    </tr>
    <tr>
      <th>Cluster</th>
      <th>Total</th>
      <th>Success</th>
      <th>Partially Succeeded</th>
      <th>Failed</th>
      <th>Canceled</th>
      <th>Success Rate</th>
    </tr>
"@

$HTMLTaskSummaryTableEnd = @"
  </table>
  <br>
"@

foreach ($clusterStatus in $clusterCountHash.GetEnumerator() | Sort-Object -Property 'name' )
{
  $value = $($clusterStatus.Value)
  $HTMLTaskSummaryTableRow = @"
  <tr>
    <td style=text-align:right>$($clusterStatus.Name)</td>
    <td style=color:$HTMLRubrikColor><b>$($value.'TotalCount')</b></td>
    <td style=color:black;background:$HTMLGreenColor>$($value.'SuccessCount')</td>
    <td style=color:black;background:$HTMLGreenColor>$($value.'PartiallySucceededCount')</td>
    <td style=color:white;background:$HTMLRedColor>$($value.'FailedCount')</td>
    <td style=color:black;background:yellow>$($value.'CanceledCount')</td>
    <td style=color:$HTMLRubrikColor><b>$($value.'SuccessRate')</b></td>
  </tr>
"@
  $HTMLTaskSummaryTableMiddle += $HTMLTaskSummaryTableRow
}

$HTMLTaskSummaryTableMiddle += @"
  <tr style=color:white;background:blue>
    <td>Total</td>
    <td>$($clusterTotal.TotalCount)</td>
    <td>$($clusterTotal.SuccessCount)</td>
    <td>$($clusterTotal.PartiallySucceededCount)</td>
    <td>$($clusterTotal.FailedCount)</td>
    <td>$($clusterTotal.CanceledCount)</td>
    <td>$($clusterTotal.SuccessRate)</td>
  </tr>
"@

$HTMLTaskSummaryTable += $HTMLTaskSummaryTableStart + $HTMLTaskSummaryTableMiddle + $HTMLTaskSummaryTableEnd + "<br><br>"
### End HTML Task Summary Table


### Create HTML Object Out of Compliance Table
$HTMLOutComplianceTable = $null
$HTMLOutComplianceTableMiddle = $null

$HTMLOutComplianceTableStart = @"
  <table class="table2">
    <tr>
      <th colspan="6">Daily Object Out of Compliance Report</th>
    </tr>
    <tr>
      <th>Name</th>
      <th>Host</th>
      <th>Cluster</th>
      <th>Local Days Behind</th>
      <th>Last Local Backup</th>
      <th>Last Replicated Backup</th>
    </tr>
"@

$HTMLOutComplianceTableEnd = @"
  </table>
  <br>
"@

# Loop through each out of compliance object and create a row
foreach ($obj in $objectsOutCompliance)
{
  $HTMLOutComplianceTableRow = @"
  <tr>
    <td style=text-align:left>$($obj.'Object Name')</td>
    <td style=text-align:left>$($obj.'Location')</td>
    <td style=text-align:left>$($obj.'Cluster Name')</td>
    <td style=background:orange>$($obj.'Local Days Behind')</td>
    <td>$($obj.'Last local snapshot')</td>
    <td>$($obj.'Last replication snapshot')</td>
  </tr>
"@
  $HTMLOutComplianceTableMiddle += $HTMLOutComplianceTableRow
}

$HTMLOutComplianceTable += $HTMLOutComplianceTableStart + $HTMLOutComplianceTableMiddle + $HTMLOutComplianceTableEnd + "<br><br>"
### End HTML Object Out of Compliance Table


### Create HTML Task Table
$HTMLTaskTable = $null
$HTMLTaskTableMiddle = $null

$HTMLTaskTableStart = @"
  <table class="table2">
    <tr>
      <th colspan="8">Daily Object Task Report</th>
    </tr>
    <tr>
      <th>Name</th>
      <th>Host</th>
      <th>Cluster</th>
      <th>Status</th>
      <th>Data Transferred (GB)</th>
      <th>Started</th>
      <th>Ended</th>
      <th>Duration</th>
    </tr>
"@

$HTMLTaskTableEnd = @"
  </table>
  <br>
"@

# Loop through each report summary info and create a row
foreach ($task in $rubrikTasksSorted)
{
  if ($task.'Task Status' -match 'Failed')
  {
    $HTMLTaskTableRow = @"
    <tr id="failed">
"@
  } elseif ($task.'Task Status' -match 'Canceled')
  {
    $HTMLTaskTableRow = @"
    <tr id="canceled">
"@
  } elseif ($showSuccess -eq $true)
  {
    $HTMLTaskTableRow = @"
    <tr id="success">
"@
  }
  if ($showSuccess -eq $true)
  {
    $HTMLTaskTableRow += @"
      <td style=text-align:left>$($task.'Object Name')</td>
      <td style=text-align:left>$($task.'Location')</td>
      <td style=text-align:left>$($task.'Cluster Name')</td>
      <td>$($task.'Task Status')</td>
      <td>$($task.'Data Trans GB')</td>
      <td>$($task.'Start Time')</td>
      <td>$($task.'End Time')</td>
      <td>$($task.'Duration Text')</td>
    </tr>
"@

    $HTMLTaskTableMiddle += $HTMLTaskTableRow
  }
}

$HTMLTaskTable += $HTMLTaskTableStart + $HTMLTaskTableMiddle + $HTMLTaskTableEnd + "<br><br>"
### End HTML Task Table

# Put all pieces of HTML together
$HTMLReport = $HTMLStart + $HTMLHeader + $HTMLComplianceSummaryTable + $HTMLTaskSummaryTable + $HTMLOutComplianceTable + $HTMLTaskTable + $HTMLEnd

# Export results to HTML file
if ($exportHTML) {
  $HTMLReport | Out-File -FilePath $htmlOutput
  Write-Host "`nHTML report output to: $htmlOutput" -foregroundcolor green
}

# Send an email with CSV attachment
if ($sendEmail) {
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $HTMLReport -SmtpServer $SMTPServer -Port $SMTPPort
}
