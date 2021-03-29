#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Calculates the capacity changes for each object between different dates and generates a HTML and CSV report.

.DESCRIPTION
The Get-Capacity-Change script calculates the change rates for each object between different dates.
You can specify a source date (default is today) and one or more days back to compare against.

The script uses custom Rubrik reports that it will create and update to get the required capacity info.
It stores the Rubrik report CSVs to a location to keep historical information.
The script leverages those CSV reports in order to calculate the capacity changes for each object.

A HTML report is created containing the objects with the highest capacity increase for each date that is compared.
A CSV report containing all the comparison calculations is also created.
You can send the HTML and CSV report through email.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Thanks to @joshuastenhouse for the HTML formatting
Date: 3/20/21

For authentication, use an API token (recommended), username/password, or a credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Make sure the PARAM and VARIABLES section are configured.

First run the script with the "-createRubrikReport $true" to create the custom Systme Capacity report.

Update the filenames where you want to store the reports and create directories if required.

Note: If an object was present in an older report but deleted from the Source Date it will not show up.
In this scenario there is probably negative capacity growth. This case might be handled in a future version.

.EXAMPLE
./Get-Capacity-Change.ps1 -server <Rubrik_server> -token <API_token> -createRubrikReport $true
Use an API token for authentication
Creates the custom System Capacity report on the Rubrik cluster and exits.

.EXAMPLE
./Get-Capacity-Change.ps1 -server <Rubrik_server>
Checks for credential file and if none found prompts for username/password.
Runs the script normally - make sure the PARAM and VARIABLES section are configured.

#>

param (
  [CmdletBinding()]

  # Rubrik cluster hostname or IP address
  [Parameter(Mandatory=$false)]
  [string]$server = '',

  # Use API token for authentication
  [Parameter(Mandatory=$false)]
  [string]$token = $null,

  # Use Rubrik username/password for authentication
  [Parameter(Mandatory=$false)]
  [string]$user = $null,

  # Use Rubrik username/password for authentication
  [Parameter(Mandatory=$false)]
  [string]$password = $null,

  # Use credential file for authentication, location of it
  [Parameter(Mandatory=$false)]
  [string]$rubrikCred = 'rubrik_cred.xml',

  # Set to true if you want the script to create the custom System Capacity report
  [Parameter(Mandatory=$false)]
  [boolean]$createRubrikReport = $false
)

Import-Module Rubrik

###### VARIABLES - BEGIN ######

$date = Get-Date

# "Source" date from which comparisons will be made, default is today's $date
$sourceDate = $date

# An array of days to compare $sourceDate against, the # of days back. Eg '-7' for 7 days earlier than Source Date
$compDates = @('-7', '-30')

# Cluster name, if you want to use a different alias than $server
$clusterName = $server

# System Capacity report on Rubrik we will download if today's date equals $sourceDate
$rubrikSysCapReportName = "System Capacity Report - For Script"

# Capacity over Time report  on Rubrik we will update and download for requests that don't have a System Capacity report available
$rubrikCapOverTimeReportName = "Capacity over Time Report - For Script"

# Filename for the custom System Capacity report CSV
# The date must be appended to this filename (-yyyy-MM-dd)
# The reports we will use for comparisons will also need to follow this format
$reportBaseFilename = "./rubrikreports/rubrik_system_capacity_report-$clusterName"
$reportFilename = $reportBaseFilename + "-" + $sourceDate.ToString("yyyy-MM-dd") + ".csv"

# HTML output for the summaries and top capacity change charts
$htmlOutput = "./htmlreports/rubrik_capacity_change_report-" + $clusterName + "-" + $date.ToString("yyyy-MM-dd_HHmm") + ".html"

# CSV output for the detailed capacity change numbers
$csvOutput = "./csvreports/rubrik_capacity_change_report-" + $clusterName + "-" + $date.ToString("yyyy-MM-dd_HHmm") + ".csv"

# Number of top results to return for each date comparison
$topNum = 20

# SMTP configuration
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'

$emailSubject = "Rubrik ($clusterName) - Capacity Change Report for: " + $sourceDate.ToString("yyyy-MM-dd")

# Set to $true to send out email in the script
$sendEmail = $false

###### VARIABLES - END #######

