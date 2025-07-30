# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will get the Task Monitoring CSV.

.DESCRIPTION
This script will get the Task Monitoring CSV.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 7/12/25
Updated 7/29/25

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a custom role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath

.EXAMPLE
./Get-Tasks-CSV.ps1
Runs the script with default arguments.

#>

###### VARIABLES - BEGIN ######

param (
  [CmdletBinding()]
  # Filter reports by last x hours based on End Time, up to 24
  [Parameter(Mandatory=$false)]
  [int]$lastHours = 1,
  # Task type filters, comma seprated string
  [Parameter(Mandatory=$false)]
  [string]$taskType = 'Backup, Archival',
  # Object type filters, comma separated string
  [Parameter(Mandatory=$false)]
  [string]$objectType = '',
  # Cluster filter by cluster name
  [Parameter(Mandatory=$false)]
  [string]$cluster = '',
  # Time zone to report in. Could be 'America/New_York', 'America/Chicago',
  # 'America/Denver', or 'America/Los_Angeles'
  [Parameter(Mandatory=$false)]
  $timeZone = 'America/Chicago',
  # Whether to get Completed Tasks
  [Parameter(Mandatory=$false)]
  [bool]$statusCompleted = $true,
  # Whether to get Failed Tasks
  [Parameter(Mandatory=$false)]
  [bool]$statusFailed = $true,
  # Whether to get Canceled Tasks
  [Parameter(Mandatory=$false)]
  [bool]$statusCanceled = $true,
  # Whether to get In Progress Tasks, you should gather In Progress separately
  [Parameter(Mandatory=$false)]
  [bool]$statusInProgress = $false
)
### VARIABLES - BEGIN ###

# File location of the RSC service account json
$serviceAccountPath = "./rsc-service-account-rr.json"

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# CSV file info
$csvOutput = "./rubrik-task-details-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# CSV file info
$htmlOutput = "./rubrik-task-details-$($date.ToString("yyyy-MM-dd_HHmm")).html"

# SMTP configuration if you want to send an email at the end of this script
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'
$emailSubject = "Rubrik - Task Monitoring - " + $date.ToString("yyyy-MM-dd HH:MM")

# Set to $true to send out email at the end of this script
$sendEmail = $false

###### VARIABLES - END ######

if ($psversiontable.psversion -lt 7) {
  Write-Error "PowerShell version is: $($psversiontable.psversion)"
  Write-Error "Please use PowerShell version 7+"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls12, [Net.SecurityProtocolType]::Ssl3
  [Net.ServicePointManager]::SecurityProtocol = "Tls, Tls11, Tls12, Ssl3"
}

###### RUBRIK AUTHENTICATION - BEGIN ######
Write-Information -Message "Info: Attempting to read the Service Account file located at $serviceAccountPath"
try {
  $serviceAccountFile = Get-Content -Path "$serviceAccountPath" -ErrorAction Stop | ConvertFrom-Json
} catch {
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

# Trigger generating a CSV for Task Monitoring dashboard
Function Generate-TaskCSV {
  param (
    [CmdletBinding()]
    # Task Monitoring CSV type: MONITORING_IN_PROGRESS, MONITORING_COMPLETED,
    # MONITORING_FAILED, MONITORING_CANCELED
    [Parameter(Mandatory=$true)]
    [string]$taskStatus = '',
    # Time zone to report in. Could be 'America/New_York', 'America/Chicago',
    # 'America/Denver', or 'America/Los_Angeles'
    [Parameter(Mandatory=$true)]
    [string]$timeZone = ''
  )
  if ($taskStatus -eq 'MONITORING_IN_PROGRESS' -or $taskStatus -eq 'MONITORING_COMPLETED') {
    $columns = @(
      "job_status"
      "job_type"
      "cluster_name"
      "location_name"
      "sla_domain_name"
      "object_type"
      "object_name"
      "event_series_id"
      "start_time"
      "duration"
      "estimated_time_remaining"
      "data_transferred"
      "data_remaining"
      "throughput"
      "object_logical_size"
      "retry_count"
      "node_id"
      "source_cluster_name"
      "org_name"
      "progress"
    )
  }
  if ($taskStatus -eq 'MONITORING_FAILED') {
    $columns = @(
      "job_type"
      "cluster_name"
      "location_name"
      "sla_domain_name"
      "object_type"
      "object_name"
      "event_series_id"
      "error_code"
      "error_message"
      "error_reason"
      "error_remedy"
      "start_time"
      "end_time"
      "duration"
      "last_successful_job_time"
      "next_job_time"
      "object_logical_size"
      "node_id"
      "source_cluster_name"
      "org_name"
    )
  }
  if ($taskStatus -eq 'MONITORING_CANCELED') {
    $columns = @(
      "job_type"
      "cluster_name"
      "location_name"
      "sla_domain_name"
      "object_type"
      "object_name"
      "event_series_id"
      "start_time"
      "end_time"
      "duration"
      "last_successful_job_time"
      "object_logical_size"
      "node_id"
      "source_cluster_name"
      "org_name"
    )
  }
  $variables = @{
    "input" = @{
      "fileType" = "CSV"
      "reportId" = 0
      "timezone" = $timeZone
      "config" = @{
        "ngAlphaConfig" = @{
          "name" = $taskStatus
          "dataViewType" = $taskStatus
          "columns" = $columns
          "groupBy" = @{
            "groupById" = ""
            "aggregations" = @()
          }
          "aggregations" = @()
          "filters" = @()
          "sortBy" = ""
          "sortOrder" = "DESC"
        }
        "reportVersion" = "NG_REPORT_ALPHA"
      }
    }
  }
  $query = 'mutation NgReportDownloadFileMutation($input: DownloadReportFileInput!) {
    downloadFile(input: $input) {
      jobId
      referenceId
      __typename
    }
  }'
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $response = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers
  return $response.data.downloadfile
} ### Function Generate-TaskCSV

