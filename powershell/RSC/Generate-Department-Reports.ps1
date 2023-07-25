# https://www.rubrik.com/api
<#
.SYNOPSIS
This script creates custom html reports for Rubrik object compliance and
tasks based on a mapping to different departments.
The html can be emailed if SMTP details are provided.

.DESCRIPTION
This script creates custom html reports for Rubrik object compliance and
tasks based on a mapping to different departments.
The html can be emailed if SMTP details are provided.

Users will need to create three custom reports in Rubrik Security Cloud and
provide access to those reports via a RSC service account w/read-only permissions.

The script can be scheduled to run on a server daily in order to generate
the html report.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 7/24/23

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only reporting role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath

Two RSC custom reports will need to be created:
1. Protection Report - Filters: Past 24 hours; cluster type: Appliance, Virtual, Cloud
2. Object Compliance Report - Filters: Past 24 hours
3. Protection Task Details Report - Filter: Past 24 hours, backup jobs

For each report, grab the report ID. This can be seen as the # in the URL
when you have the report open.

Fill out the report ID in these variables:
- $reportIDProtectionReport
- $reportIDdailyComplianceReport
- $reportIDdailyTaskReport

This script using a mapping file in order to map the Departments for which
to create the html reports for. The mapping file is specified at the variable
'$mappngFile'.

Use the following flag to create or update a mapping file:
-createMapping $true

If there is no existing mapping file found at $mappingFile location
then a new mapping file is created.

If an existing mapping file exists then it will create a current object
list with the mapping filename appended with the current date.

Within the mapping file, note the 'Department' that each object belongs to.

The script will use the mapping file and for each department create a separate html report.

If you want the report to be emails, fill out the SMTP information and set
the variable $sendEmail to $true.

.EXAMPLE
./Generate-Department-Reports.ps1 -createMapping $true
Runs the script to create a new mapping file

.EXAMPLE
./Generate-Department-Reports.ps1
Runs the script to generate the custom html report.
#>

param (
  [CmdletBinding()]

  # Set to true to create a new mapping file based on the Protection Report
  [Parameter(Mandatory=$false)]
  [string]$createMapping = $false
)



### Variables section - please fill out as needed

# File location of the RSC service account json
$serviceAccountPath = "./rsc-service-account-rr.json"

# The report IDs for the custom reports that are created
# Protection Report - filters: Past 24 hours; Cluster type: Appliance, Virtual, Cloud
$reportIDProtectionReport = 54

# Object Compliance Report - Filters: Past 24 hours
$reportIDdailyComplianceReport = 53

# Protection Task Details Report - Filter: Past 24 hours, backup jobs
$reportIDdailyTaskReport = 52

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# Whether to list successful tasks or not in the report
$showSuccess = $true

# Current departmental mapping file
$mappingFile = "./Rubrik-Department_Mapping.csv"
$newMappingFile = "./Rubrik-Department_Mapping-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# Whether to export the html as a file along with file path
$exportHTML = $true
$htmlBaseName = "./Rubrik-Daily_Object_Report"
# $htmlOutput = "./Rubrik-Daily_Object_Report-$($date.ToString("yyyy-MM-dd_HHmm")).html"

# SMTP configuration if you want to send an email at the end of this script
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'
$emailSubject = "Rubrik Daily Compliance and Task Report - " + $date.ToString("yyyy-MM-dd HH:MM")

# Set to $true to send out email at the end of this script
$sendEmail = $false

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

