<#
.SYNOPSIS
This script will create a snapshot and disk clone for Epic IRIS ODB backups
in Azure for v2 / Ultra SSDs.

.DESCRIPTION
This script will create a snapshot and disk clone for Epic IRIS ODB backups
in Azure for v2 / Ultra SSDs.

This script works with a PSD1 config file (see rubrik_az_config.psd1).

# TODO: Add support for Azure Instant Snapshots (eliminates background copy wait)

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
9. Azure - Mounts the newly cloned Managed Disk onto the Proxy VM
10. Proxy VM - Re-Mount the refreshed Managed Disk
   ** vgchange -ay <volume_groups>
   ** mount <using dev mapper>
11. Rubrik backup begins

The snapshot and the cloned Managed Disks will be the same name as the source disk
but appended with a 'suffix' and datestamped.

.NOTES
Written by Steven Tong for usage with Rubrik
GitHub: stevenctong
Date: 8/30/24
Updated: 7/12/26

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

 .PARAMETER configFile
 Path to the PSD1 config file containing all instance-specific variables.
 See rubrik_az_config.psd1 for an example.

 .EXAMPLE
 ./Rubrik-New-v2-Ultra-Snapshot.ps1 -configFile 'rubrik_az_config.psd1'
 Execute the script according to the variables in the config file. Specify
 variables such as mount points, VG, and LV within the config file.

#>

[CmdletBinding()]
param (
  [Parameter(Mandatory=$true)]
  [string]$configFile
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


##### BEGIN - VARIABLES #####

if (-Not (Test-Path $configFile)) {
  throw "File not found: $configFile"
}

$configData = Import-PowerShellDataFile -Path $configFile

# Create local variables from all config keys
foreach ($key in $configData.Keys) {
  New-Variable -Name $key -Value $configData[$key] -Force
}

# Log path derived from config values + date
if ($irisName) {
  $logPath = $logDir + '/' + $logFilename + '-' + $irisName + '-' + $dateString + '.log'
} else {
  $logPath = $logDir + '/' + $logFilename + '-' + $dateString + '.log'
}

Start-Transcript -path $logPath -append

Write-Host ""
Write-Host "Starting Azure snapshot and clone script on $(hostname)"
Write-Host "Config file: $configFile"
Write-Host "Date: $date"
Write-Host "Date string (appended to resources): $dateString"
Write-Host "Log file: $logPath"
if ($irisName) {
  Write-Host "IRIS instance: $irisName"
}
Write-Host ""
Write-Host "Execution flags:"
Write-Host "  Epic commands: $executeEpicCommands"
Write-Host "  Connect to Azure: $executeConnectToAzure"
Write-Host "  Azure cleanup: $executeAzureCleanup"
Write-Host "  Azure snapshot: $executeAzureSnapshot"
Write-Host "  Managed Disk clone: $executeManagedDiskClone"
Write-Host "  Proxy disk unmount: $executeProxyDiskUnmountCommands"
Write-Host "  Azure disk detach: $executeAzureDiskDetach"
Write-Host "  Azure disk attach: $executeAzureDiskAttach"
Write-Host "  Proxy mount: $executeProxyMountCommands"
Write-Host ""

# Delete log files older than 60 days
$logRetentionDays = 60
$logCutoff = $date.AddDays(-$logRetentionDays)
Get-ChildItem -Path $logDir -Filter "${logFilename}*.log" -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt $logCutoff } |
  ForEach-Object {
    Write-Host "Deleting log older than $logRetentionDays days: $($_.Name)"
    Remove-Item $_.FullName -Force
  }

# IRIS freeze / thaw commands - derived from irisName or config
if ($irisName) {
  $EPIC_FREEZE_CMD = "sudo /epic/${irisName}/bin/instfreeze"
  $EPIC_THAW_CMD = "sudo /epic/${irisName}/bin/instthaw"
} else {
  $EPIC_FREEZE_CMD = $EPIC_FREEZE
  $EPIC_THAW_CMD = $EPIC_THAW
}
$EPIC_AUTOTHAW_CMD = "nohup sh -c '(sleep 5m && ${EPIC_THAW_CMD}) > /dev/null 2>&1 &'"

# Email subject derived from config + irisName + date
if ($irisName) {
  $emailSubject = $emailSubject + " - " + $irisName + " - " + $date.ToString("yyyy-MM-dd HH:mm")
} else {
  $emailSubject = $emailSubject + " - " + $date.ToString("yyyy-MM-dd HH:mm")
}

# MOUNT_LIST, VG_LIST, LV_LIST - derived from irisName or config
if ($irisName) {
  $MOUNT_LIST = @('/' + $irisName + '01')
  $VG_LIST = @($irisName + 'vg')
  $LV_LIST = @('lv_' + $irisName)
} else {
  $MOUNT_LIST = $MOUNTS
  $VG_LIST = $VGS
  $LV_LIST = $LVS
}