###### RUBRIK AUTHENTICATION - BEGIN ######
# First try using API token, then username/password if a user is provided, then credential file
try {
  if (!$server) { $server = Read-Host "Rubrik hostname or IP" }
  if ($token) { Connect-Rubrik -Server $server -Token $token }
  else {
    if ($user) {
      if ($password) {
        $password = ConvertTo-SecureString $password -AsPlainText -Force
        $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $user, $password
      }
      else { $credential = Get-Credential -Username $user }
    }
    elseif (Test-Path $rubrikCred) { $credential  = Import-Clixml -Path $rubrikCred }
    else { $credential = Get-Credential }
    Connect-Rubrik -Server $server -Credential $credential
  }
} catch {
  try {
    Write-Error "Error connecting to cluster or with authentication."
    $html = "Error connecting to cluster or with authentication."
    if ($sendEmail) { Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort }
    Exit 1
  } catch { Exit 1 }
}
###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# The "Create-Update-CapacityOverTimeReport" function updates the Capacity over Time report
# on Rubrik to the correct date. It will also create the report if it does not exist.
Function Create-Update-CapacityOverTimeReport($rubrikCapOverTimeReportName, $reportDate)
{
  $rubrikCapOverTimeReport = Get-RubrikReport -name $rubrikCapOverTimeReportName

  # Check the the report exists on Rubrik and create it if not
  if (!($rubrikCapOverTimeReport))
  {
    $templateBody = [PSCustomObject] @{
      name = $rubrikCapOverTimeReportName
      reportTemplate = 'CapacityOverTime'
    }

    $createReport = Invoke-RubrikRESTCall -Method POST -Api "internal" -Endpoint "report" -Body $templateBody

    $rubrikCapOverTimeReport = Get-RubrikReport -name $rubrikCapOverTimeReportName
  }

  # To generate the correct date we need to add one to the date
  $reportDate = $reportDate

  # To generate the correct date we need to add one to the date
  $reportAfterDate=$reportDate.AddDays(1).ToString("yyyy-MM-ddT00:00:00.000Z")
  $reportBeforeDate=$reportDate.AddDays(2).ToString("yyyy-MM-ddT00:00:00.000Z")

  # Capacity over time report body for the fields we are interested in
  $reportBodyCapOverTime = @"
  {
    "name":"$rubrikCapOverTimeReportName",
    "filters": {
      "dateConfig": {
        "period": "CustomDate",
        "beforeDate": "$reportBeforeDate",
        "afterDate": "$reportAfterDate"
      },
      "clusterLocation": [ "Local" ]
    },
    "chart0": {
      "id":"chart0", "name": "Total Object Logical Size",
      "chartType": "VerticalBar", "attribute": "Day", "measure":"LogicalObjectSize"
    },
    "chart1": {
      "id": "chart1", "name": "Total Storage Used by Location",
      "chartType": "StackedVerticalBar", "attribute": "Day", "measure": "StackedTotalStorage"
    },
    "table": {
      "columns": [
        "Day", "ObjectId", "ObjectName", "Location", "ObjectType", "SlaDomain",
        "LogicalObjectSize", "LocalStorage", "ArchiveStorage", "ReplicaStorage",
        "ArchivalTarget", "ReplicationTarget", "LocalDedupRatio", "LocalDataReductionPercent",
        "ArchiveDedupRatio", "ArchiveDataReductionPercent", "DirectArchive"
      ]
    }
  }
"@  | ConvertFrom-JSON

  # Update the report with the new dates and then refresh the report to make it generate much faster.
  $updateReport = Invoke-RubrikRESTCall -Method PATCH -Api "internal" -Endpoint "report/$($rubrikCapOverTimeReport.id)" -Body $reportBodyCapOverTime

  $refreshReport = Invoke-RubrikRESTCall -Method POST -Api "internal" -Endpoint "report/$($rubrikCapOverTimeReport.id)/refresh" -Body "{}"
  $updateReport

  # If report is still Updating, keep checking status until it completes
  do {
    Write-Host "Report is updating - this can take some time." -foregroundcolor blue

    sleep 10

    $updateStatus = Invoke-RubrikRESTCall -Method GET -Api "internal" -Endpoint "report/$($rubrikCapOverTimeReport.id)"
    $updateStatus
  } while ($updateStatus.updateStatus -eq 'Updating')

  Write-Host "`"$rubrikCapOverTimeReportName`" report has finished updating" -foregroundcolor green

  return 0
} # FUNCTION - Create-Update-CapacityOverTimeReport($reportName, $reportDate)

###### FUNCTIONS - END ######

# Create a new System Capacity report
if ($createRubrikReport -eq $true)
{

  if (Get-RubrikReport -name $rubrikSysCapReportName)
  {
    Write-Error "Report: `"$rubrikSysCapReportName`" already exists - exiting."
    exit 1
  }

