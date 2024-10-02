# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will create a snapshot and disk clone for Epic IRIS ODB backups
in Azure for v2 / Ultra SSDs.

.DESCRIPTION
This script will create a snapshot and disk clone for Epic IRIS ODB backups
in Azure for v2 / Ultra SSDs.

This script works with the following config file:
- rubrik_az_config_rubrik.yml

The only config values contained in this script file are:
1) Log file path and filenames
2) IRIS ODB freeze / thaw commands

The script supports creating the snapshots from a Prod VM in one subscription
and creating the clone of the disks to a Proxy VM in another subscription.

For v2 / Ultra disks, the performance config depends on disk size. The script has
some error handling to check for a valid config and sets it to the max value
if the disk config throws an error.

The script performs the following tasks:

1. SSH to PROD VM - Freeze IRIS ODB
   ** ssh <user>@<iris_host> 'sudo <instafreeze>'
   ** Also sends command via sleep to automatically 'instathaw' after x minutes
2. Azure - Create v2/Ultra SSD snapshot
3. SSH to PROD VM - Thaw IRIS ODB
   ** ssh <user>@<iris_host> 'sudo <instathaw>'
4. Azure - Check and waits for the snapshot background copy to complete
5. Azure - Creates new Managed Disks from the snapshots for the Proxy VM
6. Azure - Check and waits for the Managed Disk background copy to complete
7. Proxy VM - Prep the VM for the refreshed Managed Disks
   ** unmount <mount_points>
   ** vgchange -an <volume_groups>
8. Azure - Find Managed Disks with 'rubrik' on the Proxy VM and detaches & deletes them
9. Azure - Mounts the newly cloned Managed Disk onto theProxy VM
10. Proxy VM - Re-Mount the refreshed Managed Disk
   ** vgchange -ay <volume_groups
   ** mount <using dev mapper>
11. Rubrik backup begins

The snapshot and the cloned Managed Disks wil be the same name as the source disk
but appended with a 'suffix' and datestamped.

.NOTES
Written by Steven Tong for usage with Rubrik
GitHub: stevenctong
Date: 8/30/24
Updated: 9/27/24

PRE-REQUISITES:
1. IRIS PROD VM has the Proxy VM keys as 'authorized_keys' for SSH commands
2. Mount points created on the Proxy VM - we will use dev-mapper to mount
3. Proxy VM is built with option to "Support Premium SSDs" and also placed
   in a specific Availability Zone that supports v2 / Ultra disks
4. Azure authentication - the script will run from the Proxy VM. The Proxy VM
   should have Managed Identity enabled and a role attached with the following
   permissions:

  "actions": [
    "Microsoft.Compute/snapshots/read",
    "Microsoft.Compute/snapshots/write",
    "Microsoft.Compute/snapshots/delete",
    "Microsoft.Compute/virtualMachines/attachDetachDataDisks/action",
    "Microsoft.Compute/disks/read",
    "Microsoft.Compute/disks/write",
    "Microsoft.Compute/disks/delete",
    "Microsoft.Compute/disks/beginGetAccess/action",
    "Microsoft.Compute/virtualMachines/read",
    "Microsoft.Compute/virtualMachines/write"
  ]

 .EXAMPLE
 ./Rubrik-New-v2-Ultra-Snapshot.ps1 -configFile 'rubrik_az_config.yml'
 Execute the scripts according to the variables in the config file. Specify
 variables such as mount points, VG, and LV within the config file.

.EXAMPLE
./Rubrik-New-v2-Ultra-Snapshot.ps1 -configFile 'rubrik_az_config.yml' -irisName 'ply' -azDiskNames 'az-ply-disk-01'
Execute the scripts according to the variables in the config file and using an
IRIS ODB instance name. The mount points, VG, and LV will be automatically
generated based on $irisName.

#>

param (
  [CmdletBinding()]
  # Location of the YAML config file
  [Parameter(Mandatory=$true)]
  [string]$configFile = '',
  # The name of the IRIS instance you want to execute against
  # This is used to build the VG, LVM, and mount point names
  [Parameter(Mandatory=$false)]
  [string]$irisName = '',
  [CmdletBinding()]
  # Source disk names in Azure associated with the instance
  # If multiple disks, separate with a comma
  [Parameter(Mandatory=$false)]
  [string]$azDiskNames = ''
)

Import-Module Az.Accounts
Import-Module Az.Compute

$date = Get-Date
# $dateString will be appended to all snapshots and managed disks
# If this pattern changes, the logic to delete older snapshots and cloned disks
# will need to be updated
$dateString = $date.ToString("yyyy-MM-dd_HHmm")

