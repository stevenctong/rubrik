#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Generates a filterable list of objects and snapshots under Snapshot Management and assists with deletion.
Have the script delete the snapshots or export the snapshots to a CSV file that you can edit and re-import for deletion.

.DESCRIPTION
The Get-Delete-SnapshotManagement.ps1 script generates a list of objects and snapshots under Snapshot Management.
The list can be filtered by snapshots older than a certain date, object type, or object status.
The list will be exported to a CSV file.
You can have the script delete the snapshots by setting $delete to $true.
Or you can edit the CSV to contain the snapshots you want deleted and have the script read the CSV file and delete those snapshots.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 12/20/20

For authentication, use an API token (recommended), username/password, or credential file.

To create a credential file (note: only the user who creates it can use it):
- Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

Fill out the PARAM and VARIABLES section with config details for this script.

.EXAMPLE
./Get-Delete-SnapshotManagement.ps1 -server <Rubrik_server> -token <API_token>
Use an API token for authentication.
Generates a list of snapshots based on the config in the VARIABLES section and export the list to a CSV file.

.EXAMPLE
./Get-Delete-SnapshotManagement.ps1 -server <Rubrik_server> -delete $true
Checks for credential file and if none found prompts for username/password.
Generates a list of snapshots based on the config in the VARIABLES section, deletes the snapshots, and exports the list to a CSV file.

.EXAMPLE
./Get-Delete-SnapshotManagement.ps1 -server <Rubrik_server> -csvDelete './rubrik_snapshot_list-2020-12-01_2220.csv'
Reads in the file './rubrik_snapshot_list-2020-12-01_2220.csv' and deletes the snapshots in there.

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

  # Set to true to also delete the snapshots that are found
  [Parameter(Mandatory=$false)]
  [string]$delete = $false,

  # CSV file with snapshots to delete
  [Parameter(Mandatory=$false)]
  [string]$csvDelete = ''
)

###### VARIABLES - BEGIN #######

# Depending on cluster version, set to either '1' or 'internal'
# Use '1' for later cluster versions (v5.1+)
$apiVer = 'internal'

# Get snapshots before this date. Set to '' if you want all snapshots without filtering by date.
$beforeDate = (Get-Date -Year 2020 -Month 09 -Day 01)
# $beforeDate = ''    # Set to '' if you want all snapshots

# Object Type to filter by:
# VirtualMachine, MssqlDatabase, LinuxFileset, WindowsFileset, ShareFileset, NutanixVirtualMachine,
# HypervVirtualMachine, ManagedVolume, Ec2Instance, StorageArrayVolumeGroup, VcdVapp, LinuxHost,
# WindowsHost, OracleDatabase, VolumeGroup, AppBlueprint
$objectType = ''

# Object Status to filter by:
# Protected, Relic, Unprotected, ReplicatedRelic, RemoteUnprotected
$objectStatus = ''

# CSV file info
$date = Get-Date
$csvFile = "./rubrik_snapshot_list-$($date.ToString("yyyy-MM-dd_HHmm")).csv"

###### VARIABLES - END #######

Import-Module Rubrik

# Rubrik authentication - first try using API token, then username/password if a user is provided, then credential file
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
  Write-Error "Error connecting to cluster or with authentication."
  Exit
}

