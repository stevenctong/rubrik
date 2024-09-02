# https://www.rubrik.com/api
<#
.SYNOPSIS
This script will create a snapshot and disk clone for Epic IRIS ODB backups
in Azure for v2 / Ultra SSDs.

.DESCRIPTION
This script will create a snapshot and disk clone for Epic IRIS ODB backups
in Azure for v2 / Ultra SSDs.

Variables should be filled out in order to run this script correctly.

The script supports creating the snapshots from a Prod VM in one subscription
and creating the clone of the disks to a Proxy VM in another subscription.

For v2 / Ultra disks, the performance config depends on disk size. The script has
some error handling to check for a valid config and sets it to the max value
if the disk config throws an error.

The script performs the following tasks:

1. SSH to PROD VM - Freeze IRIS ODB
   ** ssh <user>@<iris_host> '<instafreeze>'
   ** Also sends command via sleep to automatically 'instathaw' after x minutes
2. Azure - Create v2/Ultra SSD snapshot
3. SSH to PROD VM - Thaw IRIS ODB
   ** ssh <user>@<iris_host> '<instathaw>'
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
   ** mount -a
      Note: The disks should be in /etc/fstab
11. Rubrik backup begins

The snapshot and the cloned Managed Disks wil be the same name as the source disk
but appended with a 'suffix' and datestamped.

.NOTES
Written by Steven Tong for usage with Rubrik
GitHub: stevenctong
Date: 8/30/24

PRE-REQUISITES:
1. IRIS PROD VM has the Proxy VM keys as 'authorized_keys' for SSH commands
2. Proxy VM has the disk mount mounts configured in /etc/fstab
   ** Use 'blkid' to get the UUID of the lvm to add to /etc/fstab:
      /dev/mapper/vg--prd01-lvm--prd01: UUID="26f0deef-c81e-4885-bf43-26b89a1bbe8c" TYPE="xfs"
      /dev/mapper/vg--prd02-lvm--prd02: UUID="b172cbc8-6947-441a-9084-1d1be3395d77" TYPE="xfs"
   ** /etc/fstab example:
      UUID=26f0deef-c81e-4885-bf43-26b89a1bbe8c   /epic/prd01  xfs  defaults   0 0
      UUID=b172cbc8-6947-441a-9084-1d1be3395d77   /epic/prd02  xfs  defaults   0 0
3. Azure authentication for script - either as a Service Principal or
   a Managed Identity on the VM (eg Proxy VM) that the script wil be running
   from with the appropriate role/permissions

.EXAMPLE
./New-v2-Ultra-Snapshot.ps1
Execute the scripts according to the variables within the script.

#>

$date = Get-Date
$dateString = $date.ToString("yyyy-MM-dd_HHmm")

# Log directory
# $logDir = './logs'
# $logPath = "${logDir}/rubrik_azure_snap_script-${dateString}).log"
# Start-Transcript -path $logPath -append

# Whether to execute certain groups of commands as break points
$executeAzureCommands = $true
$executeEpicCommands = $false
$executeDiskUnmountCommands = $false
$executeMountCommands = $false

##### BEGIN - VARIABLES #####

### Variables for Azure

# Subscription & Resource Group of the source disks
$sourceSubscriptionId = ''
$sourceResourceGroup = ''

# Names of source disks that will be cloned in a list
$sourceDisks = @('datadisk-01', 'datadisk-02')

# Target subscription of the Proxy VM you want to clone to disks to
$targetSubscriptionId = ''
$targetResourceGroup = ''

# Name of the Proxy VM you want to mount the cloned disks to
$proxyVM = ''

# Snapshots will be appended with -${sourceSnapshotSuffix}-${dateString}
$sourceSnapshotSuffix = 'rubrik-snap'

# The name of the new disks on the Proxy VM will be appended with the following
# suffix based on the name of each source disk and-${targetDiskSuffix}-${dateString}
$targetDiskSuffix = 'rubrik-disk'


# Performance config for v2 / Ultra cloned Managed Disks
# Acceptable values also depends on the size of the v2 / Ultra Managed Disks
# Script has error handling if out of bounds to set to its max discovered value
$DiskMBpsReadWrite = 800
$DiskMBpsReadOnly = 800
$DiskIOPSReadWrite = 10000
$DiskIOPSReadOnly = 10000

# Time to wait between status checks, in seconds
$statusCheckSecs = 120

### Variables for Proxy VM commands - mount variables & Epic freeze / thaw

$MOUNT_BASE = '/epic'
$MOUNT_LIST = @( '/prd01', '/prd02' )
$VG_LIST = @( 'vg-prd01', 'vg-prd02' )

$EPIC_FREEZE_CMD = '/epic/prd/bin/instfreeze'
$EPIC_THAW_CMD = '/epic/prd/bin/instthaw'
$EPIC_AUTOTHAW_CMD = "nohup sh -c '(sleep 5m && ${EPIC_THAW_CMD}) > /dev/null 2>&1 &'"
$EPIC_PRD_SERVER = ''
$EPIC_PRD_USER = 'root'

### Variables SMTP to send an email
# Email has not been added yet to the script, for future
# $emailTo = @('')
# $emailFrom = ''
# $SMTPServer = ''
# $SMTPPort = '25'
# $emailSubject = "Rubrik Azure Script - " + $date.ToString("yyyy-MM-dd HH:MM")

##### END - VARIABLES #####


#### Login to Azure and initialization of some variables ####

if ($executeAzureCommands) {
  Connect-AzAccount
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
  $index = 0
  foreach ($disk in $sourceDisks) {
    Write-Host "Source Disk Name: $disk"
    Write-Host "Source Snapshot Name: $($sourceDiskToSnapshot.$disk)"
    Write-Host "Target Disk Name: $($sourceDiskToTargetDisk.$disk)"
    Write-Host ""
    $index++
  }
  Write-Host ""
}

