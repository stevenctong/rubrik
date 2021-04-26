#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Searches the latest snapshot of all VMs or Filesets for a filename and outputs to a CSV file.

.DESCRIPTION
The Search-for-File script searches for a filename across all VMs and filesets from the latest snapshot.
The filename can be a partial match.
Outputs the details to a CSV file.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 3/10/21

For authentication, use an API token (recommended), username/password, or a credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM and VARIABLES section with config details for this script.

.EXAMPLE
./Search-for-File.ps1 -filename 'bak' -server <Rubrik_server> -token <API_token>
Use an API token for authentication.
Search for any file with 'bak' in the name.

.EXAMPLE
./Search-for-File.ps1 -filename '*.pdf' -limit 50 -server <Rubrik_server>
Checks for credential file and if none found prompts for username/password.
Search for any file ending with extension '.pdf'.
Limit result per object to 50.

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

  # Filename string to search for
  [Parameter(Mandatory=$false)]
  [string]$filename = '',

  # Limit the number of search results per object to #
  [Parameter(Mandatory=$false)]
  [string]$limit = 200,

  # Minimum size of files in GB to add to the result list
  [Parameter(Mandatory=$false)]
  [int]$minSize = 1,

  # Which number in the snpshot array to continue processing from
  [Parameter(Mandatory=$false)]
  [int]$startNum = 1,

  # List of VMware VMs to search on
  [Parameter(Mandatory=$false)]
  [string]$vmlist = ''
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

###### VARIABLES - BEGIN ######

$date = Get-Date
$snapDate = $date.ToUniversalTime()

# Import a CSV generated from step 1 (snapshoot list) to search against
$importSnapshotCSV = ''

# CSV for object list (step 1)
$csvSnapshotList = "./rubrik_$($server)-snapshot_list.csv"

# CSV for search results
$csvOutput = "./rubrik_$($server)-search_results-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

###### VARIABLES - END #######

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
  try {
    Write-Error "Error connecting to cluster or with authentication."
    $html = "Error connecting to cluster or with authentication."
    if ($sendEmail) { Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $html -SmtpServer $SMTPServer -Port $SMTPPort }
    Exit 1
  } catch { Exit 1 }
}
###### RUBRIK AUTHENTICATION - END ######

$objectList = @()

if ($importSnapshotCSV -eq '')
{
  if ($vmlist -eq '')
  {
    $objectList = Get-RubrikVM
    $objectList += Get-RubrikFileset
  } else
  {
    $vmlist.split(",") | foreach {
      $vm = Get-RubrikVM -name $_
      if ($vm -ne $null) { $objectList += Get-RubrikVM -name $_ }
    }
  }

  # For each object, choose the one snapshot closest to $snapDate and add to $snapshotList
  $snapshotList = @()

  $objectNum = 1

  foreach ($i in $objectList)
  {
    Write-Host "[$objectNum/$($objectList.count)] Building snapshot list for object: $($i.name) (step 1 of 2): " -foregroundcolor green
    $objectNum += 1

    if ($i.id -like 'VirtualMachine*')
    {
      $objectInfo = Get-RubrikVM -id $i.id
      $location = $objectInfo.vcenterName
      $type = 'vSphere VM'
      $os = $objectInfo.guestOsType
    }
    elseif ($i.id -like 'Fileset*')
    {
      $objectInfo = Get-RubrikFileset -id $i.id
      $location = $objectInfo.hostName

      if ($objectInfo.operatingSystemType -like 'UnixLike') {
        $type = 'Linux & Unix Fileset'
        $os = 'Linux & Unix'
      }
      elseif ($objectInfo.operatingSystemType -like 'Windows') {
        $type = 'Windows Fileset'
        $os = 'Windows'
      }
      else {
        $type = 'NAS Fileset'
        $os = 'NAS'
      }
    }

    # For each object, find the snapshot nearest the date given in order to pull size info
    if ($objectInfo.snapshotCount -gt 0)
    {
      $snapshot = Get-ClosestSnapshot $objectInfo.snapshots $snapDate

      $snapshotDetail = [PSCustomObject]@{
        Name = $objectInfo.name
        Location = $location
        OS = $os
        CalculatedName = $objectInfo.Name + '+' + $location
        Type = $type
        snapshotID = $snapshot.id
        snapshotDateUTC = $snapshot.date
      }

      $snapshotList += $snapshotDetail
    }
  } # foreach ($i in $objectList)

  # Export out snapshot list (step 1)
  $snapshotList | Export-Csv -NoTypeInformation -Path $csvSnapshotList
} else {
  $snapshotList = Import-Csv -Path $importSnapshotCSV
}

# Build list of each search hit and which object + snapshot it belongs to
$resultList = @()

$snapshotNum = 1

# Iterate through each snapshot and search for $filename
foreach ($i in $snapshotList)
{
  # Try to get search results only if the current $snapshotNum >= $startNum
  if ($snapshotNum -ge $startNum)
  {
    Write-Host "[$snapshotNum/$($snapshotList.count)] Searching on object: $($i.name), $($i.location) (step 2 of 2)" -foregroundcolor green
    try
    {
      # Search for the filename in each snapshot
      $searchResult = Invoke-RubrikRESTCall -Method GET -Api 'internal' -Endpoint "search/snapshot_search?limit=$($limit)&snapshot_id=$($i.snapshotID)&name=$($filename)&dir=/" -verbose

      $searchResult.data
      Write-Host "Total files found in $($i.name), $($i.location): $($searchResult.data.count)" -foregroundcolor green

      foreach ($j in $searchResult.data)
      {
        # # Store result if it is > $minSize (size in GB)
        if ($j.size -gt $($minSize*1000000000))
        {
          $resultDetail = [PSCustomObject]@{
            Name = $i.name
            Location = $i.location
            Type = $i.type
            OS = $i.os
            Dir = $j.dir
            Filename = $j.filename
            Size = $j.size
            SizeGB = $($j.size/1000000000)
            lastModified = $j.lastModified
            snapshotID = $i.snapshotID
            snapshotDateUTC = $i.snapshotDateUTC
            snapshotNum = $snapshotNum
          }

          $resultDetail | Export-Csv -NoTypeInformation -Path $csvOutput -Append

          $resultList += $resultDetail
        }
      } # foreach in $searchResult

    }
    catch {
      Write-Error "Error searching on object: $($i.name)"
    }
  } else {
    Write-Host "Skipping search on object # (step 2 of 2): $snapshotNum of $($snapshotList.count), start #: $startNum" -foregroundcolor yellow
  }

  $snapshotNum += 1
} # foreach ($i in $snapshotList)

# $resultList | Export-Csv -NoTypeInformation -Path $csvOutput

Disconnect-Rubrik -Confirm:$false
