# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Calculates the capacity changes for each object between different dates and generates a HTML and CSV report.

.DESCRIPTION
The Get-CapacityChangeReport script calculates the Rubrik storage change rates for each object between different dates.
By default all comparisons will be done against today which is the source date.

A HTML report is created summarizing the capacity of the cluster on each date and the top objects with the greatest growth.
A CSV report containing all the capacity details for every object is also created.
The HTML report and CSV as an attachment can be sent over email.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Thanks to @joshuastenhouse for the HTML formatting
Date: 12/10/25

Update the the PARAM and VARIABLES section as desired.

.EXAMPLE
./Get-CapacityChangeReport.ps1

#>

# param (
#   [CmdletBinding()]
#   # Rubrik cluster hostname or IP address
#   [Parameter(Mandatory=$false)]
#   [string]$server = ''
# )


###### VARIABLES - BEGIN ######
$date = Get-Date

# Local CSV to use as source comparison, most recent report, set $useLocalReport to $true
$rubrikCSVRecent = "./capacity-12-09.csv"

# Local CSV to use as source comparison, oldest report, set $useLocalReport to $true
$rubrikCSVOldest = "./capacity-11-01.csv"

# Manually set the cluster name
$clusterName = "Rubrik"

# An array of days to compare $sourceDate against, the # of days back. Eg '-7' for 7 days earlier than Source Date
$compDates = @('-1')

# HTML report that contains the cluster summary and top objects with the most growth between the dates
# Change the directory path as needed
$htmlOutput = "./htmlreports/rubrik_capacity_change_report-" + $clusterName + "-" + $date.ToString("yyyy-MM-dd_HHmm") + ".html"

# CSV file that has detailed object capacity info
# Change the directory path as needed
$csvOutput = "./csvreports/rubrik_capacity_change_report-" + $clusterName + "-" + $date.ToString("yyyy-MM-dd_HHmm") + ".csv"

# For the HTML report, the number of top objects to return for the comparisons per date
$topNum = 20

# SMTP configuration
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'

$emailSubject = "Rubrik ($clusterName) - Capacity Change Report for: " + $sourceDate.ToString("yyyy-MM-dd")

# Set to $true to send out email in the script
$sendEmail = $false

# Metric definitions in case they change in the future
$localStorage = 'Local Storage'
$logicalBytes = 'Logical Bytes'
$archiveStorage = 'Archive Storage'
$replicaStorage = 'Replica Storage'

###### VARIABLES - END #######

###### FUNCTIONS - BEGIN ######

$reportSource = Import-Csv $rubrikCSVRecent
# Hold array of reports of the different dates we want to compare against
$reportArray = @()
$curReport = Import-CSV $rubrikCSVOldest
# Add to as an array of arrays instead of a single array
$reportArray += , $curReport

# Get the source date
$sourceDate = [datetime]::Parse($reportSource[0].time)

# Holds array of array of summary info for each report (capacity, # of objects, etc)
$summaryArray = @()

