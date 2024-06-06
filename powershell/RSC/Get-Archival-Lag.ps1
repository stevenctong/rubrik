# https://www.rubrik.com/api
<#
.SYNOPSIS
This script calculates archival lag.

.DESCRIPTION
This script calculates archival lag.

You will need to create two reports in RSC and fill out the variables section:

1. RSC Report: Compliance Report
2. RSC Report: Object Capacity Report

The script will pull the CSV reports from RSC and then process them to calculate
archival lag.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 3/29/24
Updated: 6/6/24 - Updated fields to support Report NG framework,
checking objects with zero uploaded snapshots without checking archival compliance

Requires PowerShell 7

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only reporting role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath

If you want the report to be emails, fill out the SMTP information and set
the variable $sendEmail to $true.

.EXAMPLE
./Get-Replication-Lag.ps1
Runs the script to calculate replication lag
#>

### Variables section - please fill out as needed

# File location of the RSC service account json
$serviceAccountPath = "./rsc-service-account-rr.json"

# Report ID for the RSC Compliance Report
$reportIDCompliance = 53

# Report ID for the RSC Object Capacity Report
$reportIDObjectCapacity = 123

$date = Get-Date
$utcDate = $date.ToUniversalTime()

# Path to export CSV to
$csvOutputObjectList = "./Rubrik-Archival_Lag-$($date.ToString("yyyy-MM-dd_HHmm")).csv"
$csvOutputSummary = './Rubrik-Archival_Lag_Summary.csv'

# If you don't want to use RSC but use an exported CSV directly, set $useRSC to $false
# And define where the exported report CSVs are here
$useRSC = $true
$CSVCompliance = './ReportingServer_Compliance_2024-06-05_74eb772238ed4158e8c82feb6986a792.csv'
$CSVObjCapacity = './ReportingServer_ObjectCapacity_2024-06-05_c643742255e9934e5c5f4f7834285065.csv'

# Parallel threads for processing the reports
$throttleLimit = 16

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
  client_id = $serviceAccountFile.client_id
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
  # Skipping this for now, the endpoint is not returning all report types
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
  # Temporary - removed name match
  $jobToMonitor = $downloadStatus | Where { ($_.status -match 'PENDING' -or $_.status -match 'IN_PROGRESS') }
  # $jobToMonitor = $downloadStatus | Where { $_.name -match $reportName -and ($_.status -match 'PENDING' -or $_.status -match 'IN_PROGRESS') }
  Write-Host "Waiting for CSV to be ready, current status: $($jobToMonitor.status)"
  do {
    Start-Sleep -seconds 10
    $downloadStatus = Get-DownloadStatus | Where { $_.id -eq $jobToMonitor.id }
    Write-Host "Waiting for CSV to be ready, current status: $($jobToMonitor.status)"
  } while ( $downloadStatus.status -notmatch 'COMPLETED' )
  $downloadURL = Get-CSVDownloadLink -downloadID $jobToMonitor.id
  return $downloadURL
}  ### Function Get-ReportCSVLink

###### FUNCTIONS - END ######


if ($useRSC -eq $true)
{
  # Download the current Compliance Report from RSC
  $complianceCSVLink = Get-ReportCSVLink -reportID $reportIDCompliance
  if ($PSVersionTable.PSVersion.Major -le 5) {
    $reportCompliance = $(Invoke-WebRequest -Uri $complianceCSVLink).content | ConvertFrom-CSV
    if ($saveCSV) {
      $reportCompliance | Export-CSV -path $csvReportCompliance -NoTypeInformation
    }
  } else {
    $reportCompliance = $(Invoke-WebRequest -Uri $complianceCSVLink -SkipCertificateCheck).content | ConvertFrom-CSV
    if ($saveCSV) {
      $reportCompliance | Export-CSV -path $csvReportCompliance -NoTypeInformation
    }
  }
  Write-Host "Downloaded the RSC compliance report: $($reportCompliance.count) objects" -foregroundcolor green
  # Download the current Object Capacity report from RSC
  $dailyTaskCSVLink = Get-ReportCSVLink -reportID $reportIDObjectCapacity
  if ($PSVersionTable.PSVersion.Major -le 5) {
    $reportObjCapacity = $(Invoke-WebRequest -Uri $dailyTaskCSVLink).content | ConvertFrom-CSV
    if ($saveCSV) {
      $reportObjCapacity | Export-CSV -path $csvReportTasks -NoTypeInformation
    }
  } else {
    $reportObjCapacity = $(Invoke-WebRequest -Uri $dailyTaskCSVLink -SkipCertificateCheck).content | ConvertFrom-CSV
    if ($saveCSV) {
      $reportObjCapacity | Export-CSV -path $csvReportTasks -NoTypeInformation
    }
  }
  Write-Host "Downloaded the RSC object capacity report: $($reportObjCapacity.count) tasks" -foregroundcolor green
} else {
  # If not use RSC, then use the specified CSV files by path
  $reportCompliance = Import-CSV -Path $CSVCompliance
  $reportObjCapacity = Import-CSV -Path $CSVObjCapacity
}