# System capacity report body for the fields we are interested in
  $reportBodySysCap = @"
  {
    "name":"$rubrikSysCapReportName",
    "filters": {
      "clusterLocation": [ "Local" ]
    },
    "chart0": {
      "id":"chart0", "name": "Local Storage by SLA Domain",
      "chartType": "Donut", "attribute": "SlaDomain", "measure":"LocalStorage"
    },
    "chart1": {
      "id": "chart1", "name": "Local Storage Growth by SLA Domain",
      "chartType": "Donut", "attribute": "ObjectType", "measure": "LocalStorage"
    },
    "table": {
      "columns": [
        "ObjectId", "ObjectName", "Location", "ObjectType", "SlaDomain",
        "LogicalObjectSize", "LocalStorage", "ArchiveStorage", "ReplicaStorage",
        "ArchivalTarget", "ReplicationTarget", "LocalDedupRatio", "LocalDataReductionPercent",
        "ArchiveDedupRatio", "ArchiveDataReductionPercent", "ProtectedOn", "DirectArchive"
      ]
    }
  }
"@ | ConvertFrom-JSON

  $templateBody = [PSCustomObject] @{
    name = $rubrikSysCapReportName
    reportTemplate = 'SystemCapacity'
  }

  # Create a report based off the SystemCapacity template, then modify it with the report body we want
  $createReport = Invoke-RubrikRESTCall -Method POST -Api "internal" -Endpoint "report" -Body $templateBody
  $updateReport = Invoke-RubrikRESTCall -Method PATCH -Api "internal" -Endpoint "report/$($createReport.id)" -Body $reportBodySysCap

  # Refresh the report to make it generate much faster.
  $refreshReport = Invoke-RubrikRESTCall -Method POST -Api "internal" -Endpoint "report/$($createReport.id)/refresh" -Body "{}"
  $updateReport

  # If report is still Updating, keep checking status until it completes
  do {
    Write-Host "Creating report - it may take a few minutes." -ForegroundColor green

    sleep 10

    $updateStatus = Invoke-RubrikRESTCall -Method GET -Api "internal" -Endpoint "report/$($updateReport.id)"
    $updateStatus
  } while ($updateStatus.updateStatus -eq 'Updating')

  exit 0
} # IF ($create -eq $true)

# If the custom Systems Capacity report doesn't exist then recommend creating it and exit
if (!(Get-RubrikReport -name $rubrikSysCapReportName))
{
  Write-Host "Report: `"$rubrikSysCapReportName`" doesn't exist on Rubrik cluster: $server." -foregroundcolor yellow
  Write-Host "Run script with `"-createRubrikReport `$true`" to create the report. Exiting."
  exit 1
}

Write-Host "`nComparing capacities for source date: $($sourceDate.ToString("yyyy-MM-dd"))" -foregroundcolor green

foreach ($i in $compDates)
{
  Write-Host "Comparing dates for: $i Days, $($sourceDate.AddDays($i).ToString("yyyy-MM-dd"))" -foregroundcolor green
}

# If source date for comparison is today's date and the system capacity CSV does not exist then download it
if ($date -eq $sourceDate -and !(Test-Path -Path $reportFileName))
{
  Write-Host "`nDownloading `"$rubrikSysCapReportName`" to `"$reportFilename`"" -foregroundcolor green

  # Get the CSV link of the custom Systems Capacity report and download it
  # Keep historical reports in order for the script to compare against
  $reportLink = Get-RubrikReport -Name $rubrikSysCapReportName | Export-RubrikReport
  Invoke-WebRequest -Uri $reportLink -OutFile ($reportFilename)
} else {
  Write-Host "`nCapacity report found: $reportFilename" -foregroundcolor green
}

