#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Grabs the file system size for each VM and calculates the diff between Used and File System size.

.DESCRIPTION
The Calc-BackupDiff script grabs the file system size for each VM and calculates the diff between Used and File System size.
Outputs the list to a CSV file with these included columns:

- 'LogicalSizeGB' - The logical / provisioned size of the VM
- 'FileSystemSizeGB' - The size of all files/folders seen on the VM file system
- 'UsedSizeGB' - The amount of storage used on Rubrik
- 'UsedMinusFileSystem' - The difference between the Rubrik used size and file system size
- 'UsedToFSRatio' - The Rubrik size divided by the file system size

If the 'UsedToFSRatio' is very high, it means that Rubrik is storing a lot of data
but there may not actually be that much capacity on the file system.
This could be because of dirty blocks that VMware is marking as used.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 3/22/22
Modified: 4/8/22

Requires Powershell version 7+.

For authentication, use an API token (recommended), username/password, or a credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM section with config details for this script.

.EXAMPLE
./Calc-BackupDiff.ps1 -server <Rubrik_server> -token <API_token>
Use an API token for authentication

.EXAMPLE
./Calc-BackupDiff.ps1 -server <Rubrik_server>
Checks for credential file and if none found prompts for username/password.

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
  [string]$rubrikCred = 'rubrik_cred.xml'
)

Import-Module Rubrik

$date = Get-Date

# Number of parallel theads to use
$threads = 32

# Use snapshot from two days ago to give more time for index to complete
$snapDate = (Get-Date -AsUTC).AddHours(-96)

# CSV filename to output the report to
$snapdateString = $snapDate.ToString("yyyy-MM-dd")
$csvOutput = "./rubrik_vm_size_calculations-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

# Report created on Rubrik cluster for "System Capacity"
$rubrikSysCapReportName = "System Capacity"
# $rubrikSysCapReportName = "Custom - System Capacity"

# Requires PS version 7+
if ($PSVersionTable.PSVersion.Major -lt 7) {
  Write-Error "Script requires PS version 7+. Exiting."
  exit
}

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

# Get CSV link for System Capacity report
$reportLink = Get-RubrikReport -Name $rubrikSysCapReportName | Export-RubrikReport

# Download the System Capacity report
$capacityReport = Invoke-WebRequest -Uri $reportLink[0] -SkipCertificateCheck

# Format the report as a PS Table
$report = $capacityReport.content | ConvertFrom-CSV

# Get a list of all VMs that have a SLA assignment
$objectList = Get-RubrikVM -SLAAssignment Direct
$objectList += Get-RubrikVM -SLAAssignment Derived

# Get info for each VM and the snapshot ID nearest $snapDate
$snapshotList = $objectList | ForEach-Object -throttlelimit $threads -parallel {
  # Function Get-ClosestSnapshot finds the snapshot ID nearest a date
  Function Get-ClosestSnapshot([array]$snapshotList, $snapDate)
  {
    $compDate = 9999
    foreach ($i in $snapshotList)
    {
      $dateUTC = $(Get-Date $($i.date)).ToUniversalTime()
      if ([Math]::abs($($dateUTC-$snapDate).TotalDays) -lt $compDate)
      {
        $snapshot = $i
        $compDate = [Math]::abs($($dateUTC-$snapDate).TotalDays)
      }
    }
    return $snapshot
  }
  $rubrikConnection = $using:rubrikConnection
  $objectInfo = Get-RubrikVM -id $_.id
  $location = $objectInfo.vcenterName
  $type = 'vSphere VM'
  $logicalSizeGB = $($objectInfo.logicalSize/1000000000)
  # For each object, find the snapshot nearest the date given in order to pull size info
  if ($objectInfo.snapshotCount -gt 0)
  {
    $snapshot = Get-ClosestSnapshot $objectInfo.snapshots $using:snapDate
    $snapshotDetail = [PSCustomObject]@{
      Name = $objectInfo.name
      Location = $location
      CalculatedName = $objectInfo.Name + '+' + $location
      Type = $type
      SLA = $objectInfo.effectiveSlaDomainName
      SnapshotID = $snapshot.id
      SnapshotDateUTC = $snapshot.date
      LogicalSizeGB = $logicalSizeGB
    }
    $snapshotDetail
  }
}

$comparisonList = $snapshotList | ForEach-Object -throttlelimit 32 -parallel {
  $rubrikConnection = $using:rubrikConnection
  try
  {
    $objInfo = $_
    $backupData = Invoke-RubrikRESTCall -Method GET -Api 'internal' -Endpoint "browse?snapshot_id=$($objInfo.snapshotID)&path=/"
    $fileSystemSizeGB = 0
    foreach ($j in $backupData.data)
    {
      $fileSystemSizeGB += $j.size/1000000000
    }
    $objInfo | Add-Member -MemberType NoteProperty -Name "FileSystemSizeGB" -Value $fileSystemSizeGB
    $reportObject = $using:report |  where { $_.'object name' -eq $objInfo.name }
    $usedCapacityGB = $reportObject.'Local Storage (B)'/1000000000
    $objInfo | Add-Member -MemberType NoteProperty -Name "UsedSizeGB" -Value $usedCapacityGB
    $objInfo | Add-Member -MemberType NoteProperty -Name "UsedMinusFileSystem" -Value $($usedCapacityGB - $fileSystemSizeGB)
    $objInfo | Add-Member -MemberType NoteProperty -Name "UsedToFSRatio" -Value $($usedCapacityGB / $fileSystemSizeGB)
  }
  catch {
    $fileSystemSizeGB = "Error Calculating"
    $objInfo | Add-Member -MemberType NoteProperty -Name "backupSizeGB" -Value $fileSystemSizeGB
  }
  $objInfo
}

Disconnect-Rubrik -Confirm:$false

$comparisonList | Sort-Object -Property 'UsedToFSRatio' -Desc | Export-Csv -NoTypeInformation -Path $csvOutput