## If you need to mount an existing disk, set $dateString below
# $dateString = '2024-10-01_1628'

# Directory to write logs to
$logDir = './logs'
# Filename of the log when stored in the path. The filename will be appended
# with: $logFilename-$dateString.log or $logFilename-$irisName-$dateString.log
$logFilename = 'rubrik_azure_snap_script'

if ($irisName) {
  $logPath = $logDir + '/' + $logFilename + '-' + $irisName + '-' + $dateString + '.log'
} else {
  $logPath = $logDir + '/' + $logFilename + '-' + $dateString + '.log'
}

Start-Transcript -path $logPath -append
Write-Host "Starting log capture to: $logPath"

if (-Not (Test-Path $configFile)) {
  throw "File not found: $configFile"
} else {
  $yamlContent = Get-Content -Path $configFile -Raw
}

##### BEGIN - VARIABLES #####


Function ConvertFrom-Yaml {
  param (
    [string]$YamlContent
  )
  $yamlLines = $YamlContent -split "`n"
  # Create a hashtable to store the converted data
  $result = @{}
  foreach ($line in $yamlLines) {
    if ($line -match '^\s*([^:]+):\s*(.+)\s*$') {
      $key = $matches[1].Trim()
      $value = $matches[2].Trim()
      $result[$key] = $value
      } elseif ($line -match '^\s*([^:]+):\s*$') {
        $key = $matches[1].Trim()
        $value = @{}
        $result[$key] = $value
      }
    }
    return $result
}
$configData = ConvertFrom-Yaml -YamlContent $yamlContent

# IRIS freeze / thaw commands
if ($irisName) {
  $EPIC_FREEZE = "sudo /epic/${irisName}/bin/instfreeze"
  $EPIC_THAW = "sudo /epic/${irisName}/bin/instthaw"
} else {
  $EPIC_FREEZE = $configData.EPIC_FREEZE
  $EPIC_THAW = $configData.EPIC_THAW
}

$EPIC_FREEZE_CMD = $EPIC_FREEZE
$EPIC_THAW_CMD = $EPIC_THAW
$EPIC_AUTOTHAW = "nohup sh -c '(sleep 5m && ${EPIC_THAW_CMD}) > /dev/null 2>&1 &'"
$EPIC_AUTOTHAW_CMD = $EPIC_AUTOTHAW

$EPIC_PRD_SERVER = $configData.EPIC_PRD_SERVER
$EPIC_PRD_USER = $configData.EPIC_PRD_USER

$snapDaysToKeep = [int]$configData.snapDaysToKeep
$clonedDisksDaysToKeep = [int]$configData.clonedDisksDaysToKeep
$sourceSubscriptionId = $configData.sourceSubscriptionId
$sourceResourceGroup = $configData.sourceResourceGroup
$targetSubscriptionId = $configData.targetSubscriptionId
$targetResourceGroup = $configData.targetResourceGroup
$proxyVM = $configData.proxyVM

$sourceSnapshotSuffix = $configData.sourceSnapshotSuffix
$targetDiskSuffix = $configData.targetDiskSuffix

$MOUNT_BASE = $configData.MOUNT_BASE
$MOUNTS = $configData.MOUNTS
$VGS = $configData.VGS
$LVS = $configData.LVS

if ($azDiskNames -eq '') {
  $azDiskNames = $configData.azDiskNames
}

$executeEpicCommands = [bool]::Parse($configData.executeEpicCommands)
$executeConnectToAzure = [bool]::Parse($configData.executeConnectToAzure)
$executeAzureCleanup = [bool]::Parse($configData.executeAzureCleanup)
$executeAzureSnapshot = [bool]::Parse($configData.executeAzureSnapshot)
$executeManagedDiskClone = [bool]::Parse($configData.executeManagedDiskClone)
$executeProxyDiskUnmountCommands = [bool]::Parse($configData.executeProxyDiskUnmountCommands)
$executeAzureDiskDetach = [bool]::Parse($configData.executeAzureDiskDetach)
$executeAzureDiskAttach = [bool]::Parse($configData.executeAzureDiskAttach)
$executeProxyMountCommands = [bool]::Parse($configData.executeProxyMountCommands)
$sendMail = [bool]::Parse($configData.sendMail)

$DiskMBpsReadWrite = [int]$configData.DiskMBpsReadWrite
$DiskMBpsReadOnly = [int]$configData.DiskMBpsReadOnly
$DiskIOPSReadWrite = [int]$configData.DiskIOPSReadWrite
$DiskIOPSReadOnly = [int]$configData.DiskIOPSReadOnly

$statusCheckSecs = [int]$configData.statusCheckSecs

