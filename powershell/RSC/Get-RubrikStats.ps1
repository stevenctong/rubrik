# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will gather stats on Rubrik and output it to a CSV.

.DESCRIPTION
This script will gather stats on Rubrik and output it to a CSV.

The script requires communication to RSC via outbound HTTPS (TCP 443).

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 10/1/24

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath


.EXAMPLE
./Get-RubrikStats.ps1
Runs the script to gather Rubrik stats and output to  CSV.
#>

### Variables section - please fill out as needed

# param (
#   [CmdletBinding()]
#
#   # List of clusters to register RBS on
#   [Parameter(Mandatory=$false)]
#   [array]$clusters = @('vault-r-melbourne', 'vault-r-madison')
# )

# List of Cluster IDs to gather snapshot stats for
$clusterID = '2988c49d-4040-4982-a77f-63c3c6c24c14'
$clusterName = 'HDC2-RBRK-PRD'

# The report IDs for the Compliance Report the script uses
# Compliance report should be filtered to Last 24 hours for the Cluster above
$reportIDdailyComplianceReport = 118

# File location of the RSC service account json
$serviceAccountPath = "./rsc-service-account-quorum.json"

$date = Get-Date
$dateString = $date.ToString("yyyy-MM-ddTHH:mm:ss")

# CSV file info
$csvOutput = "./rubrik_daily_stats.csv"

# SMTP configuration if you want to send an email at the end of this script
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'
$emailSubject = "Rubrik Cluster Stats - " + $date.ToString("yyyy-MM-dd HH:MM")

# Set to $true to send out email at the end of this script
$sendEmail = $false

# Define the capacity metric conversions
$GB = 1000000000
$GiB = 1073741824
$TB = 1000000000000
$TiB = 1099511627776

### End Variables section

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

Write-Debug -Message "Determing if the Service Account file contains all required variables."
$missingServiceAccount = @()
if ($serviceAccountFile.client_id -eq $null -or $serviceAccountFile.client_secret -eq $null -or
      $serviceAccountFile.access_token_uri -eq $null) {
  throw "The Service Account JSON is missing one or more parameters."
}

$headers = @{
  'Content-Type' = 'application/json'
  'Accept' = 'application/json'
}

$payload = @{
  grant_type = "client_credentials"
  client_id = $serviceAccountFile.client_id
  client_secret = $serviceAccountFile.client_secret
}

Write-Verbose -Message "Connecting to the RSC GraphQL API using the Service Account JSON file."
$response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers

# Rubrik GraphQL API URLs
$rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")
$endpoint = $rubrikURL + "/api/graphql"
$logoutUrl = $rubrikURL + "/api/session"

$headers = @{
  'Content-Type'  = 'application/json'
  'Accept' = 'application/json'
  'Authorization' = $('Bearer ' + $response.access_token)
}