# Get all objects in the production SLA - those that don't have 'Non' or 'Test' in the name
$prodInCompReport = $reportCompliance | Where { $_.'SLA Domain' -notmatch 'Non' -and $_.'SLA Domain' -notmatch 'test' } |
  Sort-Object -Property 'SLA Domain'

# Get the objects that are in non-prod SLAs
$nonProdInCompReport = $reportCompliance | Where { $_.'SLA Domain' -match 'Non' -or $_.'SLA Domain' -match 'test' } |
  Sort-Object -Property 'SLA Domain'

# Get unique SLA names to output the found Prod and Non-Prod SLAs
$prodSLAs = $prodInCompReport | Select-Object -ExpandProperty 'SLA Domain' | Get-Unique
$nonProdSLAs = $nonProdInCompReport | Select-Object -ExpandProperty 'SLA Domain' | Get-Unique

Write-Host "Prod SLAs ($($prodSLAs.count) SLAs with $($prodInCompReport.count) objects):"
$prodSLAs
Write-Host ""
Write-Host "Non-Prod SLAs ($($nonProdSLAs.count) SLAs with $($nonProdInCompReport.count) objects):"
$nonProdSLAs
Write-Host ""

# Script focuses on objects in the Production SLAs only
# Get the objects that have zero uploaded backups
#### IMPORTANT - Currently the logic doesn't check archive compliance but if
#### Zero uploaded snapshots then it adds it to the count. Previously, Archival Compliance
#### would show Out of Compliance as well. That needs to be fixed.
# $zeroArchivedSnapshots = $prodInCompReport | Where { $_.'Archival Compliance Status' -match 'NonCompliance' -and
#   $_.'Lastest Archival Snapshot' -eq '' }
$zeroArchivedSnapshots = $prodInCompReport | Where { $_.'Lastest Archival Snapshot' -eq $null -or $_.'Lastest Archival Snapshot' -eq '' }
# Get the objects that are out of compliance but have at least the first full uploaded
$outOfComplianceArchival = $prodInCompReport | Where { $_.'Archival Compliance Status' -match 'NonCompliance' -and
  $_.'Lastest Archival Snapshot' -ne ''}
# Get the objects that are fully in compliance
$inComplianceArchival = $prodInCompReport | Where { $_.'Archival Compliance Status' -match 'InCompliance' -and
  $_.'Lastest Archival Snapshot' -ne ''}

Write-Host "Total # of Prod Objects: $($prodInCompReport.count)"
Write-Host "# of Objects without Initial Upload: $($zeroArchivedSnapshots.count)"
Write-Host "# of Objects Out of Archival Compliance: $($outOfComplianceArchival.count)"
Write-Host ""

# In Object Capacity Report, first get the list of objects that are in the Prod SLAs
Write-Host "Processing Object Capacity Report"
$prodInObjCapacity = $reportObjCapacity | Where { $_.'SLA Domain' -notmatch 'Non' -and $_.'SLA Domain' -notmatch 'test' -and
  $_.'SLA Domain' -notmatch 'Unprotected' } | Sort-Object -Property 'SLA Domain'

# Add a unique ID to each object that consists of: Cluster+Name+Location
foreach ($obj in $prodInObjCapacity) {
  $objID = "$($obj.cluster)+$($obj.object)+$($obj.location)"
  $obj | Add-Member -MemberType NoteProperty -Name "ID" -Value $objID
}