$emailToConfig = $configData.emailTo
$emailFrom = $configData.emailFrom
$SMTPServer = $configData.SMTPServer
$emailSubjectConfig = $configData.emailSubject

$emailTo = @()
$emailTo = [array]($emailToConfig -split ',').ForEach{ $_.Trim() }

if ($irisName) {
  $emailSubject = $emailSubjectConfig + " - " + $irisName + " - " + $date.ToString("yyyy-MM-dd HH:MM")
} else {
  $emailSubject = $emailSubjectConfig + " - " + $date.ToString("yyyy-MM-dd HH:MM")
}

# List of source disks provided by $azDiskNames either passed as a parameter
# or defined in the config file
$sourceDisks = @()
$sourceDisks = ($azDiskNames -split ',').ForEach{ $_.Trim() }

# MOUNT_LIST holds the list of mounts that will be mounted under $MOUNT_BASE
# VG_LIST holds the list of volume group names
# LV_LIST holds the list of logical volume names
#
# If $irisName is defined, these are calculated based on the $irisName
# Otherwise, it will look for a comma seprated list of values provided in
# the config file.

# Initialize the lists
$MOUNT_LIST = @()
$VG_LIST = @()
$LV_LIST = @()

# If $irisName is provided, derives each value based on $irisName
if ($irisName) {
  $MOUNT_LIST = ($irisName -split ',').ForEach{ $_.Trim() }
  $MOUNT_LIST = $MOUNT_LIST.ForEach{ '/' + $_ + '01' }
  $VG_LIST = ($irisName -split ',').ForEach{ $_.Trim() }
  $VG_LIST = $VG_LIST.ForEach{ $_ + 'vg' }
  $LV_LIST = ($irisName -split ',').ForEach{ $_.Trim() }
  $LV_LIST = $LV_LIST.ForEach{ 'lv_' + $_ }

} else {
  # Otherwise, config file will provide a comma separated list for each
  $MOUNT_LIST = ($MOUNTS -split ',').ForEach{ $_.Trim() }
  $VG_LIST = ($VGS -split ',').ForEach{ $_.Trim() }
  $LV_LIST = ($LVS -split ',').ForEach{ $_.Trim() }
}

# Dev-Mapper holds the name of the device that will be mounted
$DEVMAPPER_LIST = @()
$VG_COUNT = $VG_LIST.count
for($i = 0; $i -lt $VG_COUNT; $i++) {
  $DEVMAPPER = "/dev/mapper/$($VG_LIST[$i])-$($LV_LIST[$i])"
  $DEVMAPPER_LIST += $DEVMAPPER
}

# # Stores all the mount points, devmapper, VG, and LVM in PSCustomTable array
# $MOUNTARRAY = @()
# $MOUNTCOUNT = $MOUNT_LIST.count
# for ($mount = 0; $mount -lt $mountCount; $mount++) {
#   $DEVMAPPER = "/dev/mapper/$($VG_LIST[$i])-$($LV_LIST[$i])"
#   $MOUNTINFO = [PSCustomObject]@{
#     MOUNT_POINT = $MOUNT_LIST[$mount]
#     DEVPATH = $DEVMAPPER
#     VG_NAME = $VG_LIST[$mount]
#     LV_NAME = $LV_LIST[$mount]
#   }
#   $MOUNTARRAY += $MOUNTINFO
# }

##### END - VARIABLES #####

#### Login to Azure and initialization of some variables ####

$currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
$emailBody = "${currentTime}: Starting Azure snapshot script $irisName `n"

if ($executeConnectToAzure) {
  Connect-AzAccount -Identity
  # Connect-AzAccount
  Set-AzContext -subscription $sourceSubscriptionId
  # Holds source disk to target disk name mapping
  $sourceDiskToTargetDisk = @{}
  # Holds the source disk to snapshot name mapping
  $sourceDiskToSnapshot = @{}
  # Holds source disk info
  $sourceDiskInfo = @{}
  # Hold source disk snapshot info
  $sourceSnapshotInfo = @{}
  # Create the source disk to target disk and snapshot name mapping
  foreach ($disk in $sourceDisks) {
    # Snapshot name with suffix and date appended
    $sourceDiskToSnapshot.$disk = "${disk}-${sourceSnapshotSuffix}-${dateString}"
    # Target disk name with suffix and date appended
    $sourceDiskToTargetDisk.$disk = "${disk}-${targetDiskSuffix}-${dateString}"
  }
  $diskCount = $sourceDisks.count
  Write-Host "Date: $date" -foregroundcolor green
  Write-Host "Source Subcription ID: $sourceSubscriptionId" -foregroundcolor green
  Write-Host "Source Resource Group: $sourceResourceGroup" -foregroundcolor green
  Write-Host "Source Snasphot suffix: -${sourceSnapshotSuffix}-${dateString}" -foregroundcolor green
  Write-Host ""
  Write-Host "Target (Proxy VM) Subcription ID: $sourceSubscriptionId" -foregroundcolor green
  Write-Host "Target (Proxy VM) Resource Group: $targetResourceGroup" -foregroundcolor green
  Write-Host "Target (Proxy VM) Disk suffix: -${targetDiskSuffix}-${dateString}" -foregroundcolor green
  Write-Host ""
  Write-Host "$diskCount disks will be snapshot and cloned:" -foregroundcolor green
  foreach ($disk in $sourceDisks) {
    Write-Host "Source Disk Name: $disk"
    Write-Host "Source Snapshot Name: $($sourceDiskToSnapshot.$disk)"
    Write-Host "Target Disk Name: $($sourceDiskToTargetDisk.$disk)"
    Write-Host ""
  }
  Write-Host ""
}