# If user wants to create a new mapping file, then create it and exit
if ($createMapping -eq $true) {
  Write-Host "Updating mapping file" -foregroundcolor green
  Write-Host "Downloading the current Protection Report from Rubrik" -foregroundcolor green
  $protectionCSVLink = Get-ReportCSVLink -reportID $reportIDProtectionReport
  if ($PSVersionTable.PSVersion.Major -le 5) {
    $rubrikProtectionList = $(Invoke-WebRequest -Uri $protectionCSVLink).content | ConvertFrom-CSV
  } else {
    $rubrikProtectionList = $(Invoke-WebRequest -Uri $protectionCSVLink -SkipCertificateCheck).content | ConvertFrom-CSV
  }
  Write-Host "Downloaded the Protection Report CSV: $($rubrikProtectionList.count) objects" -foregroundcolor green
  # Check if an an existing mapping file exists, and if it does, pull it in
  # Merge the current Protection Report with the existing mapping file
  if (Test-Path -path $mappingFile) {
    Write-Host "Existing mapping file found, importing it: $mappingFile"
    $currentMapping = Import-CSV $mappingFile
    # Create a unique ID in the Protection Report
    foreach ($obj in $rubrikProtectionList) {
      $objID = $obj.'Cluster Name' + '+' + $obj.'Object Name' + '+' + $obj.'Location'
      Add-Member -InputObject $obj -MemberType NoteProperty -name 'ID' -value $objID -Force
    }
  } else {
    # If no existing mapping file exists, then create one in the format
    Write-Host "No existing mapping file exists" -forgroundcolor green
    Write-Host "Creating a new mapping file: $currentMapping" -forgroundcolor green
    # Sort the Protection Report
    $rubrikProtectionList = $rubrikProtectionList | Sort-Object -Property 'Cluster Name', 'Location', 'Object Name'
    $newRubrikProtectionList = @()
    # Loop through and re-order the columns to what we want
    foreach ($obj in $rubrikProtectionList) {
      $objectID = $obj.'Cluster Name' + '+' + $obj.'Object Name' + '+' + $obj.'Location'
      $newObj = [PSCustomObject] @{
        "Department" = ''
        "ClusterName" = $obj.'Cluster Name'
        "ObjectName" = $obj.'Object Name'
        "Location" = $obj.'Location'
        "ProtectionStatus" = $obj.'Protection status'
        "SLADomain" = $obj.'SLA Domain'
        "LastLocalSnapshot" = $obj.'Last local snapshot'
        "LastArchivalSnapshot" = $obj.'Last archival snapshot'
        "LastReplicationSnapshot" = $obj.'Last replication snapshot'
        "Organization" = $obj.'Organization'
        "ObjectID" = $objectID
      }
      $newRubrikProtectionList += $newObj
    } # FOREACH ($obj in $rubrikProtectionList)
    Write-Host "Exporting new mapping file: $mappingFile" -foregroundcolor green
    $newRubrikProtectionList | Export-CSV -NoTypeInformation -Path $mappingFile
  }
  # Exit script since we just want the mapping file updated / created
  # exit
}

# Import the current mapping file
Write-Host "Importing mapping file: $mappingFile" -foregroundcolor green
$currentMapping = Import-CSV $mappingFile
$currentMapping = $currentMapping | Sort-Object -property 'Department'
$departmentList = $currentMapping | Select-Object -expandProperty 'Department' -Unique
Write-Host "Found $($departmentList.count) departments" -foregroundcolor green

# Add a "NotFound" category if a report shows an object that is not on the mapping list
$departmentList += "NotFound"

# Download the current daily protection task report
$dailyTaskCSVLink = Get-ReportCSVLink -reportID $reportIDdailyTaskReport
if ($PSVersionTable.PSVersion.Major -le 5) {
  $rubrikTasks = $(Invoke-WebRequest -Uri $dailyTaskCSVLink).content | ConvertFrom-CSV
} else {
  $rubrikTasks = $(Invoke-WebRequest -Uri $dailyTaskCSVLink -SkipCertificateCheck).content | ConvertFrom-CSV
}
Write-Host "Downloaded the Daily Task Report data: $($rubrikTasks.count) tasks" -foregroundcolor green

# Download the current object compliance report
$complianceCSVLink = Get-ReportCSVLink -reportID $reportIDdailyComplianceReport
if ($PSVersionTable.PSVersion.Major -le 5) {
  $rubrikCompliance = $(Invoke-WebRequest -Uri $complianceCSVLink).content | ConvertFrom-CSV
} else {
  $rubrikCompliance = $(Invoke-WebRequest -Uri $complianceCSVLink -SkipCertificateCheck).content | ConvertFrom-CSV
}
Write-Host "Downloaded the Object Compliance data: $($rubrikCompliance.count) objects" -foregroundcolor green

# Get unique cluster names
$clusterList = $rubrikTasks | Select-Object 'Cluster Name' -unique -expandProperty 'Cluster Name'