# If no CSV is provided to identify snapshots for deletion, generate a list based on the filters specified
if ($csvDelete -eq '')
{
  # Get all objects under Snapshot Management (On Demands, Relics, Unmanaged Objects)
  $allSnapshotManagement = Get-RubrikUnmanagedObject

  # $snapshostList contains list of snapshots based on the filters
  $snapshotList = @()

  # Iterate through each object in Snapshot Management
  foreach ($i in $allSnapshotManagement) {
    # Process objects that match the object type or status filter
    if (($objectType -eq '' -or $i.objectType -like $objectType) -and
        ($objectStatus -eq '' -or $i.unmanagedStatus -like $objectStatus)) {

      # Get all snapshots for the object
      $objectSnapshots = Invoke-RubrikRESTCall -Method GET -Api $apiVer -Endpoint "unmanaged_object/$($i.id)/snapshot"

      # Iterate through each all the snapshots and filter for snapshots older than $beforeDate
      foreach ($j in $objectSnapshots.data) {
        if ($beforedate -eq '' -or [DateTime]($j.date) -le $beforeDate)
        {
          $newObj = New-Object PSCustomObject

          # Object properties
          $newObj | Add-Member -MemberType NoteProperty -Name "objectName" -Value $i.name
          $objLoc = $i.physicalLocation.name -join ","
          $newObj | Add-Member -MemberType NoteProperty -Name "objectLocation" -Value $objLoc
          $newObj | Add-Member -MemberType NoteProperty -Name "objectType" -Value $i.objectType
          $newObj | Add-Member -MemberType NoteProperty -Name "objectUnmanagedStatus" -Value $i.unmanagedStatus
          $newObj | Add-Member -MemberType NoteProperty -Name "objectRetentionSlaDomainName" -Value $i.retentionSlaDomainName
          $newObj | Add-Member -MemberType NoteProperty -Name "objectTotalLocalStorage" -Value $i.localStorage
          $newObj | Add-Member -MemberType NoteProperty -Name "objectTotalArchiveStorage" -Value $i.archiveStorage
          $newObj | Add-Member -MemberType NoteProperty -Name "objectID" -Value $i.id

          # Snapshot properties
          $newObj | Add-Member -MemberType NoteProperty -Name "snapshotID" -Value $j.id
          $newObj | Add-Member -MemberType NoteProperty -Name "snapshotDate" -Value $j.date

          # If using API version 'internal', get these additional properties
          if ($apiVer -like 'internal')
          {
            $newObj | Add-Member -MemberType NoteProperty -Name "snapshotType" -Value $j.unmanagedSnapshotType
            $newObj | Add-Member -MemberType NoteProperty -Name "snapshotRetentionSlaDomainName" -Value $j.retentionSlaDomainName
          }

          # If using API version 'v1', get these additional properties
          if ($apiVer -like '1')
          {
            $newObj | Add-Member -MemberType NoteProperty -Name "snapshotType" -Value $j.snapshotType
            $newObj | Add-Member -MemberType NoteProperty -Name "snapshotLocalFrequency" -Value $j.snapshotRetentionInfo.localInfo.snapshotFrequency
            $newObj | Add-Member -MemberType NoteProperty -Name "snapshotLocalExpiration" -Value $j.snapshotRetentionInfo.localInfo.expirationTime
            $newObj | Add-Member -MemberType NoteProperty -Name "snapshotArchiveFrequency" -Value $j.snapshotRetentionInfo.archivalInfos.snapshotFrequency
            $newObj | Add-Member -MemberType NoteProperty -Name "snapshotArchiveExpiration" -Value $j.snapshotRetentionInfo.archivalInfos.expirationTime
            $newObj | Add-Member -MemberType NoteProperty -Name "snapshotReplicationFrequency" -Value $j.snapshotRetentionInfo.replicationInfos.snapshotFrequency
            $newObj | Add-Member -MemberType NoteProperty -Name "snapshotReplicationExpiration" -Value $j.snapshotRetentionInfo.replicationInfos.expirationTime
          }

          $newObj

          $snapshotList += $NewObj
         }  # if older than $beforeDate
      }  # foreach in snapshot list
    }  # if matches object filters
  }  # foreach in $allSnapshotManagement

  # Sort and export the $snapshostList
  $snapshotList = $snapshotList | Sort-Object -Property 'objectName, objectID'
  $snapshotList | Export-Csv -NoTypeInformation -Path $csvFile
  Write-Host "`nResults output to: $csvFile"
}
# Else if a CSV is provided, read the CSV to generate the object list for deletion, and delete
else
{
  $snapshotList = Import-CSV $csvDelete
  $snapshotList = $snapshotList | Sort-Object -Property 'objectName, objectID'

  $delete = $true
}

# If $delete -eq $true then try to delete all the snapshots in $snapshostList immediately
if ($delete -eq $true)
{
  # $currentObject is the current object that is being processed
  $currentObject = ''

  # $deleteArray is the an array of snapshot IDs to delete for an identical object
  $deleteArray = @()

  # Iterate through $snapshotList which contains the filtered snapshot IDs
  foreach ($i in $snapshotList) {
    # If processing a new object ID then delete the previous object's snapshots and start processing current one
    if ($currentObject -ne '' -and $currentObject -notlike $i.objectID) {

      Write-Host "Deleting object: $currentObject, snapshots $deleteArray" -ForegroundColor Green

      $body = [PSCustomObject] @{
        snapshotIds=$deleteArray
      }

      try {
        Invoke-RubrikRESTCall -Method POST -Api $apiVer -Endpoint "unmanaged_object/$($currentObject)/snapshot/bulk_delete" -Body $body
      } catch {
        Write-Host "Error deleting object $currentObject, snapshots $deleteArray" -ForegroundColor Red
      }

      $currentObject = $i.objectID
      $deleteArray = @($i.snapshotID)
    }
    # Else if the current object ID is the same, add the current object's snapshot IDs to the list for deletion
    else
    {
      $currentObject = $i.objectID
      $deleteArray += @($i.snapshotID)
    }
  }  # foreach in $allSnapshotManagement

  # Delete the last processed object and associated snapshots
  Write-Host "Deleting object: $currentObject, snapshots $deleteArray" -ForegroundColor Green

  $body = [PSCustomObject] @{
    snapshotIds=$deleteArray
  }

  try {
    Invoke-RubrikRESTCall -Method POST -Api $apiVer -Endpoint "unmanaged_object/$($currentObject)/snapshot/bulk_delete" -Body $body
  } catch {
    Write-Host "Error deleting object $currentObject, snapshots $deleteArray "
  }
}  # if $delete is $true

Disconnect-Rubrik -Confirm:$false