#### Cleanup older snapshots and cloned Managed Disks ####

if ($executeAzureCleanup) {
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Cleaning up older snapshots and cloned disks `n"
  Set-AzContext -subscription $sourceSubscriptionId
  $snapDateToKeep = $date.add("-$snapDaysToKeep")
  Write-Host "Looking for and cleaning up any snapshots older than: $snapDateToKeep" -foregroundcolor green
  # Get all snapshots in the source resource group
  $azSnapshots = Get-AzSnapshot -ResourceGroup $sourceResourceGroup
  # Loop through each disk that Rubrik is snapshotting
  foreach ($disk in $sourceDisks) {
    $rubrikSnapshotName = "${disk}-${sourceSnapshotSuffix}"
    $rubrikSnapshots = $azSnapshots | Where { $_.Name -match $rubrikSnapshotName }
    foreach ($rubrikSnap in $rubrikSnapshots) {
      $dateStringPattern = '\d{4}-\d{2}-\d{2}_\d{4}'
      if ($rubrikSnap.name -match $dateStringPattern) {
        $timestamp = $matches[0]
        # Split the timestamp into date and time parts
        $dateStamp, $time = $timestamp -split '_'
        # Reformat the time from HHMM to HH:MM to make it valid
        $time = $time.Insert(2, ':')
        # Combine date and time parts into a single string
        $dateTimeString = "$dateStamp $time"
        # Convert to DateTime object
        $snapDateTime = [datetime]::ParseExact($datetimeString, 'yyyy-MM-dd HH:mm', $null)
        if ($snapDateTime -lt $snapDateToKeep) {
          Write-Host "Deleting snapshot older than $snapDaysToKeep days: $($rubrikSnap.name)"
          $result = Remove-AzSnapshot -ResourceGroupName $sourceResourceGroup -SnapshotName $rubrikSnap.name -Force
          Write-Host "Snapshot deletion result: $($result.status)"
        }
      }
    }
  }
  $clonedDisksDateToKeep = $date.add("-$clonedDisksDaysToKeep")
  Write-Host "Looking for and cleaning up Managed Disk clones older than: $clonedDisksDateToKeep" -foregroundcolor green
  Write-Host "Switching subscription context to target subscription."
  Set-AzContext -subscription $targetSubscriptionId
  $azDisks = Get-AzDisk -ResourceGroup $targetResourceGroup
  foreach ($disk in $sourceDisks) {
    $rubrikClonedDiskName = "${disk}-${targetDiskSuffix}"
    $rubrikClonedDisks = $azDisks | Where { $_.Name -match $rubrikClonedDiskName }
    foreach ($rubrikDisk in $rubrikClonedDisks) {
      $dateStringPattern = '\d{4}-\d{2}-\d{2}_\d{4}'
      if ($rubrikDisk.name -match $dateStringPattern) {
        $timestamp = $matches[0]
        # Split the timestamp into date and time parts
        $dateStamp, $time = $timestamp -split '_'
        # Reformat the time from HHMM to HH:MM to make it valid
        $time = $time.Insert(2, ':')
        # Combine date and time parts into a single string
        $dateTimeString = "$dateStamp $time"
        # Convert to DateTime object
        $rubrikDiskDateTime = [datetime]::ParseExact($datetimeString, 'yyyy-MM-dd HH:mm', $null)
        if ($rubrikDiskDateTime -lt $clonedDisksDateToKeep) {
          Write-Host "Deleting cloned disk older than $clonedDisksDaysToKeep days: $($rubrikDisk.name)"
          $result = Remove-AzDisk -ResourceGroupName $targetResourceGroup -DiskName $rubrikDisk.name -Force
          Write-Host "Cloned disk deletion result: $($result.status)"
        }
      }
    }
  }
  Write-Host "Switching subscription context to source subscription."
  Set-AzContext -subscription $sourceSubscriptionId
}  # if ($executeAzureCleanup)

#### Create snapshot of each source disk ####
# https://learn.microsoft.com/en-us/azure/virtual-machines/disks-incremental-snapshots?tabs=azure-powershell

# Send command to IRIS PRD server to freeze and set auto-thaw
if ($executeEpicCommands) {
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Sending command to freeze IRIS ODB `n"
  Write-Host "Sending command to freeze & auto-thaw IRIS ODB..." -foregroundcolor cyan
  ssh ${EPIC_PRD_USER}@${EPIC_PRD_SERVER} ${EPIC_FREEZE_CMD} 2>&1
  ssh ${EPIC_PRD_USER}@${EPIC_PRD_SERVER} ${EPIC_AUTOTHAW_CMD} 2>&1
}