# Get the CSV download status
Function Get-DownloadStatus {
  $query = 'query DownloadBarQuery {
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
}'
  $payload = @{
    "query" = $query
  }
  $response = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $response.data.allUserFiles.downloads
} ### Get-DownloadStatus

# Trigger downloading a CSV for a report and return the download link
Function Get-TaskCSVLink {
  param (
    [CmdletBinding()]
    # Task Monitoring CSV type: MONITORING_IN_PROGRESS, MONITORING_COMPLETED,
    # MONITORING_FAILED, MONITORING_CANCELED
    [Parameter(Mandatory=$true)]
    [string]$taskStatus = ''
  )
  Write-Host "Generating CSV for Task Monitoring for: $taskStatus" -foregroundcolor green
  # Trigger creation of Task Monitoring CSV
  $responseCreateCSV = Generate-TaskCSV -taskStatus $taskStatus -timeZone $timeZone
  # Get all the recent file download requests
  $downloadStatus = Get-DownloadStatus
  # Filter by file downloads matching the report name we want
  $matchingReports = $downloadStatus | Where-Object { $_.filename -match $taskStatus }
  # File download job we want should be last one in the array (most recent request)
  $jobToMonitor = $matchingReports[-1]
  # Submitted job will likely be in a PENDING state - grab job ID
  # $jobToMonitor = $downloadStatus | Where-Object { $_.filename -match $reportName -and ($_.state -match 'PENDING' -or $_.status -match 'IN_PROGRESS') }
  Write-Host "Waiting for CSV to be ready, current status: $($jobToMonitor.state)"
  do {
    Start-Sleep -seconds 10
    $downloadStatus = Get-DownloadStatus | Where { $_.externalId -eq $jobToMonitor.externalId }
    Write-Host "Waiting for CSV to be ready, current status: $($downloadStatus.state)"
  } while ( $downloadStatus.state -notmatch 'READY' -and $downloadStatus.state -notmatch 'FAILED' )
  if ($downloadStatus.state -eq 'FAILED') {
    Write-Error "Failed to download CSV for: $taskStatus"
    return $null
  } else {
    $downloadURL = $rubrikURL + '/file-downloads/' + $jobToMonitor.externalId
    return $downloadURL
  }
}  ### Function Get-ReportCSVLink

