#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
The Get-RubrikRunningEvents.ps1 script gets a list of running events and outputs it to html & csv.

.DESCRIPTION
The Get-RubrikRunningEvents.ps1 script gets a list of running events and outputs it to html & csv.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 4/4/21

For authentication, use one of the following methods:
$token - an API token tied to a user account; keep in mind that tokens have an expiration date
$credential - credential file that can be created using: Get-Credential | Export-CliXml -Path ./rubrik_cred.xml
$user and $password - plaintext username and password

Update the the PARAM and VARIABLES section as needed.

.EXAMPLE
./Get-RubrikRunningEvents.ps1 -server <Rubrik_server>
The script will prompt for a username and password for the Rubrik cluster

.EXAMPLE
./Get-RubrikRunningEvents.ps1 -server <Rubrik_server> -token <API_token>
Use an API token for authentication

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
  [string]$rubrikCred = 'rubrik_cred.xml'
)

Import-Module Rubrik

###### VARIABLES - BEGIN ######

$date = Get-Date
$dateUTC = Get-Date -AsUTC
$diffUTChours = $($date - $dateUTC).hours

# SMTP configuration
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'

$emailSubject = "Rubrik Running Events ($server) - " + $date.ToString("yyyy-MM-dd HH:MM")
$html = "Body<br><br>"

# Set to $true to send out email in the script
$sendEmail = $false

# CSV file info
$csvOutput = "./rubrik_running_events-$($date.ToString("yyyy-MM-dd_HHmm")).csv"
$htmlOutput = "./rubrik_running_events-$($date.ToString("yyyy-MM-dd_HHmm")).html"

###### VARIABLES - END #######

###### RUBRIK AUTHENTICATION - BEGIN ######
# First try using API token, then username/password if a user is provided, then credential file
try {
  if (!$server) { $server = Read-Host "Rubrik hostname or IP" }
  if ($token) { Connect-Rubrik -Server $server -Token $token }
  else {
    if ($user) {
      if ($password) {
        [SecureString]$password = ConvertTo-SecureString -String  $password -AsPlainText -Force
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

# Get a list of Rubrik events with filtering
$events = Get-RubrikEvent -status "Running" -EventType "Backup"

# Holds an array of events to output
$eventArray = @()

# Loop through all the events to pull event series detail
foreach ($e in $events) {
  # Get the event series detail for an event
  $eventDetail = Get-RubrikEventSeries -id $e.eventSeriesId
  if ($eventDetail.startTime -ne $null) {
    $StartTimeLocal = $eventDetail.starttime.AddHours($diffUTChours)
  } else {
    $StartTimeLocal = $null
  }
  # Format the event series detail with the columns that you want
  $eventItem = [PSCustomObject]@{
    Name = $eventDetail.objectName
    Location = $eventDetail.location
    Status = $eventDetail.Status
    StartTimeUTC = $eventDetail.startTime
    StartTimeLocal = $StartTimeLocal
    Duration = $eventDetail.duration
    ProgressPercentage = $eventDetail.progressPercentage
    DataTransferredGB = $eventDetail.dataTransferred / 1000000000
  }
  # Add the event to the array of events
  $eventArray += $eventItem
}


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

### Create HTML summary info
$HTMLReportInfo = $null

### Create HTML result tables
$HTMLResultTable = $null
$HTMLResultTableMiddle = $null
$HTMLResultTableEnd = $null

$HTMLResultTableStart = @"
<table class="table1">
  <tr>
    <th>Currently running events </th>
  </tr>
</table>

<table class="table2">
  <tr>
    <th>Name</th>
    <th>Location</th>
    <th>Status</th>
    <th>StartTimeUTC</th>
    <th>StartTimeLocal</th>
    <th>Duration</th>
    <th>Progress</th>
    <th>DataTransferredGB</th>
  </tr>
"@

$HTMLResultTableEnd = @"
</table>
<br>
"@

foreach ($row in $eventArray)
{
  $HTMLResultTableRow = "
  <tr>
    <td style=text-align:left>$($row.Name)</td>
    <td style=text-align:left>$($row.Location)</td>
    <td>$($row.Status)</td>
    <td>$($row.StartTimeUTC)</td>
    <td>$($row.StartTimeLocal)</td>
    <td>$($row.Duration)</td>
    <td>$($row.ProgressPercentage)</td>
    <td>$($row.DataTransferredGB)</td>
  </tr>
  "
  $HTMLResultTableMiddle += $HTMLResultTableRow
}

$HTMLResultTable += $HTMLResultTableStart + $HTMLResultTableMiddle + $HTMLResultTableEnd + "<br><br>"

# Put all pieces of HTML together
$HTMLReport = $HTMLStart + $HTMLReportInfo + $HTMLResultTable + $HTMLEnd

# Export results to HTML file
$HTMLReport | Out-File -FilePath $htmlOutput
Write-Host "`nHTML report output to: $htmlOutput" -foregroundcolor green

# Export the list to a CSV file
$eventList | Export-Csv -NoTypeInformation -Path $csvOutput
Write-Host "`nResults output to: $csvOutput"

# Send an email with CSV attachment
if ($sendEmail)
{
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort -Attachments $csvOutput
}