# Dev-Mapper paths derived from VG and LV lists
$DEVMAPPER_LIST = for ($i = 0; $i -lt $VG_LIST.count; $i++) {
  "/dev/mapper/$($VG_LIST[$i])-$($LV_LIST[$i])"
}

##### END - VARIABLES #####

# Deletes Azure snapshots or Managed Disks older than a cutoff date.
# Parses the embedded yyyy-MM-dd_HHmm timestamp from the resource name.
function Remove-ExpiredAzureResources {
  param (
    [string]$ResourceGroup,
    [array]$Resources,
    [string]$NameSuffix,
    [datetime]$CutoffDate,
    [int]$RetentionDays,
    [ValidateSet('snapshot','disk')]
    [string]$ResourceType,
    [array]$SourceDisks
  )
  foreach ($disk in $SourceDisks) {
    $matchName = "${disk}-${NameSuffix}"
    $matched = $Resources | Where-Object { $_.Name -match $matchName }
    foreach ($resource in $matched) {
      if ($resource.Name -match '\d{4}-\d{2}-\d{2}_\d{4}') {
        $dateStamp, $time = $matches[0] -split '_'
        $time = $time.Insert(2, ':')
        $resourceDate = [datetime]::ParseExact("$dateStamp $time", 'yyyy-MM-dd HH:mm', $null)
        if ($resourceDate -lt $CutoffDate) {
          Write-Host "Deleting $ResourceType older than $RetentionDays days: $($resource.Name)"
          if ($ResourceType -eq 'snapshot') {
            $result = Remove-AzSnapshot -ResourceGroupName $ResourceGroup -SnapshotName $resource.Name -Force
          } else {
            $result = Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $resource.Name -Force
          }
          Write-Host "$ResourceType deletion result: $($result.Status)"
        }
      }
    }
  }
}

# Sends the IRIS ODB thaw command via SSH if Epic commands are enabled
function Send-EpicThawCommand {
  if ($executeEpicCommands) {
    Write-Host "Sending command to thaw IRIS ODB..." -foregroundcolor cyan
    ssh ${EPIC_PRD_USER}@${EPIC_PRD_SERVER} ${EPIC_THAW_CMD} 2>&1
  }
}

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
  Write-Host "Source Subscription ID: $sourceSubscriptionId" -foregroundcolor green
  Write-Host "Source Resource Group: $sourceResourceGroup" -foregroundcolor green
  Write-Host "Source Snapshot suffix: -${sourceSnapshotSuffix}-${dateString}" -foregroundcolor green
  Write-Host ""
  Write-Host "Target (Proxy VM) Subscription ID: $targetSubscriptionId" -foregroundcolor green
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

  $snapCutoff = $date.AddDays(-$snapDaysToKeep)
  Write-Host "Looking for and cleaning up any snapshots older than: $snapCutoff" -foregroundcolor green
  $azSnapshots = Get-AzSnapshot -ResourceGroup $sourceResourceGroup
  Remove-ExpiredAzureResources -ResourceGroup $sourceResourceGroup -Resources $azSnapshots `
    -NameSuffix $sourceSnapshotSuffix -CutoffDate $snapCutoff -RetentionDays $snapDaysToKeep `
    -ResourceType 'snapshot' -SourceDisks $sourceDisks

  $diskCutoff = $date.AddDays(-$clonedDisksDaysToKeep)
  Write-Host "Looking for and cleaning up Managed Disk clones older than: $diskCutoff" -foregroundcolor green
  Write-Host "Switching subscription context to target subscription."
  Set-AzContext -subscription $targetSubscriptionId
  $azDisks = Get-AzDisk -ResourceGroup $targetResourceGroup
  Remove-ExpiredAzureResources -ResourceGroup $targetResourceGroup -Resources $azDisks `
    -NameSuffix $targetDiskSuffix -CutoffDate $diskCutoff -RetentionDays $clonedDisksDaysToKeep `
    -ResourceType 'disk' -SourceDisks $sourceDisks

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
  Write-Host "Freeze: ssh ${EPIC_PRD_USER}@${EPIC_PRD_SERVER} ${EPIC_FREEZE_CMD}"
  $freezeResult = ssh ${EPIC_PRD_USER}@${EPIC_PRD_SERVER} ${EPIC_FREEZE_CMD} 2>&1
  Write-Host "Freeze result: $freezeResult"
  Write-Host "Auto-thaw: ssh ${EPIC_PRD_USER}@${EPIC_PRD_SERVER} ${EPIC_AUTOTHAW_CMD}"
  $autothawResult = ssh ${EPIC_PRD_USER}@${EPIC_PRD_SERVER} ${EPIC_AUTOTHAW_CMD} 2>&1
  Write-Host "Auto-thaw result: $autothawResult"
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
      Send-EpicThawCommand
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
      Send-EpicThawCommand
      Write-Error "Exiting script..."
      exit 11
    }
  } # foreach ($snapshot in $sourceDiskToSnapshot.getEnumerator())

  # If all snapshots successful, send IRIS thaw command
  Send-EpicThawCommand

  Write-Host ""
  Write-Host "Waiting for $diskCount incremental snapshots to finish background copy" -foregroundcolor green
  Write-Host ""

  # Hash table of snapshots that have completed their background copy
  $snapshotComplete = @{}
  $pollIteration = 0
  $maxPollIterations = 120

  # For each incremental snapshot, check and wait until the background copy completes
  while ($snapshotComplete.count -lt $diskCount) {
    if ($pollIteration -ge $maxPollIterations) {
      Write-Error "Snapshot background copy timed out after $([math]::Round($pollIteration * $statusCheckSecs / 60)) minutes, exiting..."
      exit 12
    }
    $pollIteration++
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
} # if ($executeAzureSnapshot)

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
    $regex = "disk\.(diskMBpsReadWrite|diskMBpsReadOnly).*between\s+(?:\d+\s+and\s+)?(\d+)"
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
          Write-Error "Unhandled error creating Managed Disk: $targetDiskName, exiting..."
          exit 30
        }
      }
    }
    Write-Host "Managed Disk creation result: $($result.ProvisioningState)"
  } # foreach ($disk in $sourceDisks) to create the disk from snapshot

  Write-Host ""
  Write-Host "Waiting until snapshot clone to Managed Disk background copy completes" -foregroundcolor green
  Write-Host ""

  # Hash table of Managed Disks that have completed their background copy
  $diskComplete = @{}
  $pollIteration = 0
  $maxPollIterations = 120

  # For each Managed Disk copy, check and wait until the background copy completes
  while ($diskComplete.count -lt $diskCount) {
    if ($pollIteration -ge $maxPollIterations) {
      Write-Error "Managed Disk background copy timed out after $([math]::Round($pollIteration * $statusCheckSecs / 60)) minutes, exiting..."
      exit 21
    }
    $pollIteration++
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
} # if ($executeManagedDiskClone)


