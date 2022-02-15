#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#

.SYNOPSIS

This PowerShell script will perform on demand snapshots of objects from a
list of VMware VMs in a CSV file to in a CSV to a target SLA.

.DESCRIPTION

This PowerShell script will perform on demand snapshots of objects from a
list of VMware VMs in a CSV file to in a CSV to a target SLA.  The intent is to
archive snapshots on a periodic basis such as Monthly or Yearly using a scheduler.

This script works by specifying source CSV file containing a list of VMware
VMs. The script will iterate through the list and attempt to perform an
On Demand Snapshot to a target SLA for each VM.

The target SLA should be defined with the overall retention that you desire,
local retention set to '0', instant archive enabled, and the archive and/or
replication locations that you want to send the backups to.

Scheduling of the snapshots is done using a job scheduler such as Windows
task scheduler to invoke this script at desired interverals. For example,
if you want monthly snapshots, you would have a task to execute the script
every month.

.NOTES
Updated by Steven Tong for community usage
GitHub: stevenctong
Date: 2/14/22

For authentication, use an API token (recommended), username/password, or a credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM section with config details for this script or pass when running.

.EXAMPLE
.\Invoke-OnDemandSnapshotsFromCSV.ps1 -server <Rubrik_server> -token <API_token> -csvFile './rubrik_on_demand_vms.csv' -targetSLAname 'Monthlies-Azure'
Takes an on demand snapshot of all objects in the CSV file './rubrik_on_demand_vms.csv' in the name to target SLA 'Monthlies-Azure'

.NOTES

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

  # Input CSV file containing a list of VMware VMs
  [Parameter(Mandatory=$false)]
  [string]$csvFile = '',

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

$vmList = Import-CSV $csvFile -header "Name"

# List containing the objects that we want to take an on demand snapshot of
$objList = @()

foreach ($vm in $vmList.Name)
{
  # Get the VM details for each VM
  $obj = Get-RubrikVM -name $vm -PrimaryClusterID local

  # If no VM is found then write out an error
  if ($obj -eq $null) {
    Write-Error "No VM found named: $vm"
    $html+="No VM found named: $vm"
  }

  $objList += Get-RubrikVM -name $vm -PrimaryClusterID local
}

$totalCount = ($objList | Where { $_.Name -ne $null }).count

# Maintains a count of the current object that we will be taking a snapshot of, up to $totalCount
$count = 1

Write-Host "`nTotal objects found: $totalCount`n" -foregroundcolor green

# Take on demand snapshot for each object
foreach ($object in $objList) {
  try
  {
    if ($object.Name -ne $null)
    {
      $object | New-RubrikSnapshot -SLA $targetSLAname -Confirm:$false
      Write-Host "[$count/$totalCount] Taking snapshot of: $($object.name), $($object.id)" -foregroundcolor Green
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
