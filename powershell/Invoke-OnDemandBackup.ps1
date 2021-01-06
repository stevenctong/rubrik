#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

# Written by Steven Tong for community usage
# GitHub: stevenctong
# Date: 9/23/20
# Updated: 12/3/21

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

# Check and return task status
Function Check-RubrikRequest($req) {
  $reqURL = $req.links.href -split 'api\/[a-z0-9]*\/'
  $req = Invoke-RubrikRESTCall -Method "Get" -Endpoint "$($reqURL[1])"
  return $req
}

# Format a timeSpan object to a string when calculating difference between two times
Function Format-TimeStr($time) {
  $timeStr = ''
  if ($time.Days -gt 0) { $timeStr += "$($time.Days) day(s) " }
  if ($time.Hours -gt 0) { $timeStr += "$($time.Hours) hr " }
  if ($time.Minutes -gt 0) { $timeStr += "$($time.Minutes) min " }
  if ($time.Seconds -gt 0) { $timeStr += "$($time.Seconds) sec " }
  return $timeStr.trim()
}

###### VARIABLES - BEGIN ######

$date = Get-Date

# Provide list of IDs to take an On Demand Snapshot
$objectids = @('Fileset:::e7fe3a06-318d-4db3-9d74-83351b223620','Fileset:::de0ac83d-7a76-4074-84f4-b748eb270f9c','VirtualMachine:::5ed1b046-0bd9-4468-a67c-3293f15f27ed-vm-307203')

# SLA name to use for the On Demand Snapshots
$slaName = 'st-sla'

# Whether to have script check and update progress until all on demand snapshots are completed
$checkProgress = $true
# Number of seconds to wait between each status update
$waitSec = 30

# SMTP configuration
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'

$emailSubject = "Rubrik On Demand Backup Triggered - $server - $($date.ToString("M/d/yyyy HH:mm"))"
$html = "<b>Rubrik On Demand Backup Triggered - $server - $($date.ToString("M/d/yyyy HH:mm"))</b><br><br>"

# Set to $true to send out email in the script
$sendEmail = $false

###### VARIABLES - END #######

###### RUBRIK AUTHENTICATION - BEGIN ######
# First try using API token, then username/password if a user is provided, then credential file
try {
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

$reqList = @()

foreach ($i in $objectids)
{
  try
  {
    if ($i -like 'Fileset*')
    {
      $filesetInfo = Get-RubrikFileset -id $i
      $req = New-RubrikSnapshot -id $i -SLA $slaName -confirm:$false

      $reqList += [PSCustomObject] @{
        id = $i
        hostname = $filesetInfo.hostname
        fileset = $filesetInfo.name
        links = $req.links
        status = $req.status
        progress = ''
        startTime = ''
        endTime = ''
        duration = ''
      }
    $status = "On Demand Snapshot triggered for ID: '$($filesetInfo.id)', host: '$($filesetInfo.hostname)', fileset: '$($filesetInfo.name)'"
    Write-Host $status -ForegroundColor Green
    $html += "$status<br>"
    }
    else
    {
      $req = New-RubrikSnapshot -id $i -SLA $slaName -confirm:$false

      $reqList += [PSCustomObject] @{
        id = $i
        links = $req.links
        status = $req.status
        progress = ''
        startTime = ''
        endTime = ''
        duration = ''
      }
    $status = "On Demand Snapshot triggered for ID: '$($i)'"
    Write-Host $status -ForegroundColor Green
    $html += "$status<br>"
    }
  }
  catch
  {
    $reqList += [PSCustomObject] @{
      id = $i
      status = "ERROR"
    }

    $status = "ERROR triggering On Demand Snapshot for ID: '$i'"
    Write-Host $status -ForegroundColor Red
    $html += "$status<br>$($ERROR[0])<br>"
  }
}

if ($sendEmail)
{
  try {
    Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort
  } catch { $ERROR[0] }
}

if ($checkProgress -eq $true)
{
  do
  {
    $reqState = $false

    foreach($i in $reqList)
    {
      if ($i.links -ne $null) {
        $req = Check-RubrikRequest($i)
        $i.status = $req.status
        $i.progress = $req.progress
        $i.startTime = $req.startTime
        $i.endTime = $req.endTime
        $i.duration = Format-TimeStr($req.endTime - $req.startTime)
      }

      if (@('QUEUED','ACQUIRING','RUNNING','FINISHING','TO_CANCEL') -contains $i.status) {
        $reqState = $true
      }
    }

    $reqList | Format-Table -property 'id', 'status', 'progress', 'hostname', 'fileset'

    if ($reqState) { Start-Sleep -Seconds $waitSec }
    Write-Host $(Get-Date)

  } while ($reqState)

  $emailSubject = "Rubrik On Demand Backup Status - $server - $($date.ToString("M/d/yyyy HH:mm"))"
  $html = "<b>Rubrik On Demand Backup Status - $server - $($date.ToString("M/d/yyyy HH:mm"))</b><br><br>"

  foreach ($i in $reqList)
  {
    $status = "On Demand Snapshot status: '$($i.status)', duration: '$($i.duration)', for ID: '$($i.id)', host: '$($i.hostname)', fileset: '$($i.fileset)', UTC start time: '$($i.startTime)', end time: '$($i.endTime)'"
    $status
    $html += "$status<br>"
  }

  if ($sendEmail)
  {
    try {
      Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort
    } catch { $ERROR[0] }
  }
}  # if $checkProgress -eq $true

$disconnect = Disconnect-Rubrik -Confirm:$false