#### Detach Managed Disk from the Proxy VM ####
# https://learn.microsoft.com/en-us/azure/virtual-machines/windows/detach-disk

# Unmount the file systems from the proxy VM and deactivate VGs
if ($executeProxyDiskUnmountCommands) {
  Write-Host ""
  Write-Host "On Proxy VM, attempting to unmount file systems" -foregroundcolor green
  foreach ($mountPoint in $MOUNT_LIST) {
    Write-Host "Attempting to unmount ${MOUNT_BASE}${mountPoint}..."
    umount ${MOUNT_BASE}${mountPoint}
  }
  Write-Host "Deactivating volume groups before disk detach" -foregroundcolor green
  foreach ($vg_name in $VG_LIST) {
    Write-Host "Deactivating VG: $vg_name..."
    vgchange -an $vg_name
  }
}

if ($executeAzureDiskDetach) {
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Detaching disks from Proxy VM `n"
  Write-Host ""
  Write-Host "Detaching existing data disks from the Proxy VM" -foregroundcolor green

  # Find and detach any pre-existing Managed Disks whose names match the source disks
  $vm = Get-AzVM -ResourceGroupName $targetResourceGroup -Name $proxyVM
  $diskPattern = ($sourceDisks | ForEach-Object { [regex]::Escape($_) }) -join '|'
  $disksToDetach = @($vm.StorageProfile.DataDisks |
    Where-Object { $_.Name -match $diskPattern } |
    ForEach-Object { $_.Name })
  Write-Host "Found $($disksToDetach.Count) disk(s) to detach: $($disksToDetach -join ', ')"
  # Detach all the disks that were matched
  foreach ($diskDetach in $disksToDetach) {
    # Detach the disk from the VM
    Write-Host "Attempting to detach disk: $diskDetach..."
    $resultUpdate = $null
    $retryCount = 0
    while ($null -eq $resultUpdate) {
      if ($retryCount -gt 4) {
        Write-Host "Too many retries trying to detach disk: $diskDetach, exiting..."
        exit 40
      }
      $retryCount++
      try {
        # Random interval avoids Azure API throttling on concurrent VM updates
        $randomInterval = Get-Random -Minimum 20 -Maximum 60
        Start-Sleep -Seconds $randomInterval
        $vm = Get-AzVM -ResourceGroupName $targetResourceGroup -Name $proxyVM
        $resultRemove = Remove-AzVMDataDisk -VM $vm -Name $diskDetach -ErrorAction Stop
        $resultUpdate = Update-AzVM -VM $vm -ResourceGroupName $targetResourceGroup -ErrorAction Stop
      } catch {
        Write-Error "Error detaching disk: $diskDetach, trying again in 30 seconds..."
        Start-Sleep 30
      }
    }
    Write-Host "Successfully detached disk: $diskDetach" -foregroundcolor green
  }
} # if ($executeAzureDiskDetach)


#### Attach Managed Disk to proxy VM ####
# https://learn.microsoft.com/en-us/azure/virtual-machines/windows/attach-disk-ps

if ($executeAzureDiskAttach) {
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Attaching cloned disks to Proxy VM `n"
  Write-Host ""
  Write-Host "Attaching new Managed Disks to the Proxy VM" -foregroundcolor green
  $lunNum = 0
  # For each source disk, will then get the target disk name to attach
  foreach ($disk in $sourceDisks) {
    $targetDiskName = $sourceDiskToTargetDisk[$disk]
    if ($targetDiskName -match 'lun([0-9]+)') {
      [int]$lunNum = $matches[1]
      Write-Host "Found LUN: $lunNum"
    }
    $randomInterval = Get-Random -Minimum 20 -Maximum 60
    Start-Sleep -Seconds $randomInterval
    $vm = Get-AzVM -ResourceGroupName $targetResourceGroup -Name $proxyVM
    # Check if the LUN is being used, and if it is, increment the LUN number
    while ($vm.StorageProfile.DataDisks.lun -contains $lunNum) {
      Write-Host "LUN conflict, incrementing by one..."
      $lunNum++
      $randomInterval = Get-Random -Minimum 20 -Maximum 60
      Start-Sleep -Seconds $randomInterval
      $vm = Get-AzVM -ResourceGroupName $targetResourceGroup -Name $proxyVM
    }
    Write-Host "Attaching disk to Proxy VM: $targetDiskName..."
    $resultUpdate = $null
    $retryCount = 0
    while ($null -eq $resultUpdate) {
      if ($retryCount -gt 4) {
        Write-Host "Too many retries trying to attach disk: $targetDiskName, exiting..."
        exit 50
      }
      $retryCount++
      try {
        # Random interval avoids Azure API throttling on concurrent VM updates
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
    Write-Host "Successfully attached disk: $targetDiskName at LUN: $lunNum" -foregroundcolor green
    [int]$lunNum++
  }
} # if ($executeAzureDiskAttach)

# Enable each VG and mount the mount points
if ($executeProxyMountCommands) {
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  $emailBody += "${currentTime}: Mounting file systems on Proxy VM `n"
  Write-Host ""
  Write-Host "On Proxy VM, re-mounting the file systems" -foregroundcolor green
  $mountCount = $MOUNT_LIST.count
  for ($mount = 0; $mount -lt $mountCount; $mount++) {
    Write-Host "Attempting to vary VG on: $($VG_LIST[$mount])..."
    $vg_name = $VG_LIST[$mount]
    $lv_name = $LV_LIST[$mount]
    # Deactivate then reactivate LVM so the kernel picks up the new underlying disk
    lvchange -an /dev/$vg_name/$lv_name
    vgchange -an $vg_name
    vgchange -ay $vg_name
    lvchange -ay /dev/$vg_name/$lv_name
    $path = $MOUNT_LIST[$mount]
    $devPath = $DEVMAPPER_LIST[$mount]
    Write-Host "Mounting $devPath to ${MOUNT_BASE}${path}..."
    mount $devPath ${MOUNT_BASE}${path}
  }
  foreach ($mountPoint in $MOUNT_LIST) {
    Write-Host ""
    Write-Host "Verifying mount point: ${MOUNT_BASE}${mountPoint}" -foregroundcolor green
    $fullMountPath = "${MOUNT_BASE}${mountPoint}"
    $output = df -h
    if ($output -like "*$fullMountPath*") {
      $output -like "*$fullMountPath*"
    } else {
      Write-Error "$fullMountPath was not mounted, exiting..."
      exit 60
    }
  }
}

$endTime = Get-Date
$elapsed = $endTime - $date
Write-Host ""
Write-Host "Script completed successfully in $([math]::Round($elapsed.TotalMinutes, 1)) minutes" -foregroundcolor green

Stop-Transcript

# Read the content of the transcript log file
$emailBody += Get-Content -Path $logPath -Raw
$emailBodyHtml = "<pre>$emailBody</pre>"

if ($sendMail) {
  # Create and send the email
  Send-MailMessage -From $emailFrom -To $emailTo -Subject $emailSubject -Body $emailBodyHtml -SmtpServer $smtpServer -BodyAsHtml $true
}

exit 0