#### Create snapshot of each source disk ####
# https://learn.microsoft.com/en-us/azure/virtual-machines/disks-incremental-snapshots?tabs=azure-powershell

# Send command to IRIS PRD server to freeze and set auto-thaw
if ($executeEpicCommands) {
  Write-Host "Sending command to freeze & auto-thaw IRIS ODB..." -foregroundcolor cyan
  ssh ${EPIC_PRD_USER}@${EPIC_PRD_SERVER} ${EPIC_FREEZE_CMD} 2>&1
  ssh ${EPIC_PRD_USER}@${EPIC_PRD_SERVER} ${EPIC_AUTOTHAW_CMD} 2>&1
}

if ($executeAzureCommands) {
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
    #### Snapshot should be a 7 day retention, write logic to delete anything after 7 days
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


#### Switch Subscription Context ####
# If the Proxy VM is in a different subscription, the rest of Azure commands will
# performed in the target subscription
if ($sourceSubscriptionId -ne $targetSubscriptionId) {
  Write-Host ""
  Write-Host "Target subscription is different, switching to: $targetSubscriptionId"
  $result = Set-AzContext -Subscription $targetSubscriptionId
  Write-Host "Context set: $($result.name)"
}


#### Create a Managed Disk from the snapshot ####
# https://learn.microsoft.com/en-us/azure/virtual-machines/scripts/virtual-machines-powershell-sample-create-managed-disk-from-snapshot
# https://learn.microsoft.com/en-us/powershell/module/az.compute/new-azdiskconfig

if ($executeAzureCommands) {
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
        # exit
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
        Write-Host "Disk copy: $($diskInfo.name), completion: $($diskInfo.CompletionPercent), waiting another $statusCheckSecs secs..."
      } else {
        Write-Host "Disk copy: $($diskInfo.name), completion: $($diskInfo.CompletionPercent)" -foregroundcolor green
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
if ($executeDiskUnmountCommands) {
  foreach ($mountPoint in $MOUNT_LIST) {
    umount ${MOUNT_BASE}${mountPoint}
  }
  foreach ($vg in $VG_LIST) {
    vgchange -an $vg
  }
}

if ($executeAzureCommands) {
  Write-Host ""
  Write-Host "Detaching existing data disks and deleting them from the Proxy VM" -foregroundcolor green

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
      # if the data disk matches, then add it to the list to detach
      if ($proxyVmDisk.name -match $disk) {
        $disksToDetach += $proxyVmDisk.name
      }
    }
  }
  # Detach and delete all the disks that were matched
  foreach ($diskDetatch in $disksToDetach) {
    # Detach the disk from the VM
    $resultRemove = Remove-AzVMDataDisk -VM $vm -Name $diskDetatch -ErrorAction Stop
    $resultUpdate = Update-AzVM -VM $vm -ResourceGroupName $targetResourceGroup -ErrorAction Stop
    Write-Host "Deleting existing disk on the Proxy VM: $diskDetatch..."
    # Delete the disk
    $result = Remove-AzDisk -Name $diskDetatch -ResourceGroupName $targetResourceGroup -force -ErrorAction Stop
    Write-Host "Deletion result: $($result.status)"
  }
} # If ($executeAzureCommands)


#### Attach Managed Disk to proxy VM ####
# https://learn.microsoft.com/en-us/azure/virtual-machines/windows/attach-disk-ps

if ($executeAzureCommands) {
  Write-Host ""
  Write-Host "Attaching new Managed Disks to the Proxy VM" -foregroundcolor green

  $vm = Get-AzVM -ResourceGroupName $targetResourceGroup -Name $proxyVM
  $lunNum = 0
  ###### Can also use the managed disk names in order to attach to a specific LUN number

  # For each source disk, will then get the target disk name to attach
  foreach ($disk in $sourceDisks) {
    $targetDiskName = $sourceDiskToTargetDisk[$disk]
    try {
      Write-Host "Attaching disk to Proxy VM: $targetDiskName..."
      $diskInfo = Get-AzDisk -DiskName $targetDiskName -ResourceGroupName $targetResourceGroup -ErrorAction Stop
      $vm = Add-AzVMDataDisk -CreateOption Attach -Lun $lunNum -VM $vm -ManagedDiskId $diskInfo.Id -ErrorAction Stop
      Update-AzVM -VM $vm -ResourceGroupName $targetResourceGroup -ErrorAction Stop
      $lunNum++
    } catch {
      # In case it fails to get the disk info, try again one more time
      Start-Sleep 10
      Write-Host "Attaching disk to Proxy VM: $targetDiskName..."
      $diskInfo = Get-AzDisk -DiskName $targetDiskName -ResourceGroupName $targetResourceGroup -ErrorAction Stop
      $vm = Add-AzVMDataDisk -CreateOption Attach -Lun $lunNum -VM $vm -ManagedDiskId $diskInfo.Id -ErrorAction Stop
      Update-AzVM -VM $vm -ResourceGroupName $targetResourceGroup -ErrorAction Stop
      $lunNum++
    }
  }
} # If ($executeAzureCommands)

# Enable each VG and mount the mount points
# The mount definitions should put in /etc/fstab
if ($executeDiskMountCommands) {
  foreach ($vg in $VG_LIST) {
    vgchange -ay $vg
  }
  mount -a
  foreach ($mountPoint in $MOUNT_LIST) {
    if ($output -like "*$mountPoint*") {
      $output -like "*$mountPoint*"
    } else {
      Write-Error "$mountPoint was not mounted"
    }
  }
}

# Stop-Transcript