if ($executeAzureSnapshot) {
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Creating snapshots `n"
  # Create a snapshot for each disk
  foreach ($snapshot in $sourceDiskToSnapshot.getEnumerator()) {
    # $sourceDiskToSnapshot contains the Source Disk Name to Snapshot Name mapping
    $diskName = $snapshot.name
    $snapshotName = $snapshot.value
    Write-Host "Creating snapshot for disk: $diskName, snapshot name: $snapshotName..."
    # Get the disk info that you need to backup by creating an incremental snapshot
    $diskInfo = Get-AzDisk -DiskName $diskName -ResourceGroupName $sourceResourceGroup
    # Add the disk info to the source disk info hashtable
    $sourceDiskInfo.$diskName = $diskInfo
    # Create an incremental snapshot by setting the SourceUri property with the value of the Id property of the disk
    $snapshotConfig = New-AzSnapshotConfig -SourceUri $diskInfo.Id -Location $diskInfo.Location -CreateOption Copy -Incremental
    # Create the new incremental snapshot
    try {
      $result = New-AzSnapshot -ResourceGroupName $sourceResourceGroup -SnapshotName $snapshotName -Snapshot $snapshotConfig -ErrorAction Stop
    } catch {
      $Error[0]
      if ($executeEpicCommands) {
        Write-Host "Sending command to thaw IRIS ODB..." -foregroundcolor cyan
        ssh ${EPIC_PRD_USER}@${EPIC_PRD_SERVER} ${EPIC_THAW_CMD} 2>&1
      }
      Write-Error "Exiting script..."
      exit 10
    }
    # Check if each snapshot taken was successful or newestSnapshot
    $snapshotState = $result.ProvisioningState
    if ($snapshotState.contains('Succeeded')) {
      Write-Host "Snapshot result: $($result.ProvisioningState)" -foregroundcolor green
    } else {
      Write-Error "Error taking snapshot: $snapshotState"
      $result
      if ($executeEpicCommands) {
        Write-Host "Sending command to thaw IRIS ODB..." -foregroundcolor cyan
        ssh ${EPIC_PRD_USER}@${EPIC_PRD_SERVER} ${EPIC_THAW_CMD} 2>&1
      }
      Write-Error "Exiting script..."
      exit 11
    }
  } # foreach ($disk in $sourceDisks)

  # If all snapshots successful, send IRIS thaw command
  if ($executeEpicCommands) {
    Write-Host "Sending command to thaw IRIS ODB..." -foregroundcolor cyan
    ssh ${EPIC_PRD_USER}@${EPIC_PRD_SERVER} ${EPIC_THAW_CMD} 2>&1
  }

  Write-Host ""
  Write-Host "Waiting for $diskCount incremental snapshots to finish background copy" -foregroundcolor green
  Write-Host ""

  # Hash table of snapshots that have completed their background copy
  $snapshotComplete = @{}

  # For each incremental snapshot, check and wait until the background copy completes
  while ($snapshotComplete.count -lt $diskCount) {
    $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
    # Check the status of each snapshot operation
    foreach ($snapshot in $sourceDiskToSnapshot.getEnumerator()) {
      # $sourceDiskToSnapshot contains the Source Disk Name to Snapshot Name mapping
      $snapshotName = $snapshot.value
      $snapshotInfo = Get-AzSnapshot -ResourceGroupName $sourceResourceGroup -SnapshotName $snapshotName
      $sourceSnapshotInfo.$snapshotName = $snapshotInfo
      if ($snapshotInfo.CompletionPercent -lt 100) {
        Write-Host "${currentTime}: Snapshot: $($snapshotInfo.name), completion: $($snapshotInfo.CompletionPercent), waiting another $statusCheckSecs secs..."
      } else {
        Write-Host "${currentTime}: Snapshot: $($snapshotInfo.name), completion: $($snapshotInfo.CompletionPercent)" -foregroundcolor green
        $snapshotComplete.$snapshot = $true
      }
    }
    if ($snapshotComplete.count -lt $diskCount) {
      Start-Sleep $statusCheckSecs
    }
  }
  Write-Host "All $diskCount snapshots have finished background copy" -foregroundcolor green
} # If ($executeAzureCommands)

# If execute snapshot is skipped, and we want to use an existing snapshot
# to clone the Managed Disk, grab the Disk and Snapshot Info.
# $dateString needs to be set to target an existing snapshot.
if ( $executeManagedDiskClone -and ($executeAzureSnapshot -eq $false) ) {
  foreach ($snapshot in $sourceDiskToSnapshot.getEnumerator()) {
    # Get disk info for each disk
    $diskName = $snapshot.name
    $diskInfo = Get-AzDisk -DiskName $diskName -ResourceGroupName $sourceResourceGroup
    $sourceDiskInfo.$diskName = $diskInfo
    # Get snapshot info for each disk
    $snapshotName = $snapshot.value
    $snapshotInfo = Get-AzSnapshot -ResourceGroupName $sourceResourceGroup -SnapshotName $snapshotName
    $sourceSnapshotInfo.$snapshotName = $snapshotInfo
  }
}

#### Switch Subscription Context ####
# If the Proxy VM is in a different subscription, the rest of Azure commands will
# performed in the target subscription
if ($executeConnectToAzure) {
  if ($sourceSubscriptionId -ne $targetSubscriptionId) {
    Write-Host ""
    Write-Host "Target subscription is different, switching to: $targetSubscriptionId"
    $result = Set-AzContext -Subscription $targetSubscriptionId
    Write-Host "Context set: $($result.name)"
  }
}

#### Create a Managed Disk from the snapshot ####
# https://learn.microsoft.com/en-us/azure/virtual-machines/scripts/virtual-machines-powershell-sample-create-managed-disk-from-snapshot
# https://learn.microsoft.com/en-us/powershell/module/az.compute/new-azdiskconfig

if ($executeManagedDiskClone) {
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Creating cloned Managed Disks from snapshots `n"
  Write-Host ""
  Write-Host "Starting Managed Disk creation from snapshots..."
  # $disk contains the name of the source disk being worked on
  foreach ($disk in $sourceDisks) {
    # Get the target disk name from the mapping
    $targetDiskName = $sourceDiskToTargetDisk[$disk]
    # Get the disk info for the source disk - cloned disk matches: size, sku, zone, and location
    $diskInfo = $sourceDiskInfo[$disk]
    # Get the snapshot name from the mapping
    $snapshotName = $sourceDisktoSnapshot[$disk]
    # Get the snapshot info for the snapshot that was taken - get snapshot Uri
    $snapshotInfo = $sourceSnapshotInfo[$snapshotName]
    Write-Host ""
    Write-Host "Building disk config for source disk: $disk"
    Write-Host "Using source snapshot: $snapshotName"
    Write-Host "Target disk name: $targetDiskName"
    $diskConfigParameters = @{
      CreateOption = "Copy"
      SourceResourceId = $snapshotInfo.Id
      DiskSizeGB = $diskInfo.DiskSizeGB
      SkuName = $diskInfo.sku.name
      Zone = $diskInfo.zones[0]
      Location = $diskInfo.location
      DiskIOPSReadWrite = $diskIOPSReadWrite
      DiskIOPSReadOnly = $diskIOPSReadOnly
      DiskMBpsReadWrite = $diskMBpsReadWrite
      DiskMBpsReadOnly = $diskMBpsReadOnly
    }
    $diskConfigParameters | Format-table
    # Create a Managed Disk config from the parameters above
    $diskConfig = New-AzDiskConfig @diskConfigParameters -ErrorAction Stop
    # Script will now create new Managed Disks from the snapshots
    # There is error handling to check if 'diskMBpsReadWrite' or 'diskMBpsReadOnly'
    # is set out of range and attempt to set it to its max value
    # Regex to check 'diskMBpsReadWrite' or 'diskMBpsReadOnly' config error and grab largest supported value
    $regex = $regex = "disk\.(diskMBpsReadWrite|diskMBpsReadOnly).*between\s+(?:\d+\s+and\s+)?(\d+)"
    $retry = $true
    # Failsafe if the error message changes, then exit script if retries too high
    $retryCount = 0
    while ($retry -eq $true -and $retryCount -lt 4) {
      $retry = $false
      $retryCount++
      if ($retryCount -ge 4) {
        Write-Error "Too many retries in creating Managed Disk, exiting..."
        exit 20
      }
      try {
        # Create a new Managed Disk from the Snapshot
        Write-Host ""
        Write-Host "Creating new Managed Disk: $targetDiskName" -foregroundcolor green
        $result = New-AzDisk -Disk $diskConfig -ResourceGroupName $targetResourceGroup -DiskName $targetDiskName -ErrorAction Stop
      } catch {
        $Error[0]
        # If the error matched on 'diskMBps__' setting
        if ($Error[0] -match $regex) {
          Write-Host "Found an issue with: $($Matches[1]), setting it to max value of: $($Matches[2])" -foregroundcolor yellow
          $diskConfigParameters.$($Matches[1]) = [int]$Matches[2]
          Write-Host "Retrying creating new Managed Disk: $targetDiskName..." -foregroundcolor yellow
          $diskConfigParameters | Format-table
          $diskConfig = New-AzDiskConfig @diskConfigParameters
          $retry = $true
        } else {
          # If error isn't related to 'diskMBps__' setting
          exit 30
        }
      }
    }
    Write-Host "Managed Disk creation result: $($result.ProvisioningState)"
  } # foreach ($disk in $sourceDisks) to create the disk from snasphot

  Write-Host ""
  Write-Host "Waiting until snapshot clone to Managed Disk background copy completes" -foregroundcolor green
  Write-Host ""

  # Hash table of Managed Disks that have completed their background copy
  $diskComplete = @{}

  # For each Managed Disk copy, check and wait until the background copy completes
  while ($diskComplete.count -lt $diskCount) {
    $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
    # Check the status of each Managed Disk operation
    foreach ($disk in $sourceDisks) {
      $targetDiskName = $sourceDiskToTargetDisk[$disk]
      $diskInfo = Get-AzDisk -DiskName $targetDiskName -ResourceGroupName $targetResourceGroup
      if ($diskInfo.CompletionPercent -lt 100) {
        Write-Host "${currentTime}: Disk copy: $($diskInfo.name), completion: $($diskInfo.CompletionPercent), waiting another $statusCheckSecs secs..."
      } else {
        Write-Host "${currentTime}: Disk copy: $($diskInfo.name), completion: $($diskInfo.CompletionPercent)" -foregroundcolor green
        $diskComplete.$disk = $true
      }
    }
    if ($diskComplete.count -lt $diskCount) {
      Start-Sleep $statusCheckSecs
    }
  } # while ($diskComplete.count -lt $diskCount) to check disk copy status
  Write-Host "All $diskCount Managed Disks have finished background copy" -foregroundcolor green
} # If ($executeAzureCommands)