# Loop through each object in the Compliance array, search for it in the
# Object Capacity array, and then add the capacity metrics to the Compliance array
Write-Host "Adding capacity metrics to Compliance Report, this could take a few minutes..."
$prodInCompReport | ForEach-Object -Parallel {
  $prodInObjCapacity = $using:prodInObjCapacity
  $capacityMetric = $using:capacityMetric
  $capacityDisplay = $using:capacityDisplay
  $objID = "$($_.cluster)+$($_.object)+$($_.location)"
  $_ | Add-Member -MemberType NoteProperty -Name "ID" -Value $objID
  $searchString = [regex]::Escape($objID)
  $objCapacity = $prodInObjCapacity | Where-Object -Property "ID" -match $searchString
try {
  $_ | Add-Member -MemberType NoteProperty -Name "Object Logical Size ($capacityDisplay)" -Value $($objCapacity.'Object Logical Size' / $capacityMetric)
  if ($objCapacity.'Used Size' -notmatch 'N/A') {
    $_ | Add-Member -MemberType NoteProperty -Name "Used Size ($capacityDisplay)" -Value $($objCapacity.'Used Size' / $capacityMetric)
  } else {
    $_ | Add-Member -MemberType NoteProperty -Name "Used Size ($capacityDisplay)" -Value $($objCapacity.'Used Size')
  }
  $_ | Add-Member -MemberType NoteProperty -Name "Physical Size ($capacityDisplay)" -Value $($objCapacity.'Physical Size' / $capacityMetric)
} catch {
  write-host $objCapacity.id
}
} -ThrottleLimit $throttleLimit


# Get list of unique Rubrik clusters
$clusterList = $prodInCompReport | Select-Object 'Cluster' -unique -expandProperty 'Cluster'

# Summarize the info for each cluster and also the Total across all clusters
$csvSummary = @()

# Loop through the cluster and build a cluster summary
foreach ($cluster in $clusterList)
{
  # Filter objects for In Compliance, Zero Archived, and Out of Compliance by cluster
  $clusterInComplianceArchival = $inComplianceArchival | Where { $_.'Cluster' -eq $cluster }
  $clusterZeroArchivedSnapshots = $zeroArchivedSnapshots | Where { $_.'Cluster' -eq $cluster }
  $clusterOutOfComplianceArchival = $outOfComplianceArchival | Where { $_.'Cluster' -eq $cluster }
  # Get the Physical capacity sum for each group
  $clusterInComplianceArchivalPhysicalSum = ($clusterInComplianceArchival |
    Measure-Object -Property "Physical Size ($capacityDisplay)" -Sum).Sum
  $clusterZeroArchivedSnapshotsPhysicalSum = ($clusterZeroArchivedSnapshots |
    Measure-Object -Property "Physical Size ($capacityDisplay)" -Sum).Sum
  $clusterOutOfComplianceArchivalPhysicalSum = ($clusterOutOfComplianceArchival |
    Measure-Object -Property "Physical Size ($capacityDisplay)" -Sum).Sum
  # Calculate the per cluster total Physical capacity size
  $clusterTotalPhysicalSum = $clusterInComplianceArchivalPhysicalSum +
    $clusterZeroArchivedSnapshotsPhysicalSum + $clusterOutOfComplianceArchivalPhysicalSum
  # Calculate the total # of objects for the cluster
  $clusterTotalObjects = $($clusterInComplianceArchival.count) +
    $($clusterZeroArchivedSnapshots.count) + $($clusterOutOfComplianceArchival.count)
  # Build the per cluster summary
  $clusterObj = [PSCustomObject] @{
    "Date" = $date.ToString("yyyy-MM-dd_HHmm")
    "Cluster" = $cluster
    "Total Objects" = $clusterTotalObjects
    "Total Physical Sum ($capacityDisplay)" = [Math]::Round($clusterTotalPhysicalSum, 2)
    "Zero Uploaded Out of Compliance" = $($clusterZeroArchivedSnapshots.count)
    "Zero Uploaded Physical Sum ($capacityDisplay)" = [Math]::Round($clusterZeroArchivedSnapshotsPhysicalSum, 2)
    "Out of Compliance" = $($clusterOutOfComplianceArchival.count)
    "Out of Compliance Physical Sum ($capacityDisplay)" = [Math]::Round($clusterOutOfComplianceArchivalPhysicalSum, 2)
    "In Compliance" = $($clusterInComplianceArchival.count)
    "In Compliance Physical Sum ($capacityDisplay)" = [Math]::Round($clusterInComplianceArchivalPhysicalSum, 2)
  }
  $csvSummary += $clusterObj
}

# For objects In Compliance, calculate the sum of Physical capacity
$inComplianceArchivalPhysicalSum = ($inComplianceArchival | Measure-Object -Property "Physical Size ($capacityDisplay)" -Sum).Sum
Write-Host "Objects In Compliance: $($inComplianceArchival.count)"
Write-Host "Total Physical Size In Compliance: $([Math]::Round($inComplianceArchivalPhysicalSum, 2)) $capacityDisplay"
Write-Host ""

