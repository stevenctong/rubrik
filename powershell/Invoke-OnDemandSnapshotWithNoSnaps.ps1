#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Trigger on demand snapshots for VMs that don't have an existing snapshot for a given SLA.

.DESCRIPTION
The Invoke-OnDemandSnapshotWithNoSnaps.ps1 triggers on demand snapshots for VMs that don't have an existing snapshot for a given SLA.

On Demand Snapshots need to be associated with a target SLA.
The on demand snapshot will be retained for the longest retention for each local, replication, and archive location as defined in the target SLA.
An on demand snapshot to an archive location starts a new on demand snapshot chain.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 9/24/21

For authentication, use an API token (recommended), username/password, or a credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM section with config details for this script.

.EXAMPLE
./Trigger-OnDemandSnapshotWithNoSnaps.ps1 -server <Rubrik_server> -token <API_token>
Use an API token for authentication.

.EXAMPLE
./Trigger-OnDemandSnapshotWithNoSnaps.ps1 -server <Rubrik_server>
Checks for credential file and if none found prompts for username/password.

.EXAMPLE
./Trigger-OnDemandSnapshotWithNoSnaps.ps1 -server <Rubrik_server> -sourceSLA "Gold" -targetSLA "Silver"
Checks for credential file and if none found prompts for username/password.
Triggers an on demand snapshot for VMs in the Gold SLA that have zero snapshots using the Silver SLA.

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

  # SLA to check VMs that don't have an on demand snapshot
  [Parameter(Mandatory=$false)]
  [string]$sourceSLA = '',

  # Target SLA to use for the On Demand Snapshots
  [Parameter(Mandatory=$false)]
  [string]$targetSLA = ''
)

Import-Module Rubrik


###### RUBRIK AUTHENTICATION - BEGIN ######
# First try using API token, then username/password if a user is provided, then credential file
try {
  if ($token) { Connect-Rubrik -Server $server -Token $token }
  else {
    if ($user) {
      if ($password) {
        [SecureString]$password = ConvertTo-SecureString $password -AsPlainText -Force
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


# Get a list of VMware VMs from the source SLA
$objList = @()
$objList += Get-RubrikVM -SLA $sourceSLA -PrimaryClusterID local

$totalCount = ($objList | Where { $_.Name -ne $null }).count

Write-Host "Total # of objects found in $sourceSLA: $totalCount"

# Build a list of the VMs that have zero snapshots
$snapshotList = @()

# Loop through all the VMs and build a list those that have zero snapshots
foreach ($object in $objList)
{
  # Get the snapshots for a particular VM
  $vmSnapshots = Get-RubrikVM $($object.Name)  | Get-RubrikSnapshot

  # If no snapshots are returned, add it to the snapshot list
  if ($vmSnapshots.id -eq $null) {
    $snapshotList += $object
    Write-Host "Found VM with no snapshots: $($object.Name)"
  }
}

Write-Host "`nTotal # of VMs that needs an immediate snapshot: $($snapshotList.count)`n"

# Take on demand snapshot for each VM that needs it
foreach ($object in $snapshotList) {
  try
  {
    if ($object.Name -ne $null)
    {
      $object | New-RubrikSnapshot -SLA $targetSLA -Confirm:$false
      Write-Host "[$count/$totalCount] Taking snapshot of: $($object.name), $($object.id)"
      $html+="Taking a snapshot of: $($object.name), $($object.id)<br>"
    }
  } catch {
    Write-Error "[$count/$totalCount] Error taking snapshot of: $($object.name), $($object.id)"
    $html+="Error taking snapshot of: $($object.name), $($object.id)<br>"
  }
}