#### Detach Managed Disk from the Proxy VM ####
# https://learn.microsoft.com/en-us/azure/virtual-machines/windows/detach-disk

# Unmount the file systems from the proxy VM and disable the VG
if ($executeProxyDiskUnmountCommands) {
  Write-Host ""
  Write-Host "On Proxy VM, attempting to unmount file systems" -foregroundcolor green
  foreach ($mountPoint in $MOUNT_LIST) {
    Write-Host "Attempting to unmount ${MOUNT_BASE}${mountPoint}..."
    umount ${MOUNT_BASE}${mountPoint}
  }
}

if ($executeAzureDiskDetach) {
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Detatching disks from Proxy VM `n"
  Write-Host ""
  Write-Host "Detaching existing data disks from the Proxy VM" -foregroundcolor green

  # On the Proxy VM, detach and delete any pre-existing Managed Disks with the
  # same name we are about to create
  # List of disk that match to detach
  $disksToDetach = @()
  # Get the Proxy VM details
  $vm = Get-AzVM -ResourceGroupName $targetResourceGroup -Name $proxyVM
  # For each source disk, find matching ones on the Proxy VM
  foreach ($disk in $sourceDisks) {
    # Disk info is stored in 'StorageProfile.DataDisks'
    foreach ($proxyVmDisk in $vm.StorageProfile.DataDisks) {
      # If the data disk matches, then add it to the list to detach
      if ($proxyVmDisk.name -match $disk) {
        $disksToDetach += $proxyVmDisk.name
      }
    }
  }
  # Detach all the disks that were matched
  foreach ($diskDetatch in $disksToDetach) {
    # Detach the disk from the VM
    Write-Host "Attempting to detatch disk: $diskDetatch..."
    $resultUpdate = $null
    $retry = $true
    # Failsafe if the error message changes, then exit script if retries too high
    $retryCount = 0
    while ($resultUpdate -eq $null) {
      if ($retryCount -gt 4) {
        Write-Host "Too many retries trying to detatch disk: $diskDetatch, exiting..."
        exit 40
      }
      $retryCount++
      try {
        $randomInterval = Get-Random -Minimum 20 -Maximum 60
        Start-Sleep -Seconds $randomInterval
        $vm = Get-AzVM -ResourceGroupName $targetResourceGroup -Name $proxyVM
        $resultRemove = Remove-AzVMDataDisk -VM $vm -Name $diskDetatch -ErrorAction Stop
        $resultUpdate = Update-AzVM -VM $vm -ResourceGroupName $targetResourceGroup -ErrorAction Stop
      } catch {
        Write-Error "Error detatching disk: $diskDetatch, trying again in 30 seconds..."
        Start-Sleep 30
      }
    }
  }
} # If ($executeAzureCommands)


#### Attach Managed Disk to proxy VM ####
# https://learn.microsoft.com/en-us/azure/virtual-machines/windows/attach-disk-ps

if ($executeAzureDiskAttach) {
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Attaching cloned disks to Proxy VM `n"
  Write-Host ""
  Write-Host "Attaching new Managed Disks to the Proxy VM" -foregroundcolor green
  $vm = Get-AzVM -ResourceGroupName $targetResourceGroup -Name $proxyVM
  $lunNum = 0
  # For each source disk, will then get the target disk name to attach
  foreach ($disk in $sourceDisks) {
    $targetDiskName = $sourceDiskToTargetDisk[$disk]
    if ($targetDiskName -match 'lun([0-9]+)') {
      [int]$lunNum = $matches[1]
    }
    Write-Host "Attaching disk to Proxy VM: $targetDiskName..."
    $resultUpdate = $null
    # Failsafe if the error message changes, then exit script if retries too high
    $retryCount = 0
    while ($resultUpdate -eq $null) {
      if ($retryCount -gt 4) {
        Write-Host "Too many retries trying to attach disk: $targetDiskName, exiting..."
        exit 50
      }
      $retryCount++
      try {
        $randomInterval = Get-Random -Minimum 20 -Maximum 60
        Start-Sleep -Seconds $randomInterval
        $diskInfo = Get-AzDisk -DiskName $targetDiskName -ResourceGroupName $targetResourceGroup -ErrorAction Stop
        $resultAdd = Add-AzVMDataDisk -CreateOption Attach -Lun $lunNum -VM $vm -ManagedDiskId $diskInfo.Id -ErrorAction Stop
        $resultUpdate = Update-AzVM -VM $vm -ResourceGroupName $targetResourceGroup -ErrorAction Stop
      } catch {
        Write-Error "Error attaching disk: $targetDiskName, trying again in 30 seconds..."
        Start-Sleep 30
      }
    }
    [int]$lunNum++
  }
} # If ($executeAzureCommands)

