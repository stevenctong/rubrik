#requires -modules Rubrik
<#
.SYNOPSIS
This script imports a list objects which have previously been tiered and
checks the status from the event series.

.DESCRIPTION
This script imports a list objects which have previously been tiered and
checks the status from the event series.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 4/20/24

Fill out the PARAM and VARIABLES section with config details for this script.

.EXAMPLE
./Get-TierSnapshotsStatus.ps1

#>

param (
  [CmdletBinding()]

  # Rubrik cluster hostname or IP address
  [Parameter(Mandatory=$false)]
  [string]$server = '',

  # Use API token for authentication
  [Parameter(Mandatory=$false)]
  [string]$token = ''
)

Import-Module Rubrik

###### VARIABLES - BEGIN ######

# Depending on cluster version, set to either '1' or 'internal'
# Use '1' for later cluster versions (v5.1+)
$apiVer = '1'

# CSV file info
$date = Get-Date

# Specify filename of the CSV file with the list of objects to check
$csvInput = "./rubrk_tier_objects-2024-04-23_2158.csv"

# Specify output CSV
$csvOutput = "./rubrk_tier_event_list-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

###### VARIABLES - END ######

###### RUBRIK AUTHENTICATION - BEGIN ######
# First try using API token, then username/password if a user is provided, then credential file
try {
  if (!$server) { $server = Read-Host "Rubrik hostname or IP" }
  if ($token) { Connect-Rubrik -Server $server -Token $token } else {
    Write-Error "No token supplied."
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

$objList = Import-CSV -Path $csvInput

$objCount = $objList.count
$count = 1

foreach ($obj in $objList) {
  Write-Host "[$count / $objCount] Getting archive events for: $($obj.name)"
  $count++
  $archiveEvents = Get-RubrikEvent -id $obj.id -eventtype 'Archive'
  $tierEvent = $archiveEvents | Where { $_.eventName -match 'Tier' }
  if ($tierEvent.count -gt 0) {
    $obj | Add-Member -MemberType NoteProperty -Name "eventName" -Value $($tierEvent[0].eventName)
    $obj | Add-Member -MemberType NoteProperty -Name "eventStatus" -Value $($tierEvent[0].eventStatus)
    $obj | Add-Member -MemberType NoteProperty -Name "eventInfo" -Value $($tierEvent[0].eventInfo)
  }
}

$objList | Export-CSV -NoTypeInformation -path $csvOutput
Write-Host "CSV output to: $csvOutput"

$disconnect = Disconnect-Rubrik -Confirm:$false