# Import reports for processing
try {
  $reportSource = Import-Csv ($reportBaseFilename + "-" + $sourceDate.ToString("yyyy-MM-dd") + ".csv")

  # Hold array of reports of the different dates we want to compare against
  $reportArray = @()

  foreach ($i in $compDates)
  {
    $compFilename = $reportBaseFilename + "-" + $sourceDate.AddDays($i).ToString("yyyy-MM-dd") + ".csv"

    # If source date for comparison is today's date and the system capacity CSV does not exist then download it
    if (!(Test-Path -Path $compFilename))
    {
      Write-Host "`nSystems Capacity report not found for $i days ($($sourceDate.AddDays($i).ToString("yyyy-MM-dd")))" -foregroundcolor yellow
      Write-Host "Generating `"$rubrikCapOverTimeReportName`" to `"$compFilename`"`n" -foregroundcolor yellow

      Create-Update-CapacityOverTimeReport $rubrikCapOverTimeReportName $sourceDate.AddDays($i)

      Write-Host "Downloading `"$rubrikCapOverTimeReportName`" to `"$compFilename`"" -foregroundcolor green

      # Get the CSV link of the custom Systems Capacity report and download it
      # Keep historical reports in order for the script to compare against
      $reportLink = Get-RubrikReport -Name $rubrikCapOverTimeReportName | Export-RubrikReport
      Invoke-WebRequest -Uri $reportLink -OutFile ($compFilename)
    } else {
      Write-Host "`nCapacity report found: $compFilename" -foregroundcolor green
    }

    $curReport = Import-CSV $compFilename

    # Add to an array of array instead of a single array
    $reportArray += , $curReport
  }
} catch {
  Write-Error $ERROR[0]
  exit 1
}

# Holds array of array of summary info for each report (capacity, # of objects, etc)
$summaryArray = @()

# Create the summary for the source report and add it as the first object
# Add the values later when we loop into that table
$summary = [PSCustomObject] @{
  "Date" = "Source $($sourceDate.ToString("yyyy-MM-dd"))"
  "Total Object Logical Size (TB)" = [math]::Round($($reportSource | Measure-Object -Property 'Object Logical Size (B)' -Sum).sum / 1000000000000, 3)
  "Total Local Storage (TB)" = [math]::Round($($reportSource | Measure-Object -Property 'Local Storage (B)' -Sum).sum / 1000000000000, 3)
  "Total Archival Storage (TB)" = [math]::Round($($reportSource | Measure-Object -Property 'Archival Storage (B)' -Sum).sum / 1000000000000, 3)
  "Total Replicated Storage (TB)" = [math]::Round($($reportSource | Measure-Object -Property 'Replicated Storage (B)' -Sum).sum / 1000000000000, 3)
  "Objects" = $reportSource.count
  "VMs" = 0
  "Physical Hosts" = 0
  "NAS" = 0
  "MS SQL" = 0
  "Oracle" = 0
  "MVs" = 0
}

$summaryArray += , $summary

# Align $compDates with $report to get how many days back we are processing
$curCompDateIndex = 0