# Enable each VG and mount the mount points
# The mount definitions should put in /etc/fstab
if ($executeProxyMountCommands) {
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Mounting file systems on Proxy VM `n"
  Write-Host ""
  Write-Host "On Proxy VM, re-mounting the file systems" -foregroundcolor green
  $mountCount = $MOUNT_LIST.count
  for ($mount = 0; $mount -lt $mountCount; $mount++) {
    Write-Host "Attempting to vary VG on: $VG_LIST[$mount]..."
    $vg_name = $VG_LIST[$mount]
    $lv_name = $LV_LIST[$mount]
    lvchange -an /dev/$vg_name/$lv_name
    vgchange -an $vg_name
    vgchange -ay $vg_name
    lvchange -ay /dev/$vg_name/$lv_name
    $path = $MOUNT_LIST[$mount]
    $devPath = $DEVMAPPER_LIST[$mount]
    mount $devPath ${MOUNT_BASE}${path}
  }
  foreach ($mountPoint in $MOUNT_LIST) {
    Write-Host ""
    Write-Host "Verifying mount points" -foregroundcolor green
    $output = df -h
    if ($output -like "*$mountPoint*") {
      $output -like "*$mountPoint*"
    } else {
      Write-Error "$mountPoint was not mounted"
    }
  }
}

Stop-Transcript

# Read the content of the transcript log file
$emailBody += Get-Content -Path $logPath -Raw
$emailBodyHtml = "<pre>$emailBody</pre>"

if ($sendMail) {
  # Create and send the email
  Send-MailMessage -From $emailFrom -To $emailTo -Subject $emailSubject -Body $emailBodyHtml -SmtpServer $smtpServer -BodyAsHtml $true
}

exit 0
