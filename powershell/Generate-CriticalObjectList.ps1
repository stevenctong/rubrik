#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

# Written by Steven Tong for community usage
# GitHub: stevenctong
# Date: 10/24/20

# This script generates a list of objects whose Latest Local Snapshot Date is more than x # of days old
# Option to email the CSV at the end of this script

# $compareDays - if an object's last snapshot is older than $compareDays then add to the list
$compareDays = 3
$dateComparison = (Get-Date).AddDays(-$compareDays)

# Whether to include objects that do not have any snapshot date
$includeBlankLatest = $true

# To create a credential file (note: only the user who creates it can use it):
# Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

# Import Credential file
$credential  = Import-Clixml -Path ./rubrik_cred.xml

# Set Rubrik cluster URL/IP address
$server = 'amer1-rbk01.rubrikdemo.com'

$curDateTime = Get-Date -Format "yyyy-MM-dd_HHmm"
$csvFile = "./critical_objects-$curDateTime-$server.csv"

# Connect to Rubrik cluster
Connect-Rubrik -Server $server -Credential $credential
# Connect-Rubrik -Server $server -Token $token

# Get report ID of the "SLA Compliance Summary" report
$reportID = Get-RubrikReport -Name "SLA Compliance Summary" -Type "Canned" | Select-Object id

# Get the URL of the "SLA Compliance Report"
# -Endpoint - is in "" so to expand a variable you have to put it into $()
$reportURI = Invoke-RubrikRESTCall -Method GET -Api "internal" -Endpoint "report/$($reportID.id)/csv_link"

$date = (Get-Date).ToString("yyyy-MM-dd")

# Download the SLA Compliance Report
Invoke-WebRequest -URI $reportURI -OutFile "SLA_Compliance_Summary_Report_$date.csv"

# Import the "SLA Compliance Report"
$slaReport = Import-Csv -Path "SLA_Compliance_Summary_Report_$date.csv"


# Initializes a list of objects that need attention
$criticalObjects = @()

# Loop through the imported SLA Report
# For each object it compares if the last snapshot date is older than the date in $dateComparison.
# If it is, display it and add to $criticalObjects list.
foreach ($i in $slaReport) {
  if ($i.'Latest Local Snapshot' -ne '' -and [DateTime]$i.'Latest Local Snapshot' -le $dateComparison) {
    $i
    $criticalObjects += $i
  }
  elseif ($i.'Latest Local Snapshot' -eq '' -and $includeBlankLatest -eq $true)
  {
    $i
    $criticalObjects += $i
  }
}

# Sorts the critical object list in descending order
$criticalObjects = $criticalObjects | Sort-Object -Property 'Latest Local Snapshot' -Descending

# Current date
$curdate = Get-Date -Format "yyyy-MM-dd_HHmm"

# Exports the critical object list as a CSV
$criticalObjects | Export-Csv -NoTypeInformation -Path $csvFile
Write-Host "`nResults output to: $csvFile"

Disconnect-Rubrik -Confirm:$false

<#
# SMTP configuration
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'

$emailSubject = "Rubrik ($server) - Critical Objects List - " + $curDate
$html = "Rubrik ($server) - Critial Object List - $curDate<br><br>Attached critical_objects_$curdate.csv"

Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort -Attachments ./critical_objects_$curdate.csv
#>