# Create hash table to keep track of per-cluster task counts for each Department
$departmentCountHash = @{}
# Create hash table to keep track of per-cluster total task counts for each Department
$departmentClusterTotal = @{}
foreach ($department in $departmentList)
{
  # Create a hash table to keep the task status and compliance counts for each cluster
  $clusterCountHash = @{}
  foreach ($cluster in $clusterList)
  {
    $clusterObj = [PSCustomObject] @{
      "SuccessCount" = 0
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
  $departmentCountHash.add($($department),$clusterCountHash)
  # PSCustomObject to keep track of all counts for all clusters
  $clusterTotal = [PSCustomObject] @{
    "SuccessCount" = 0
    "CanceledCount" = 0
    "FailedCount" = 0
    "TotalCount" = 0
    "SuccessRate" = [float]0
    "InCompliance" = 0
    "OutCompliance" = 0
    "TotalCompliance" = 0
    "ComplianceRate" = [float]0
  }
  $departmentClusterTotal.add($($department),$clusterTotal)
}

$rubrikComplianceCount = $rubrikCompliance.count
Write-Host "Processing $rubrikComplianceCount objects in compliance report" -foregroundcolor green
$count = 1

# Process each object and calculate some values
foreach ($j in $rubrikCompliance)
{
  if (($count % 200) -eq 0) {
    Write-Host "Processing objects: $count of $rubrikComplianceCount"
  }
  $count += 1
  # Add Object ID based on 'Cluster'+'Name'+'Location'
  $objectID = $j.'Cluster Name' + '+' + $j.'Object Name' + '+' + $j.'Location'
  Add-Member -InputObject $j -MemberType NoteProperty -name 'ObjectID' -value $objectID -Force
  # Find object in mapping list
  $objectDepartmentMatch = $currentMapping | Where { $_.'ObjectID' -like $objectID }
  # If a match is found, set department value. Otherwise, set to 'NotFound'
  if ($objectDepartmentMatch.count -gt 0) {
    $objDepartment = $($objectDepartmentMatch[0].Department)
  } else {
    $objDepartment = 'NotFound'
  }
  Add-Member -InputObject $j -MemberType NoteProperty -name 'Department' -value $objDepartment -Force
}

$rubrikTasksCount = $rubrikTasks.count
Write-Host "Processing $rubrikTasksCount tasks" -foregroundcolor green
$count = 1

# Process each task and calculate some values
foreach ($i in $rubrikTasks)
{
  if (($count % 200) -eq 0) {
    Write-Host "Processing tasks: $count of $rubrikTasksCount"
  }
  $count += 1
  # Add Object ID based on 'Cluster'+'Name'+'Location'
  $objectID = $i.'Cluster Name' + '+' + $i.'Object Name' + '+' + $i.'Location'
  Add-Member -InputObject $i -MemberType NoteProperty -name 'ObjectID' -value $objectID -Force
  # Find object in mapping list
  $objectDepartmentMatch = $currentMapping | Where { $_.'ObjectID' -like $objectID }
  # If a match is found, set department value. Otherwise, set to 'NotFound'
  if ($objectDepartmentMatch.count -gt 0) {
    $objDepartment = $($objectDepartmentMatch[0].Department)
  } else {
    $objDepartment = 'NotFound'
  }
  Add-Member -InputObject $i -MemberType NoteProperty -name 'Department' -value $objDepartment -Force
  # Track the task status counts for each cluster
  $departmentCountHash[$objDepartment][$i.'Cluster Name'].'TotalCount' += 1
  if ($i.'Task Status' -match 'Success') {
    $departmentCountHash[$objDepartment][$i.'Cluster Name'].'SuccessCount' += 1
  } elseif ($i.'Task Status' -match 'Failed') {
    $departmentCountHash[$objDepartment][$i.'Cluster Name'].'FailedCount' += 1
  } elseif ($i.'TaskStatus' -match 'Canceled') {
    $departmentCountHash[$objDepartment][$i.'Cluster Name'].'CanceledCount' += 1
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

# Calculate the success rate per department, per cluster
# Loop $departmentCountHash, list of departments, with the cluster hash table underneath
foreach ($departmentStatus in $departmentCountHash.GetEnumerator())
{
  # Loop through the value which contains hash table of clusters for each department
  foreach ($clusterStatus in $departmentStatus.value.GetEnumerator())
  {
    try {
      $value = $($clusterStatus.Value)
      $value.SuccessRate = [math]::round($value.SuccessCount / ($value.SuccessCount + $value.FailedCount) * 100, 1)
    } catch { }
  }
}

# Create a table of tasks, with Failed tasks followed by Canceled, followed by Successul taks
# Within each grouping, sorted by "Duration" in descending order
Write-Host "Sorting tasks" -foreground green

$rubrikTasks = $rubrikTasks | Sort-Object -Property 'Department'

$rubrikTasksSorted = $rubrikTasks | Where { $_.'Task status' -match 'Fail' } |
  Sort-Object -property 'Duration' -Descending

$rubrikTasksSorted += $rubrikTasks | Where { $_.'Task status' -match 'Cancel' } |
  Sort-Object -property 'Duration' -Descending

$rubrikTasksSorted += $rubrikTasks | Where { $_.'Task status' -match 'Success' } |
  Sort-Object -property 'Duration' -Descending

# Calculate cluster totals for tasks
foreach ($dept in $departmentList)
{
  # Calculate total count of Tasks for each department
  $departmentClusterTotal[$dept].SuccessCount = $($rubrikTasks | Where { $_.'Task status' -match 'Success' -and
    $_.'Department' -like $dept }).count
  $departmentClusterTotal[$dept].CanceledCount = $($rubrikTasks | Where { $_.'Task status' -match 'Cancel' -and
    $_.'Department' -like $dept }).count
  $departmentClusterTotal[$dept].FailedCount = $($rubrikTasks | Where { $_.'Task status' -match 'Fail' -and
    $_.'Department' -like $dept }).count
  $departmentClusterTotal[$dept].TotalCount = $departmentClusterTotal[$dept].SuccessCount + $departmentClusterTotal[$dept].CanceledCount + $departmentClusterTotal[$dept].FailedCount
  if ($departmentClusterTotal[$dept].TotalCount -gt 0) {
    $departmentClusterTotal[$dept].SuccessRate = [math]::round($departmentClusterTotal[$dept].SuccessCount / $departmentClusterTotal[$dept].TotalCount * 100, 1)
  } else {
    $departmentClusterTotal[$dept].SuccessRate = 'N/A'
  }
  # Filter for objects that are In Compliance and separately, Out of Compliance
  $objectsInCompliance = $rubrikCompliance | Where { $_.'Compliance Status' -like 'In compliance' -and
    $_.'Department' -like $dept }
  $objectsOutCompliance = $rubrikCompliance | Where { $_.'Compliance Status' -like 'Out of compliance' -and
    $_.'Department' -like $dept }
  # Calculate cluster totals for compliance
  # $departmentClusterTotal[$dept].InCompliance = $objectsInCompliance.count
  # $departmentClusterTotal[$dept].OutCompliance = $objectsOutCompliance.count
  # $departmentClusterTotal[$dept].TotalCompliance = $departmentClusterTotal[$dept].InCompliance + $departmentClusterTotal[$dept].OutCompliance
  # if ($departmentClusterTotal[$dept].TotalCompliance -gt 0) {
  #   $departmentClusterTotal[$dept].ComplianceRate = [math]::round($departmentClusterTotal[$dept].InCompliance / $departmentClusterTotal[$dept].TotalCompliance * 100, 1)
  # } else {
  #   $departmentClusterTotal[$dept].ComplianceRate = 'N/A'
  # }
} # FOREACH ($dept in $departmentList)

$totalObjectsInCompliance = $rubrikCompliance | Where { $_.'Compliance Status' -match 'In Compliance' }
$totalObjectsOutCompliance = $rubrikCompliance | Where { $_.'Compliance Status' -match 'Out of compliance' }

# For each cluster, get the compliance summary details
foreach ($departmentStatus in $departmentCountHash.GetEnumerator())
{
  foreach ($clusterStatus in $departmentStatus.value.GetEnumerator())
  {
    $value = $($clusterStatus.Value)
    $objectsList = $totalObjectsInCompliance | Where { $_.'Cluster Name' -match $clusterStatus.Name -and $_.'Department' -match $($departmentStatus.name) }
    $value.InCompliance = $($totalObjectsInCompliance | Where { $_.'Cluster Name' -match $clusterStatus.Name -and
      $_.'Department' -like $($departmentStatus.name) }).count
    $value.OutCompliance = $($totalObjectsOutCompliance | Where { $_.'Cluster Name' -match $clusterStatus.Name -and
      $_.'Department' -like $($departmentStatus.name) }).count
    $value.TotalCompliance = $value.InCompliance + $value.OutCompliance
    # Add to total count
    $departmentClusterTotal[$($departmentStatus.name)].inCompliance += $value.InCompliance
    $departmentClusterTotal[$($departmentStatus.name)].OutCompliance += $value.OutCompliance
    $departmentClusterTotal[$($departmentStatus.name)].TotalCompliance += $value.TotalCompliance
    # If there are no objects that are being protected, then compliance rate is N/A
    try {
      $value.ComplianceRate = [math]::round($value.InCompliance / $value.TotalCompliance * 100, 1)
    }
    catch {
      if ($value.TotalCompliance -eq 0) {
        $value.ComplianceRate = 'N/A'
      }
    }
  }
}

# Process each object out of compliance
foreach ($j in $totalObjectsOutCompliance)
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

$totalObjectsOutCompliance = $totalObjectsOutCompliance | Sort-Object -Property 'Local Days Behind' -Descending

Write-Host "Creating HTML tables" -foregroundcolor green

# Loop through each department to create their own HTML
foreach ($dept in $departmentList)
{

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
  <b>Rubrik Daily Object Report for: $dept</b>
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
      <th colspan="5">Daily Compliance Summary for Department: $dept</th>
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


foreach ($clusterStatus in $departmentCountHash[$dept].GetEnumerator() | Sort-Object -Property 'name')
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
    <td>$($departmentClusterTotal[$dept].TotalCompliance)</td>
    <td>$($departmentClusterTotal[$dept].InCompliance)</td>
    <td>$($departmentClusterTotal[$dept].OutCompliance)</td>
    <td>$($departmentClusterTotal[$dept].ComplianceRate)</td>
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
      <th colspan="6">Daily Backup Task Summary for: $dept</th>
    </tr>
    <tr>
      <th>Cluster</th>
      <th>Total</th>
      <th>Success</th>
      <th>Failed</th>
      <th>Canceled</th>
      <th>Success Rate</th>
    </tr>
"@

$HTMLTaskSummaryTableEnd = @"
  </table>
  <br>
"@

foreach ($clusterStatus in $departmentCountHash[$dept].GetEnumerator() | Sort-Object -Property 'name' )
{
  $value = $($clusterStatus.Value)
  $HTMLTaskSummaryTableRow = @"
  <tr>
    <td style=text-align:right>$($clusterStatus.Name)</td>
    <td style=color:$HTMLRubrikColor><b>$($value.'TotalCount')</b></td>
    <td style=color:black;background:$HTMLGreenColor>$($value.'SuccessCount')</td>
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
    <td>$($departmentClusterTotal[$dept].TotalCount)</td>
    <td>$($departmentClusterTotal[$dept].SuccessCount)</td>
    <td>$($departmentClusterTotal[$dept].FailedCount)</td>
    <td>$($departmentClusterTotal[$dept].CanceledCount)</td>
    <td>$($departmentClusterTotal[$dept].SuccessRate)</td>
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
      <th colspan="6">Daily Object Out of Compliance Report for: $dept</th>
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

$deptObjectsOutCompliance = $totalObjectsOutCompliance | Where { $_.'Department' -like $dept }

# Loop through each out of compliance object and create a row
foreach ($obj in $deptObjectsOutCompliance)
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
      <th colspan="7">Daily Object Task Report for: $dept</th>
    </tr>
    <tr>
      <th>Name</th>
      <th>Host</th>
      <th>Cluster</th>
      <th>Status</th>
      <th>Data Transferred (GB)</th>
      <th>Started</th>
      <th>Duration</th>
    </tr>
"@

$HTMLTaskTableEnd = @"
  </table>
  <br>
"@

$deptRubrikTasksSorted = $rubrikTasksSorted | Where { $_.'Department' -like $dept }

# Loop through each report summary info and create a row
foreach ($task in $deptRubrikTasksSorted)
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
  $htmlOutput = $htmlBaseName + "-$dept-$($date.ToString("yyyy-MM-dd_HHmm")).html"
  $HTMLReport | Out-File -FilePath $htmlOutput
  Write-Host "`nHTML report output to: $htmlOutput" -foregroundcolor green
}

# Send an email with CSV attachment
if ($sendEmail) {
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $HTMLReport -SmtpServer $SMTPServer -Port $SMTPPort
}

}