# Create the summary for the source report and add it as the first object
# Add the values later when we loop into that table
$summary = [PSCustomObject] @{
  "Date" = "Source $($sourceDate.ToString("yyyy-MM-dd"))"
  "Total Object Logical Size (TB)" = [math]::Round($($reportSource | Measure-Object -Property $logicalBytes -Sum).sum / 1000000000000, 3)
  "Total Local Storage (TB)" = [math]::Round($($reportSource | Measure-Object -Property $localStorage -Sum).sum / 1000000000000, 3)
  "Total Archival Storage (TB)" = [math]::Round($($reportSource | Measure-Object -Property $archiveStorage -Sum).sum / 1000000000000, 3)
  "Total Replicated Storage (TB)" = [math]::Round($($reportSource | Measure-Object -Property $replicaStorage -Sum).sum / 1000000000000, 3)
  "Objects" = 0
  "VMs" = 0
  "Physical Hosts" = 0
  "NAS" = 0
  "MS SQL" = 0
  "Oracle" = 0
  "MVs" = 0
  "SAP HANA" = 0
  "DB2" = 0
  "MongoDB" = 0
  "K8S" = 0
  "ADs" = 0
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
    "Total Object Logical Size (TB)" = [math]::Round($($report | Measure-Object -Property $logicalBytes -Sum).sum / 1000000000000, 3)
    "Total Local Storage (TB)" = [math]::Round($($report | Measure-Object -Property $localStorage -Sum).sum / 1000000000000, 3)
    "Total Archival Storage (TB)" = [math]::Round($($report | Measure-Object -Property $archiveStorage -Sum).sum / 1000000000000, 3)
    "Total Replicated Storage (TB)" = [math]::Round($($report | Measure-Object -Property $replicaStorage -Sum).sum / 1000000000000, 3)
    "Objects" = 0
    "VMs" = 0
    "Physical Hosts" = 0
    "NAS" = 0
    "MS SQL" = 0
    "Oracle" = 0
    "SAP HANA" = 0
    "DB2" = 0
    "MongoDB" = 0
    "MVs" = 0
    "K8S" = 0
    "ADs" = 0
  }

  foreach ($reportObj in $report)
  {
    $reportObj | Add-Member -MemberType NoteProperty -Name "CompDates" -Value $i
    if ($reportObj."Object Type" -like "*VM*") {
      $reportObj | Add-Member -MemberType NoteProperty -Name "NameLocation" -Value "$($reportObj.'Object Name')"
    } else {
      $reportObj | Add-Member -MemberType NoteProperty -Name "NameLocation" -Value "$($reportObj.'Object Name')+$($reportObj.Location)"
    }

    # Add to count if it exists and Local Capacity > 0 to ignore anything that isn't really protected
    if (($reportObj."Object Type" -like "*VM*" -or $reportObj."ObjectType" -like "*vCD*") -and [double]$reportObj."$localStorage" -gt 0) {
      $summary."VMs" += 1
      $summary."Objects" +=1
    } elseif (($reportObj."Object Type" -like "*Linux*" -or $reportObj."Object Type" -like "*Windows*") -and [double]$reportObj."$localStorage" -gt 0) {
      $summary."Physical Hosts" += 1
      $summary."Objects" +=1
    } elseif ($reportObj."Object Type" -like "*NAS*" -and [double]$reportObj."$localStorage" -gt 0) {
      $summary."NAS" += 1
      $summary."Objects" +=1
    } elseif ($reportObj."Object Type" -like "*SQL*" -and [double]$reportObj."$localStorage" -gt 0) {
      $summary."MS SQL" +=1
      $summary."Objects" +=1
    } elseif ($reportObj."Object Type" -like "*Oracle*" -and [double]$reportObj."$localStorage" -gt 0) {
      $summary."Oracle" += 1
      $summary."Objects" +=1
    } elseif ($reportObj."Object Type" -like "*Managed*" -and [double]$reportObj."$localStorage" -gt 0) {
      $summary."MVs" += 1
      $summary."Objects" +=1
    } elseif ($reportObj."Object Type" -like "*Active*" -and [double]$reportObj."$localStorage" -gt 0) {
      $summary."ADs" += 1
      $summary."Objects" +=1
    } elseif ($reportObj."Object Type" -like "*HANA*" -and [double]$reportObj."$localStorage" -gt 0) {
      $summary."SAP HANA" += 1
      $summary."Objects" +=1
    } elseif ($reportObj."Object Type" -like "*DB2*" -and [double]$reportObj."$localStorage" -gt 0) {
      $summary."DB2" += 1
      $summary."Objects" +=1
    } elseif ($reportObj."Object Type" -like "*Mongo*" -and [double]$reportObj."$localStorage" -gt 0) {
      $summary."MongoDB" += 1
      $summary."Objects" +=1
    } elseif ($reportObj."Object Type" -like "*K8s*" -and [double]$reportObj."$localStorage" -gt 0) {
      $summary."K8S" += 1
      $summary."Objects" +=1
    }
  } # FOREACH $reportObj in $report

  $summaryArray += , $summary
}

$count = 1
$total = $reportSource.count