# Function to generate an HTML table with conditional row coloring
function ConvertTo-HTMLTable {
    param (
        [Parameter(Mandatory)]
        [array]$Data, # The array of objects to convert
        [string]$Title = "" # Table title (optional)
    )
    # Start building the HTML table
    $html = @()
    if ($Title) {
        $html += "<h2>$Title</h2>"
    }
    $html += '<table border="1" cellspacing="0" cellpadding="5" style="border-collapse: collapse; width: 100%;">'
    # Generate the table header from the property names
    $html += '<thead><tr>'
    foreach ($property in $Data[0].PsObject.Properties.Name) {
        $html += "<th>$property</th>"
    }
    $html += '</tr></thead>'
    # Generate the table rows
    $html += '<tbody>'
    foreach ($row in $Data) {
        # Determine the row style based on the Status property
        $rowStyle = "background-color: white;" # Default style
        if ($row.'Task Status' -like 'Success*') { $rowStyle = "background-color: #D4EDDA; color: #155724;" } # Green (Success)
        elseif ($row.'Task Status' -like 'Fail*')   { $rowStyle = "background-color: #F8D7DA; color: #721C24;" } # Red (Fail)
        elseif ($row.'Task Status' -like 'Cancel*') { $rowStyle = "background-color: #FFF3CD; color: #856404;" } # Yellow (Cancel)
        # Build the row with the style
        $html += "<tr style='$rowStyle'>"
        foreach ($property in $row.PsObject.Properties.Name) {
            $html += "<td>$($row.$property)</td>"
        }
        $html += '</tr>'
    }
    $html += '</tbody>'
    $html += '</table>'
    # Return the HTML as a string
    return $html -join "`n"
} ### ConvertTo-HTMLTable


###### FUNCTIONS - END ######

$allTasks = @()

if ($statusInProgress -eq $true) {
  $csvInProgress = Get-TaskCSVLink -TaskStatus "MONITORING_IN_PROGRESS"
  $tasksInProgress = $(Invoke-WebRequest -Uri $csvInProgress -Headers $headers -SkipCertificateCheck).content | ConvertFrom-CSV
  $tasksInProgress | ForEach-Object {
      $_ | Add-Member -NotePropertyName 'Task Status' -NotePropertyValue 'In Progress'
  }
  $allTasks += $tasksInProgress
}

if ($statusCompleted -eq $true) {
  $csvCompleted = Get-TaskCSVLink -TaskStatus "MONITORING_COMPLETED"
  $tasksCompleted = $(Invoke-WebRequest -Uri $csvCompleted -Headers $headers -SkipCertificateCheck).content | ConvertFrom-CSV
  $tasksCompleted | ForEach-Object {
      $_ | Add-Member -NotePropertyName 'Task Status' -NotePropertyValue 'Successful'
  }
  $allTasks += $tasksCompleted
}

if ($statusFailed -eq $true) {
  $csvFailed = Get-TaskCSVLink -TaskStatus "MONITORING_FAILED"
  $tasksFailed = $(Invoke-WebRequest -Uri $csvFailed -Headers $headers -SkipCertificateCheck).content | ConvertFrom-CSV
  $tasksFailed | ForEach-Object {
      $_ | Add-Member -NotePropertyName 'Task Status' -NotePropertyValue 'Failed'
  }
  $allTasks += $tasksFailed
}

if ($statusCanceled -eq $true) {
  $csvCanceled = Get-TaskCSVLink -TaskStatus "MONITORING_CANCELED"
  $tasksCanceled = $(Invoke-WebRequest -Uri $csvCanceled -Headers $headers -SkipCertificateCheck).content | ConvertFrom-CSV
  $tasksCanceled | ForEach-Object {
      $_ | Add-Member -NotePropertyName 'Task Status' -NotePropertyValue 'Canceled'
  }
  $allTasks += $tasksCanceled
}

$filteredAllTasks = $allTasks

# Filter the tasks by Cluster
if ($cluster -ne '') {
  Write-Host ""
  Write-Host "Filtering tasks by cluster: $cluster"
  $filteredAllTasks = $filteredAllTasks | Where { $_.'Cluster Name' -eq $cluster }
  Write-Host "Found a total of $($filteredAllTasks.count) tasks"
}

# Filter the tasks by Task Type
if ($taskType -ne '') {
  [array]$taskTypeArray = $taskType -split ',' | ForEach-Object { $_.Trim() }
  Write-Host ""
  Write-Host "Filtering tasks by task types: $taskType"
  $filteredAllTasks = $filteredAllTasks | Where { $_.'Task Type' -in $taskTypeArray }
  Write-Host "Found a total of $($filteredAllTasks.count) tasks"
}