Write-Host "Successfully connected to: $rubrikURL"
###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# Get cluster stats
Function Get-ClusterStats {
  param (
    [CmdletBinding()]
    # Cluster ID
    [Parameter(Mandatory=$false)]
    [string]$clusterID = ''
  )
  $variables = @{
    "id" = $clusterID
  }
  $query = "query ClusterMetricQuery(`$id: UUID!) {
    cluster(clusterUuid: `$id) {
      id
      metric {
        ingestedSnapshotStorage
        usedCapacity
        liveMountCapacity
        miscellaneousCapacity
        physicalSnapshotStorage
        snapshotCapacity
        totalCapacity
        availableCapacity
        pendingSnapshotCapacity
        cdpCapacity
        physicalArchivalStorage
        averageDailyGrowth
        lastUpdateTime
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
  return $result.data.cluster.metric
}  ### Function Get-ClusterStats

# Get RCV stats
Function Get-RCVStats {
  $query = "query RcsEntitlementQuery {
    rcsEntitlement: rcvAccountEntitlement {
      archiveEntitlement {
        capacity
        __typename
      }
      backupEntitlement {
        capacity
        __typename
      }
      entitlements {
        entitlement {
          bundle
          capacity
          tier
          redundancy
          __typename
        }
        usedCapacity
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
  return $result.data.rcsEntitlement
}  ### Function Get-RCVStats


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
  $query = "query DownloadBarQuery {
    getUserDownloads {
      id
      name
      status
      progress
      identifier
      createTime
      completeTime
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
      }
    }
  }"
  $payload = @{
    "query" = $query
  }
  $response = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $response.data.allUserFiles.downloads
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
    [int]$reportID,
    # Rubrik URL
    [Parameter(Mandatory=$true)]
    [string]$rubrikURL
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
  # This grabs the status of all recent downloads
  $downloadStatus = Get-DownloadStatus
  # Find the matching report that is in progress and that is the one we want to monitor
  $jobToMonitor = $downloadStatus | Where { $_.filename -match "$reportName*" -and ($_.state -match 'PENDING' -or $_.state -match 'IN_PROGRESS') }
  Write-Host "Waiting for CSV to be ready, current status: $($jobToMonitor.state)"
  do {
    Start-Sleep -seconds 10
    $downloadStatus = Get-DownloadStatus | Where { $_.externalId -eq $jobToMonitor.externalId }
    Write-Host "Waiting for CSV to be ready, current status: $($downloadStatus.state)"
  } while ( $downloadStatus.state -notmatch 'READY' )
  # $downloadURL = Get-CSVDownloadLink -downloadID $responseCreateCSV.id
  $fileURL = $rubrikURL + "/file-downloads/" + $($jobToMonitor.externalId)
  return $fileURL
}  ### Function Get-ReportCSVLink

###### FUNCTIONS - END ######


# Download the current daily protection task report
$dailyComplianceCSVLink = Get-ReportCSVLink -reportID $reportIDdailyComplianceReport -rubrikURL $rubrikURL
if ($PSVersionTable.PSVersion.Major -le 5) {
  $rubrikCompliance = $(Invoke-WebRequest -Uri $dailyComplianceCSVLink -headers $Headers).content | ConvertFrom-CSV
} else {
  $rubrikCompliance = $(Invoke-WebRequest -Uri $dailyComplianceCSVLink -SkipCertificateCheck -headers $Headers).content | ConvertFrom-CSV
}
Write-Host "Downloaded the Daily Task Compliance CSV: $($rubrikCompliance.count) tasks" -foregroundcolor green

$complianceByCluster = $rubrikCompliance | Where { $_.'Cluster' -eq $clusterName }

$localSnapshots = 0
$missedSnapshots = 0

foreach ($obj in $complianceByCluster) {
  try {
    $localSnapshots += [int]$obj.'Local Snapshots'
    $missedSnapshots += [int]$obj.'Missed Snapshots'
  } catch {
    Write-Error "Error totaling snapshots for: $($obj.Object)"
  }
}

$clusterStats = Get-ClusterStats -clusterID $clusterID
$rcvStats = Get-RCVStats

$clusterUsedCapacityTB = [math]::Round($clusterStats.usedCapacity / $TB, 2)
$clusterFreeCapacityTB = [math]::Round($clusterStats.availableCapacity / $TB, 2)
$clusterTotalCapacityTB = [math]::Round($clusterStats.totalCapacity / $TB, 2)
$clusterPctUsed = [math]::Round($clusterUsedCapacityTB / $clusterTotalCapacityTB * 100, 2)

foreach ($tier in $rcvstats.entitlements) {
  if ($tier.entitlement.tier -eq 'BACKUP') {
    $rcvBackupTotalCapacityTB = $tier.entitlement.capacity
    $rcvBackupUsedCapacityTB = [math]::Round($tier.usedCapacity, 2)
    $rcvBackupFreeCapacity = $rcvBackupTotalCapacityTB - $rcvBackupUsedCapacityTB
    $rcvBackupPctUsed = [math]::Round($rcvBackupUsedCapacityTB / $rcvBackupTotalCapacityTB * 100, 2)
  }
  if ($tier.entitlement.tier -eq 'ARCHIVE') {
    $rcvArchiveTotalCapacityTB = $tier.entitlement.capacity
    $rcvArchiveUsedCapacityTB = [math]::Round($tier.usedCapacity, 2)
    $rcvArchiveFreeCapacity = $rcvArchiveTotalCapacityTB - $rcvArchiveUsedCapacityTB
    $rcvArchivePctUsed = [math]::Round($rcvArchiveUsedCapacityTB / $rcvArchiveTotalCapacityTB * 100, 2)
  }
}

$statsTable = [PSCustomObject] @{
  "Date" = $dateString
  "Cluster" = $clusterName
  "Local Snapshots" = $localSnapshots
  "Missed Snapshots" = $missedSnapshots
  "Cluster Used TB" = $clusterUsedCapacityTB
  "Cluster Free TB" = $clusterFreeCapacityTB
  "Cluster Total TB" = $clusterTotalCapacityTB
  "Cluster Used Pct" = $clusterPctUsed
  "RCV Backup Tier Used TB" = $rcvBackupUsedCapacityTB
  "RCV Backup Tier Free TB" = $rcvBackupFreeCapacity
  "RCV Backup Tier Total TB" = $rcvBackupTotalCapacityTB
  "RCV Backup Tier Used Pct" = $rcvBackupPctUsed
  "RCV Archive Tier Used TB" = $rcvArchiveUsedCapacityTB
  "RCV Archive Tier Free TB" = $rcvArchiveFreeCapacity
  "RCV Archive Tier Total TB" = $rcvArchiveTotalCapacityTB
  "RCV Archive Tier Used Pct" = $rcvArchivePctUsed
}

$statsTable | Format-Table

# Log out of RSC session
# $closeStatus = $(Invoke-RestMethod -Method DELETE -Uri $logoutUrl -Headers $headers -ContentType "application/json")

$statsTable | Export-CSV -Path $csvOutput -NoTypeInformation -Append
Write-Host "CSV output to: $csvOutput" -foregroundcolor green


# Send an email with CSV attachment
if ($sendEmail) {
  $htmlReport = ""
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $HTMLReport -SmtpServer $SMTPServer -Attachments $csvOutput
}