foreach ($i in $reportSource)
{
  # Create a unique field using "Name"+"Location" field for each object in the report
  if ($i."Object Type" -like "*VM*") {
    $i | Add-Member -MemberType NoteProperty -Name "NameLocation" -Value "$($i.'Object Name')"
  } else {
    $i | Add-Member -MemberType NoteProperty -Name "NameLocation" -Value "$($i.'Object Name')+$($i.Location)"
  }

  Write-Host "Processing $count of $total - Phase (1 of 2)  [$($i.'NameLocation')]"
  $count += 1

  # Add to count if it exists and Local Capacity > 0 to ignore anything that isn't really protected
  if (($i."Object Type" -like "*VM*" -or $i."ObjectType" -like "*vCD*") -and [double]$i."$localStorage" -gt 0) {
    $summaryArray[0]."VMs" += 1
    $summaryArray[0]."Objects" += 1
  } elseif (($i."Object Type" -like "*Linux*" -or $i."Object Type" -like "*Windows*") -and [double]$i."$localStorage" -gt 0) {
    $summaryArray[0]."Physical Hosts" += 1
    $summaryArray[0]."Objects" += 1
  } elseif ($i."Object Type" -like "*NAS*" -and [double]$i."$localStorage" -gt 0) {
    $summaryArray[0]."NAS" += 1
    $summaryArray[0]."Objects" += 1
  } elseif ($i."Object Type" -like "*SQL*" -and [double]$i."$localStorage" -gt 0) {
    $summaryArray[0]."MS SQL" +=1
    $summaryArray[0]."Objects" += 1
  } elseif ($i."Object Type" -like "*Oracle*" -and [double]$i."$localStorage" -gt 0) {
    $summaryArray[0]."Oracle" += 1
    $summaryArray[0]."Objects" += 1
  } elseif ($i."Object Type" -like "*Managed*" -and [double]$i."$localStorage" -gt 0) {
    $summaryArray[0]."MVs" += 1
    $summaryArray[0]."Objects" += 1
  } elseif ($reportObj."Object Type" -like "*Active*" -and [double]$reportObj."$localStorage" -gt 0) {
    $summaryArray[0]."ADs" += 1
    $summaryArray[0]."Objects" +=1
  } elseif ($reportObj."Object Type" -like "*HANA*" -and [double]$reportObj."$localStorage" -gt 0) {
    $summaryArray[0]."SAP HANA" += 1
    $summaryArray[0]."Objects" +=1
  } elseif ($reportObj."Object Type" -like "*DB2*" -and [double]$reportObj."$localStorage" -gt 0) {
    $summaryArray[0]."DB2" += 1
    $summaryArray[0]."Objects" +=1
  } elseif ($reportObj."Object Type" -like "*Mongo*" -and [double]$reportObj."$localStorage" -gt 0) {
    $summaryArray[0]."MongoDB" += 1
    $summaryArray[0]."Objects" +=1
  } elseif ($reportObj."Object Type" -like "*K8s*" -and [double]$reportObj."$localStorage" -gt 0) {
    $summaryArray[0]."K8S" += 1
    $summaryArray[0]."Objects" +=1
  }

  # Calculate today's report metrics to GB
  $localStorageGB = [math]::Round($i."$localStorage" / 1000000000, 3)
  $logicalStorageGB = [math]::Round($i."$logicalBytes" / 1000000000)
  $archivalStorageGB = [math]::Round($i."$archiveStorage" / 1000000000, 3)
  $replicationStorageGB = [math]::Round($i."$replicaStorage" / 1000000000, 3)

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
      $objLocalStorageGB = [math]::Round($obj[0]."$localStorage" / 1000000000, 3)
      $objLogicalStorageGB = [math]::Round($obj[0]."$logicalBytes" / 1000000000)
      $objArchivalStorageGB = [math]::Round($obj[0]."$archiveStorage" / 1000000000, 3)
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
    <th>Archival Storage (TB)</th>
    <th>Replicated Storage (TB)</th>
    <th>|</th>
    <th>Objects</th>
    <th>VMs</th>
    <th>Physical Hosts</th>
    <th>NAS</th>
    <th>MS SQL</th>
    <th>Oracle</th>
    <th>MVs</th>
    <th>ADs</th>
    <th>SAP HANA</th>
    <th>Db2</th>
    <th>K8S</th>
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
    <td>$($sumDate."ADs")</td>
    <td>$($sumDate."SAP HANA")</td>
    <td>$($sumDate."Db2")</td>
    <td>$($sumDate."K8S")</td>
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

if ($useLocalReport -eq $false) {
  # Disconnect-Rubrik
  Invoke-RestMethod -uri $delSessionURL -Headers $header -Method Delete -ContentType $type -SkipCertificateCheck
}