# For objects with Zero Uploads, calculate the sum of Physical capacity
$zeroArchivedSnapshotsPhysicalSum = ($zeroArchivedSnapshots | Measure-Object -Property "Physical Size ($capacityDisplay)" -Sum).Sum
Write-Host "Objects with Zero Snapshots uploaded: $($zeroArchivedSnapshots.count)"
Write-Host "Total Physical Size not yet uploaded: $([Math]::Round($zeroArchivedSnapshotsPhysicalSum, 2)) $capacityDisplay"
Write-Host ""

# For objects Out of Compliance, calculate the sum of Physical capacity
$outOfComplianceArchivalPhysicalSum = ($outOfComplianceArchival | Measure-Object -Property "Physical Size ($capacityDisplay)" -Sum).Sum
Write-Host "Objects Out of Compliance (with first full uploaded): $($outOfComplianceArchival.count)"
Write-Host "Total Physical Size Out of Compliance: $([Math]::Round($outOfComplianceArchivalPhysicalSum, 2)) $capacityDisplay"
Write-Host ""

# Calculate the total Physical capacity size
$totalPhysicalSum = $inComplianceArchivalPhysicalSum + $zeroArchivedSnapshotsPhysicalSum + $outOfComplianceArchivalPhysicalSum

# Calculate total number of objects
$totalObjects = $($inComplianceArchival.count) + $($zeroArchivedSnapshots.count) + $($outOfComplianceArchival.count)

$summaryItem = [PSCustomObject]@{
  "Date" = $date.ToString("yyyy-MM-dd_HHmm")
  "Cluster" = "All"
  "Total Objects" = $totalObjects
  "Total Physical Sum ($capacityDisplay)" = [Math]::Round($totalPhysicalSum, 2)
  "Zero Uploaded Out of Compliance" = $($zeroArchivedSnapshots.count)
  "Zero Uploaded Physical Sum ($capacityDisplay)" = [Math]::Round($zeroArchivedSnapshotsPhysicalSum, 2)
  "Out of Compliance" = $($outOfComplianceArchival.count)
  "Out of Compliance Physical Sum ($capacityDisplay)" = [Math]::Round($outOfComplianceArchivalPhysicalSum, 2)
  "In Compliance" = $($inComplianceArchival.count)
  "In Compliance Physical Sum ($capacityDisplay)" = [Math]::Round($inComplianceArchivalPhysicalSum, 2)
}

$csvSummary += $summaryItem

try {
  $oldSummary = Import-CSV -Path $csvOutputSummary
  $csvSummary += $oldSummary
} catch { }

$zeroArchivedSnapshots = $zeroArchivedSnapshots | Sort-Object -Property "Physical Size ($capacityDisplay)" -Descending
$outOfComplianceArchival = $outOfComplianceArchival | Sort-Object -Property "Physical Size ($capacityDisplay)" -Descending
$totalOutOfCompliance = $zeroArchivedSnapshots + $outOfComplianceArchivalPhysicalSum

$totalOutOfCompliance | Export-CSV -Path $csvOutputObjectList
Write-Host "Out of Compliance CSV exported to: $csvOutputObjectList"

$csvSummary | Export-CSV -Path $csvOutputSummary

# Send an email with CSV attachment
if ($sendEmail) {
  $HTMLReport = $csvSummary
  $mailMessage = @{
    To = $emailTo
    From = $emailFrom
    Subject = $emailSubject
    Body = $HTMLReport
    SmtpServer = $SMTPServer
    SmtpPort = $SMTPPort
    Attachments = @($csvOutputObjectList, $csvOutputSummary)
    BodyAsHtml = $true
  }
  Send-MailMessage @mailMessage
}


# foreach ($obj in $prodInCompReport) {
#   $objID = "$($obj.cluster)+$($obj.object)+$($obj.location)"
#   $obj | Add-Member -MemberType NoteProperty -Name "ID" -Value $objID
#   $objCapacity = $prodInObjCapacity | Where { $_.ID -match [regex]::Escape($objID) }
#   $obj | Add-Member -MemberType NoteProperty -Name "Object Logical Capacity" -Value $objCapacity.'Object Logical Capacity'
#   $obj | Add-Member -MemberType NoteProperty -Name "Used Size" -Value $objCapacity.'Used Size'
#   $obj | Add-Member -MemberType NoteProperty -Name "Physical Size" -Value $objCapacity.'Physical Size'
# }
