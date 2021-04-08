#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS


# 35bf6eb6-8832-4467-8067-f118d1b78d66
# aea01930-a01f-444c-a8e0-44e7dcf6e555

.DESCRIPTION


.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 4/7/23

For authentication, use an API token (recommended), username/password, or a credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM section with config details for this script.

.EXAMPLE
./

.EXAMPLE
./

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

  # Hyper-V VM name to get the list of all files for
  [Parameter(Mandatory=$false)]
  [string]$hypervvm = '',

  # Closest date (UTC) to get backup size for, use (yyyy/mm/dd) format
  [Parameter(Mandatory=$true)]
  [string]$snapDate = '',

  # Path to start the list from
  [Parameter(Mandatory=$false)]
  [string]$startPath = '',
)

Import-Module Rubrik

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

Function Get-FilesInPath($snapshot, $path, $csvOutput)
{
  Write-Host "$snapshot $path"

  try
  {
    $files = Invoke-RubrikRESTCall -Method GET -Api "internal" -Endpoint "browse?snapshot_id=$snapshot&path=$path"

    foreach ($i in $files.data)
    {
      $i | Add-Member -MemberType NoteProperty -Name "fullPath" -Value $path
      $i | Add-Member -MemberType NoteProperty -Name "fullFilename" -Value "$path/$($i.filename)"
      $i | Export-Csv -NoTypeInformation -Path $csvOutput -Append

      if ( ($i.fileMode -eq "drive") -or ($i.fileMode -eq 'directory') )
      {
        Get-FilesInPath $snapshot "$path/$($i.path)" $csvOutput
      }
    }
  } catch {
    Write-Error "Error on path: $path"
  }
  return
}

[DateTime]$snapDate = Get-Date($snapDate)

$snapdateString = $snapDate.ToString("yyyy-MM-dd")
$csvOutput = "./rubrik_filelist-$($hypervvm)-snapshot_nearest_$snapdateString.csv"

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


$hvvm = Get-RubrikHyperVVM -name $hypervvm

if ($hvvm.count -lt 1) {
  Write-Error "No Hyper-V VM found with name: $hypervvm"
  exit 1
}

$snapshotList = Invoke-RubrikRESTCall -Method GET -Api "internal" -Endpoint "hyperv/vm/$($hvvm.id)/snapshot"

$snapshot = Get-ClosestSnapshot $snapshotList.data $snapDate

$files = Invoke-RubrikRESTCall -Method GET -Api "internal" -Endpoint "browse?snapshot_id=$($snapshot.id)&path=$path"

Get-FilesInPath $snapshot.id $startPath $csvOutput

Disconnect-Rubrik -Confirm:$false