# Filter the tasks by Object Type
if ($objectType -ne '') {
  [array]$objectTypeArray = $objectType -split ',' | ForEach-Object { $_.Trim() }
  Write-Host ""
  Write-Host "Filtering tasks by object types: $objectType"
  $filteredAllTasks = $filteredAllTasks | Where { $_.'Object Type' -in $objectTypeArray }
  Write-Host "Found a total of $($filteredAllTasks.count) tasks"
}

$sortedTasks = $filteredAllTasks | Sort-Object {
    [datetime]::ParseExact($_.'End Time','MM/dd/yyyy hh:mm:ss tt',$null)
} -Descending

Write-Host ""
Write-Host "Filtering tasks by last $lastHours hours in time zone $timeZone"

# Get the current time in the Task Monitoring time zone we are using
$timeZoneInfo = [System.TimeZoneInfo]::FindSystemTimeZoneById($timezone)
$nowInTimeZone = [System.TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $timeZoneInfo)

# Get the time for the last x hours
$cutoffTime = $nowInTimeZone.AddHours(-($lastHours))

# Filter tasks whose 'End Time' is within the last x hours
$recentTasks = $sortedTasks | Where-Object {
    # Parse task End Time to datetime
    $taskEndTime = [datetime]::ParseExact($_.'End Time', 'MM/dd/yyyy hh:mm:ss tt', $null)
    # If the parsed task End Time doesn't specify a time zone, it is treated as being in the specified timezone.
    # Check if task end time is between cutoff and now
    ($taskEndTime -ge $cutoffTime)
}
Write-Host "Found a total of $($recentTasks.count) tasks from last $lastHours hours"
Write-Host ""

# Holds the list of formatted tasks
$taskList = @()

foreach ($t in $recentTasks) {
  # Convert $t.duration from seconds to mm:ss
  $minutes = [math]::Floor($t.duration / 60)    # Get the whole minutes
  $seconds = $t.duration % 60                   # Get the remaining seconds
  $durationMMSS = "{0:00}:{1:00}" -f $minutes, $seconds
  # Convert Bytes to GB
  $objLogicalSizeGB = [math]::Round($t.'Object Logical Size' / 1000000000, 2)
  $dataTransGB = [math]::Round($t.'Data Transferred' / 1000000000, 2)
  # Calculate throughput in GB/s
  $throughputMBpS = [math]::Round($dataTransGB / $t.duration * 1000, 2)
  # Populate Status since it doesn't populate for Failed tasks
  if ($t.status -eq $null) {
    $status = $t.'Task Status'
  } else {
    $status = $t.'Status'
  }
  # Create the task detail item with the proper order
  $taskDetail = [PSCustomObject]@{
    "Object Name" = $t.'Object Name'
    "SLA Domain" = $t.'SLA Domain'
    "Object Type" = $t.'Object Type'
    "Task Type" = $t.'Task Type'
    "Status" = $status
    "Task Status" = $t.'Task Status'
    "Start Time" = $t.'Start Time'
    "End Time" = $t.'End Time'
    "Duration MM:SS" = $durationMMSS
    "Object Logical Size GB" = $objLogicalSizeGB
    "Data Transferred GB" = $dataTransGB
    "Throughput MBpS" = $throughputMBpS
    "Source Cluster" = $t.'Source Cluster'    # Might not need
    "Cluster Name" = $t.'Cluster Name'
    "Location" = $t.'Location'
    "Error Code" = $t.'Error Code'
    "Error Message" = $t.'Error Message'
    "Error Reason" = $t.'Error Reason'
    "Error Remedy" = $t.'Error Remedy'
  }
  $taskList += $taskDetail
}

Write-Host "Exporting to CSV: $csvOutput"
$taskList | Export-CSV -Path $csvOutput -NoTypeInformation

# Create the HTML table from the $taskList table
$htmlTable = ConvertTo-HTMLTable -Data $taskList -Title "Rubrik Tasks - Last $lastHours hours"
# Create a basic HTML page with the table
$fullHTML = @"
<!DOCTYPE html>
<html>
<head>
    <title>Rubrik Tasks - Last $lastHours hours</title>
</head>
<body>
    $htmlTable
</body>
</html>
"@

Write-Host "Exporting to HTML: $htmlOutput"
$fullHTML | Out-File -FilePath $htmlOutput -Encoding utf8

# Send an email with CSV attachment
if ($sendEmail) {
  Write-Host "Sending email to: $emailTo with subject: $emailSubject"
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $fullHTML -SmtpServer $SMTPServer -Port $SMTPPort -Attachments $csvOutput
}