# Loop through each report and create a unqiue ID field "Name"+"Location" for each object
foreach ($report in $reportArray)
{
  $curCompDate = $compDates[$curCompDateIndex]
  $curCompDateIndex += 1

  $summary = [PSCustomObject] @{
    "Date" = "$($sourceDate.AddDays($curCompDate).ToString("yyyy-MM-dd")) ($curCompDate Days)"
    "Total Object Logical Size (TB)" = [math]::Round($($report | Measure-Object -Property 'Object Logical Size (B)' -Sum).sum / 1000000000000, 3)
    "Total Local Storage (TB)" = [math]::Round($($report | Measure-Object -Property 'Local Storage (B)' -Sum).sum / 1000000000000, 3)
    "Total Archival Storage (TB)" = [math]::Round($($report | Measure-Object -Property 'Archival Storage (B)' -Sum).sum / 1000000000000, 3)
    "Total Replicated Storage (TB)" = [math]::Round($($report | Measure-Object -Property 'Replicated Storage (B)' -Sum).sum / 1000000000000, 3)
    "Objects" = $report.count
    "VMs" = 0
    "Physical Hosts" = 0
    "NAS" = 0
    "MS SQL" = 0
    "Oracle" = 0
    "MVs" = 0
  }

  foreach ($reportObj in $report)
  {
    $reportObj | Add-Member -MemberType NoteProperty -Name "CompDates" -Value $i
    $reportObj | Add-Member -MemberType NoteProperty -Name "NameLocation" -Value "$($reportObj.'Object Name')+$($reportObj.Location)"

    if ($reportObj."Object Type" -like "*VM*" -or $reportObj."ObjectType" -like "*vCD*") {
      $summary."VMs" += 1
    } elseif ($reportObj."Object Type" -like "*Linux*" -or $reportObj."Object Type" -like "*Windows*") {
      $summary."Physical Hosts" += 1
    } elseif ($reportObj."Object Type" -like "*NAS*") {
      $summary."NAS" += 1
    } elseif ($reportObj."Object Type" -like "*SQL*") {
      $summary."MS SQL" +=1
    } elseif ($reportObj."Object Type" -like "*Oracle*") {
      $summary."Oracle" += 1
    } elseif ($reportObj."Object Type" -like "*Managed*") {
      $summary."MVs" += 1
    }
  } # FOREACH $reportObj in $report

  $summaryArray += , $summary
}

$count = 1
$total = $reportSource.count

foreach ($i in $reportSource)
{
  # Create a unique field using "Name"+"Location" field for each object in the report
  $i | Add-Member -MemberType NoteProperty -Name "NameLocation" -Value "$($i.'Object Name')+$($i.Location)"

  Write-Host "Processing $count of $total - Phase (1 of 2)  [$($i.'NameLocation')]"
  $count += 1

  # Add summary info to the summary array
  if ($i."Object Type" -like "*VM*" -or $i."ObjectType" -like "*vCD*") {
    $summaryArray[0]."VMs" += 1
  } elseif ($i."Object Type" -like "*Linux*" -or $i."Object Type" -like "*Windows*") {
    $summaryArray[0]."Physical Hosts" += 1
  } elseif ($i."Object Type" -like "*NAS*") {
    $summaryArray[0]."NAS" += 1
  } elseif ($i."Object Type" -like "*SQL*") {
    $summaryArray[0]."MS SQL" +=1
  } elseif ($i."Object Type" -like "*Oracle*") {
    $summaryArray[0]."Oracle" += 1
  } elseif ($i."Object Type" -like "*Managed*") {
    $summaryArray[0]."MVs" += 1
  }

  # Calculate today's report metrics to GB
  $localStorageGB = [math]::Round($i."Local Storage (B)" / 1000000000, 3)
  $logicalStorageGB = [math]::Round($i."Object Logical Size (B)" / 1000000000)
  $archivalStorageGB = [math]::Round($i."Archival Storage (B)" / 1000000000, 3)
  $replicationStorageGB = [math]::Round($i."Replicated Storage (B)" / 1000000000, 3)

  $i | Add-Member -MemberType NoteProperty -Name "Local Storage (GB)" -Value $localStorageGB
  $i | Add-Member -MemberType NoteProperty -Name "Object Logical Size (GB)" -Value $logicalStorageGB
  $i | Add-Member -MemberType NoteProperty -Name "Archival Storage (GB)" -Value $archivalStorageGB
  $i | Add-Member -MemberType NoteProperty -Name "Replicated Storage (GB)" -Value $replicationStorageGB

  # Align $compDates with $report to get how many days back we are processing
  $curCompDateIndex = 0

  # Loop through each old report that we want to compare against
  foreach ($report in $reportArray)
  {
    $curCompDate = $compDates[$curCompDateIndex]
    $curCompDateIndex += 1

    # Find the object in the old report we want to compare against to the source's object
    $obj = $report | Where { $_.NameLocation -eq $i.NameLocation }

    if ($obj)
    {
      # Calculate the old report metrics to GB
      # If there are multiple objects of the same 'Name+Location' only uses the first one - use Object ID to handle uniques better
      $objLocalStorageGB = [math]::Round($obj[0]."Local Storage (B)" / 1000000000, 3)
      $objLogicalStorageGB = [math]::Round($obj[0]."Object Logical Size (B)" / 1000000000)
      $objArchivalStorageGB = [math]::Round($obj[0]."Archival Storage (B)" / 1000000000, 3)
    } else {
      $objLocalStorageGB = 0
      $objLogicalStorageGB = 0
      $objArchivalStorageGB = 0
    }

    # Calculate the capacity change rates
    $localChangeGB = [math]::Round($localStorageGB - $objLocalStorageGB, 3)
    $logicalChangeGB = [math]::Round($logicalStorageGB - $objLogicalStorageGB, 3)
    $archivalChangeGB = [math]::Round($archivalStorageGB - $objArchivalStorageGB, 3)

    $i | Add-Member -MemberType NoteProperty -Name "Local Storage (GB) $curCompDate Days" -Value $objLocalStorageGB
    $i | Add-Member -MemberType NoteProperty -Name "Object Logical Size (GB) $curCompDate Days" -Value $objLogicalStorageGB
    $i | Add-Member -MemberType NoteProperty -Name "Archival Storage (GB) $curCompDate Days" -Value $objArchivalStorageGB

    $i | Add-Member -MemberType NoteProperty -Name "Local Storage Change (GB) $curCompDate Days" -Value $localChangeGB
    $i | Add-Member -MemberType NoteProperty -Name "Object Logical Size Change (GB) $curCompDate Days" -Value $logicalChangeGB
    $i | Add-Member -MemberType NoteProperty -Name "Archival Storage Change (GB) $curCompDate Days" -Value $archivalChangeGB
  } # FOREACH - $report in $reportArray - locate object for comparison
} # FOREACH - Loop through each object in today's report

