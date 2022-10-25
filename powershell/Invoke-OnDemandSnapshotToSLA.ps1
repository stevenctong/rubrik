#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#

.SYNOPSIS

This PowerShell script will perform on demand snapshots of objects in one SLA to
another SLA.

.DESCRIPTION

This PowerShell script will perform on demand snapshots of objects in one SLA to
another SLA. The intent is to archive snapshots on a periodic basis such as
Monthly or Yearly using a scheduler.

This script works by specifying source SLA(s) with a unique string containing the
objects that you want to archive. The script will query those SLA(s) and build
a list of objects then take an on demand backup of each object.

The target SLA should be defined with the overall retention that you desire,
local retention set to '0', instant archive enabled, and the archive and/or
replication locations that you want to send the backups to.

Scheduling of the snapshots is done using a job scheduler such as Windows
task scheduler to invoke this script at desired interverals. For example,
if you want monthly snapshots, you would have a task to execute the script
every month.

.NOTES
Original script by: @clumnah
Updated by Steven Tong for community usage
GitHub: stevenctong
Date: 4/18/21

For authentication, use an API token (recommended), username/password, or a credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM section with config details for this script or pass when running.

.EXAMPLE
.\Invoke-OnDemandSnapshotsToSLA.ps1 -server <Rubrik_server> -token <API_token> -sourceSLAstring toAzure -targetSLAname Monthlies-Azure
Takes an on demand snapshot of all objects in SLA(s) containing 'toAzure' in the name to target SLA 'Monthlies-Azure'

.NOTES

#>

param (
  [CmdletBinding()]

  # Rubrik cluster hostname or IP address
  [Parameter(Mandatory=$false)]
  [string]$server = 'amer1-rbk01.rubrikdemo.com',

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

  # Source SLA string - takes an on demand snapshot for objects in SLAs that contain this string
  [Parameter(Mandatory=$false)]
  [string]$sourceSLAstring = '',

  # Source SLA array - takes an on demand snapshot for objects in SLAs that contain this string
  [Parameter(Mandatory=$false)]
  [array]$sourceSLAname = @(''),

  # Target SLA name - on demand snapshot is taken to this SLA
  [Parameter(Mandatory=$false)]
  [string]$targetSLAname = ''
)

Import-Module Rubrik

$date = Get-Date

# SMTP configuration
$emailTo = @('')
$emailFrom = ''
$SMTPServer = ''
$SMTPPort = '25'

$emailSubject = "Rubrik ($server) - Triggering On Demand Backups to SLA $slaTargetName" + $date.ToString("yyyy-MM-dd HH:MM")
$html = "<b><Rubrik cluster: $server/b><br>Date: $date<br>Source SLA string: $sourceSLAstring<br>Target SLA name: $targetSLAname<br><br>"

# Set to $true to send out email in the script
$sendEmail = $false


###### RUBRIK AUTHENTICATION - BEGIN ######
# First try using API token, then username/password if a user is provided, then credential file
try {
  if (!$server) { $server = Read-Host "Rubrik hostname or IP" }
  if ($token) { Connect-Rubrik -Server $server -Token $token }
  else {
    if ($user) {
      if ($password) {
        [SecureString]$password = ConvertTo-SecureString -String $password -AsPlainText -Force
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

# Get a list of all SLAs in Rubrik
$slaCluster = Get-RubrikSLA -PrimaryClusterID local | Sort-Object 'Name'
$slaList = @()

# Filter SLAs by those with the source SLA string we're looking for
foreach ($sla in $slaCluster) {
  if ($sla.name -match $sourceSLAstring) {
    $sla.name
    $slaList += $sla.name
  }
}

# List containing the objects that we want to take an on demand snapshot of
$objList = @()

Write-Host "`nBuilding list of objects from source SLAs with string: `"$sourceSLAstring`"`n" -foregroundcolor green

# For each SLA we found, get all objects of each type for that SLA to build the list of objects
foreach ($sla in $slaList) {

  Write-Host "Getting objects for SLA: `"$sla`"" -foregroundcolor green

  Write-Host ".....Getting VMware VMs"
  $objList += Get-RubrikVM -SLA $sla -PrimaryClusterID local

  Write-Host ".....Getting HyperV VMs"
  $objList += Get-RubrikHyperVVM -SLA $sla -PrimaryClusterID local

  Write-Host ".....Getting AHV VMs"
  $objList += Get-RubrikNutanixVM -SLA $sla -PrimaryClusterID local

  Write-Host ".....Getting Filesets that are not Passthrough"
  $objList += (Get-RubrikFileset -SLA $sla -PrimaryClusterID local | Where-Object {$_.isPassthrough -eq $false})

  Write-Host ".....Getting SQL Server Databases"
  $objList += Get-RubrikDatabase -SLA $sla -PrimaryClusterID local

  Write-Host ".....Getting Oracle Databases"
  $objList += Get-RubrikOracleDB -SLA $sla -PrimaryClusterID local

  Write-Host ".....Getting Volume Groups"
  $objList += Get-RubrikVolumeGroup -SLA $sla -PrimaryClusterID local
}

$totalCount = ($objList | Where { $_.Name -ne $null }).count

# Maintains a count of the current object that we will be taking a snapshot of, up to $totalCount
$count = 1

Write-Host "`nTotal objects found: $count`n" -foregroundcolor green

# Take on demand snapshot for each object
foreach ($object in $objList) {
  try
  {
    if ($object.Name -ne $null)
    {
      $object | New-RubrikSnapshot -SLA $targetSLAname -Confirm:$false
      Write-Host "[$count/$totalCount] Taking snapshot of: $($object.name), $($object.id)"
      $html+="Taking a snapshot of: $($object.name), $($object.id)<br>"
      $count += 1
    }
  } catch {
    Write-Error "[$count/$totalCount] Error taking snapshot of: $($object.name), $($object.id)"
    $html+="Error taking snapshot of: $($object.name), $($object.id)<br>"
    $count += 1
  }
}

# Send an email
if ($sendEmail)
{
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort
}
