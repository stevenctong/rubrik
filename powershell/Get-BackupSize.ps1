#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Gets the size of the backup nearest the date provided for VMs and filesets

.DESCRIPTION
The Get-BackupSize script gets the size of backup nearest the date provided for VMs and filesets.
Outputs the list to a CSV file.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 1/23/21

For authentication, use an API token (recommended), username/password, or a credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM section with config details for this script.

.EXAMPLE
./Get-BackupSize.ps1 -server <Rubrik_server> -token <API_token> -snapDate 2020/12/10
Use an API token for authentication
Get backup size of all VMs and filesets nearest 2020/12/10 (yyyy/mm/dd)

.EXAMPLE
./Get-BackupSize.ps1 -server <Rubrik_server> -snapDate 2021/01/05
Checks for credential file and if none found prompts for username/password.
Get backup size of all VMs and filesets nearest 2021/01/05 (yyyy/mm/dd)

#>

param (
  [CmdletBinding()]

  # Rubrik cluster hostname or IP address
  [Parameter(Mandatory=$false)]
  [string]$server = $null,

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

  # Snapshot cloest to date to get backup date on (yyyy/mm/dd)
  [Parameter(Mandatory=$true)]
  [string]$snapDate = ''
)

Import-Module Rubrik

Function Get-ClosestSnapshot([array]$snapshotList, $snapDate)
{
  $compDate = 9999

  foreach ($i in $snapshotList)
  {
    if ([Math]::abs($($i.date-$snapDate).TotalDays) -lt $compDate)
    {
      $snapshot = $i
      $compDate = [Math]::abs($($i.date-$snapDate).TotalDays)
    }
  }
  return $snapshot
}

[DateTime]$snapDate = Get-Date($snapDate)

$snapdateString = $snapDate.ToString("yyyy-MM-dd")
$csvOutput = "./rubrik_backup_sizes_for_snapshot_nearest-$snapdateString.csv"

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
  Write-Error "Error connecting to cluster or with authentication."
  Exit
}
###### RUBRIK AUTHENTICATION - END ######

$objectList = Get-RubrikVM
$objectList += Get-RubrikFileset

$snapshotList = @()

foreach ($i in $objectList)
{
  if ($i.id -like 'VirtualMachine*')
  {
    $objectInfo = Get-RubrikVM -id $i.id
    $location = $objectInfo.vcenterName
    $type = 'vSphere VM'
    $logicalSizeGB = $($objectInfo.logicalSize/1000000000)
  }
  elseif ($i.id -like 'Fileset*')
  {
    $objectInfo = Get-RubrikFileset -id $i.id
    $location = $objectInfo.hostName
    $logicalSizeGB = $($objectInfo.localStorage/1000000000)

    if ($objectInfo.operatingSystemType -like 'UnixLike') {
      $type = 'Linux & Unix Fileset'
    }
    elseif ($objectInfo.operatingSystemType -like 'Windows') {
      $type = 'Windows Fileset'
    }
    else {
      $type = 'NAS Fileset'
    }
  }

  if ($objectInfo.snapshotCount -gt 0)
  {
    $snapshot = Get-ClosestSnapshot $objectInfo.snapshots $snapDate

    $snapshotDetail = [PSCustomObject]@{
      Name = $objectInfo.name
      Location = $location
      CalculatedName = $objectInfo.Name + '+' + $location
      Type = $type
      SLA = $objectInfo.effectiveSlaDomainName
      logicalSizeGB = $logicalSizeGB
      snapshotID = $snapshot.id
      snapshotDate = $snapshot.date
    }

    $snapshotDetail

    $snapshotList += $snapshotDetail
  }
}

foreach ($i in $snapshotList)
{
  try
  {
    $backupData = Invoke-RubrikRESTCall -Method GET -Api 'internal' -Endpoint "browse?snapshot_id=$($i.snapshotID)&path=/"

    $backupData.data

    $backupSizeGB = 0

    foreach ($j in $backupData.data)
    {
      $backupSizeGB += $j.size/1000000000
    }

    $i | Add-Member -MemberType NoteProperty -Name "backupSizeGB" -Value $backupSizeGB

  }
  catch {
    $backupSizeGB = "Error Calculating"
    $i | Add-Member -MemberType NoteProperty -Name "backupSizeGB" -Value $backupSizeGB
  }
  $i
}

$snapshotList | Export-Csv -NoTypeInformation -Path $csvOutput

Disconnect-Rubrik -Confirm:$false