#  Array to store formatted results
$results=@()

$count = 1
$total = $reportSource.count

# Loop through each report object to format and build $results array
foreach ($i in $reportSource)
{
  Write-Host "Processing $count of $total - Phase (2 of 2)  [$($i.'NameLocation')]" -foregroundcolor green
  $count += 1

  # $resultObj holds the formatted and calculated values for the source object being processed
  $resultObj = [PSCustomObject] @{
    "Object Name" = $i."Object Name"
    "Location" = $i.location
    "NameLocation" = $i.NameLocation
    "Object Type" = $i."Object Type"
  }

  foreach ($j in $compDates) {
    $resultObj | Add-Member -MemberType NoteProperty `
      -Name "Local Storage Change (GB) $j Days" -Value $i."Local Storage Change (GB) $j Days"
  }

  $resultObj | Add-Member -MemberType NoteProperty `
    -Name "Local Storage (GB)" -Value $i."Local Storage (GB)"

  foreach ($j in $compDates) {
    $resultObj | Add-Member -MemberType NoteProperty `
      -Name "Local Storage (GB) $j Days" -Value $i."Local Storage (GB) $j Days"
  }

  $resultObj | Add-Member -MemberType NoteProperty `
    -Name "Object Logical Size (GB)" -Value $i."Object Logical Size (GB)"

  foreach ($j in $compDates) {
    $resultObj | Add-Member -MemberType NoteProperty `
      -Name "Object Logical Size (GB) $j Days" -Value $i."Object Logical Size (GB) $j Days"
  }

  $resultObj | Add-Member -MemberType NoteProperty `
    -Name "Archival Target" -Value $i."Archival Target"
  $resultObj | Add-Member -MemberType NoteProperty `
    -Name "Archival Storage (GB)" -Value $i."Archival Storage (GB)"

  foreach ($j in $compDates) {
    $resultObj | Add-Member -MemberType NoteProperty `
      -Name "Archival Storage (GB) $j Days" -Value $i."Archival Storage (GB) $j Days"
  }

  $resultObj | Add-Member -MemberType NoteProperty `
    -Name "Replication Target" -Value $i."Replication Target"
  $resultObj | Add-Member -MemberType NoteProperty `
    -Name "Replicated Storage (GB)" -Value $i."Replicated Storage (GB)"

  $resultObj | Add-Member -MemberType NoteProperty -Name "SLA Domain" -Value $i."SLA Domain"
  $resultObj | Add-Member -MemberType NoteProperty -Name "Protected On" -Value $i."Protected On"
  $resultObj | Add-Member -MemberType NoteProperty -Name "Local Data Reduction (%)" -Value $i."Local Data Reduction (%)"
  $resultObj | Add-Member -MemberType NoteProperty -Name "Local Dedup Ratio (x)" -Value $i."Local Dedup Ratio (x)"
  $resultObj | Add-Member -MemberType NoteProperty -Name "Archival Data Reduction (%)" -Value $i."Archival Data Reduction (%)"
  $resultObj | Add-Member -MemberType NoteProperty -Name "Archival Dedup Ratio (x)" -Value $i."Archival Dedup Ratio (x)"
  $resultObj | Add-Member -MemberType NoteProperty -Name "Source Date" -Value $sourceDate.ToString("yyyy-MM-dd")

  $results += $resultObj
} # FOREACH - Loop through each report object to format

# Array of an array that contains the top results for each date comparison
$topResults = @()

# Loop through number of past dates to compare against to build top # list
foreach ($j in $compDates)
{
  # Sort results by the largest change for each comparison date to pull top results
  $results = $results | Sort-Object -Property "Local Storage Change (GB) $j Days" -Descending

  # Array to hold top results of current date comparison
  $topCompResults = @()

  # Add the $topNum (eg top 20) results to the array
  for ($n = 0; $n -lt $topNum; $n++)
  {
    $topCompResults += $results[$n]
  }

  $topResults += , $topCompResults
}

# Export results to CSV file
$results | Export-Csv -NoTypeInformation -Path $csvOutput
Write-Host "`nCSV report output to: $csvOutput" -foregroundcolor green


### Creating HTML tables ###
### HTML formatting borrowed from: @joshuastenhouse

$HTMLHighlightColor="#FFC000"
$HTMLRubrikColor="#00B2A9"

$HTMLStart = @"
<!DOCTYPE html>
<html>
<head>
<style>

a {
    color: black;
}

a:link {
    text-decoration: none;
    color: #333333;
}

table.table1 {
  border-collapse: collapse;
  width: 100%;
}
table.table1 th {
  text-align: center;
  padding: 8px;
  border-bottom: 1px solid #ddd;
  background-color: white;
  color: #333333;
  font-size:16px
}
table.table1 td {
  text-align: center;
  padding: 8px;
  border-bottom: 1px solid #ddd;
  font-size:12px
}

table.table2 {
  border-collapse: collapse;
  width: 100%;
}
table.table2 th {
  text-align: center;
  padding: 8px;
  border-bottom: 1px solid #ddd;
  background-color: white;
  color: #00B2A9;
  font-size:14px
}
table.table2 td {
  text-align: center;
  padding: 8px;
  border-bottom: 1px solid #ddd;
  font-size:12px
}

table.table3 {
  border-collapse: collapse;
  width: 100%;
}
table.table3 th {
  text-align: left;
  padding: 8px;
  border-bottom: 1px solid #ddd;
  background-color: white;
  color: #00B2A9;
  font-size:14px
}
table.table3 td {
  text-align: left;
  padding: 8px;
  border-bottom: 1px solid #ddd;
  font-size:12px
}

</style>
</head>

<body>

<div style="overflow-x:auto;">

<br><br>
"@

$HTMLEnd = @"
</div>

</body>
</html>
"@

### Create HTML report info
$HTMLReportInfo = @"
<b>Rubrik Cluster: <font color=$HTMLRubrikColor>$clusterName</font></b>
<br>
<b>Rubrik Report (System Capacity):</b> $rubrikSysCapReportName
<br>
<b>Rubrik Report (Capacity over Time):</b> $rubrikCapOverTimeReportName
<br>
<b>Report Generated On:</b> $date
<br><br>
<b>Source Report Date:</b> $($sourceDate.ToString("yyyy-MM-dd"))
<br><br>
"@

### Create HTML summary table

$HTMLSummaryTable = $null
$HTMLSummaryTableMiddle = $null

$HTMLSummaryTableStart = @"
<table class="table1">
  <tr>
    <th>Report Summaries</th>
  </tr>
</table>

<table class="table2">
  <tr>
    <th>Report Dates</th>
    <th>Object Logical Size (TB)</th>
    <th>Local Storage (TB)</th>
    <th>Archival Storage</th>
    <th>Replicated Storage (TB)</th>
    <th>|</th>
    <th>Objects</th>
    <th>VMs</th>
    <th>Physical Hosts</th>
    <th>NAS</th>
    <th>MS SQL</th>
    <th>Oracle</th>
    <th>MVs</th>
  </tr>
"@

$HTMLSummaryTableEnd = @"
</table>
<br>
"@

# Loop through each report summary info and create display
foreach ($sumDate in $summaryArray)
{
  $HTMLSummaryTableRow = "
  <tr>
    <td>$($sumDate."Date")</td>
    <td>$($sumDate."Total Object Logical Size (TB)")</td>
    <td><b>$($sumDate."Total Local Storage (TB)")</b></td>
    <td>$($sumDate."Total Archival Storage (TB)")</td>
    <td>$($sumDate."Total Replicated Storage (TB)")</td>
    <td>|</td>
    <td><b>$($sumDate."Objects")</b></td>
    <td>$($sumDate."VMs")</td>
    <td>$($sumDate."Physical Hosts")</td>
    <td>$($sumDate."NAS")</td>
    <td>$($sumDate."MS SQL")</td>
    <td>$($sumDate."Oracle")</td>
    <td>$($sumDate."MVs")</td>
  </tr>
  "
  $HTMLSummaryTableMiddle += $HTMLSummaryTableRow
}

$HTMLSummaryTable += $HTMLSummaryTableStart + $HTMLSummaryTableMiddle + $HTMLSummaryTableEnd + "<br><br>"

### Create HTML result tables
$HTMLResultTable = $null
$HTMLResultTableMiddle = $null

$curCompDateIndex = 0

# Creates a separate table for each of the reports we compare against
foreach ($curTopResult in $topResults)
{
  # Match the current report with the comparison date
  $curCompDate = $compDates[$curCompDateIndex]
  $curCompDateIndex += 1

  $curCompDateTime = $sourceDate.AddDays($curCompDate).ToString("yyyy-MM-dd")

  $HTMLResultTableStart = @"
  <table class="table1">
    <tr>
      <th>Top $topNum objects with largest Local Storage change from: <b><font color=$HTMLHighlightColor>$curCompDate days</b> ago ($curCompDateTime)</font></th>
    </tr>
  </table>

  <table class="table2">
    <tr>
      <th>Object</th>
      <th>Location</th>
      <th>Object Type</th>
      <th><font color=$HTMLHighlightColor>Local Storage Change (GB)</font></th>
      <th>Local Storage (GB): Source</th>
      <th>Local Storage (GB): $curCompDate Days</th>
      <th>Archival Storage (GB): Source</th>
      <th>Archival Storage (GB): $curCompDate Days</th>
    </tr>
"@

  $HTMLResultTableEnd = @"
  </table>
  <br>
"@

  $HTMLResultTableMiddle = $null

  foreach ($row in $curTopResult)
  {
    $HTMLResultTableRow = "
    <tr>
      <td style=text-align:left>$($row."Object Name")</td>
      <td style=text-align:left>$($row."Location")</td>
      <td>$($row."Object Type")</td>
      <td><font color=$HTMLHighlightColor>$($row."Local Storage Change (GB) $curCompDate Days")</font></td>
      <td>$($row."Local Storage (GB)")</td>
      <td>$($row."Local Storage (GB) $curCompDate Days")</td>
      <td>$($row."Archival Storage (GB)")</td>
      <td>$($row."Archival Storage (GB) $curCompDate Days")</td>
    </tr>
    "
    $HTMLResultTableMiddle += $HTMLResultTableRow
  }

  $HTMLResultTable += $HTMLResultTableStart + $HTMLResultTableMiddle + $HTMLResultTableEnd + "<br><br>"
}

# Put all pieces of HTML together
$HTMLReport = $HTMLStart + $HTMLReportInfo + $HTMLSummaryTable + $HTMLResultTable + $HTMLEnd

# Export results to HTML file
$HTMLReport | Out-File -FilePath $htmlOutput
Write-Host "`nHTML report output to: $htmlOutput" -foregroundcolor green


# Send an email
if ($sendEmail)
{
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $HTMLReport -SmtpServer $SMTPServer -Port $SMTPPort -Attachments $csvOutput
}

Disconnect-Rubrik
