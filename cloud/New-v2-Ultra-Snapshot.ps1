<#
#### IRIS Script ####

1. Freeze IRIS ODB -
** ssh -i <ssh.pem> <user>@<iris_host> '<instafreeze>'
** Also add to cron to automatically 'instathaw' after 9 minutes
2. Create Ultra SSD snapshot
3. Thaw IRIS ODB
** ssh -i <ssh.pem> <user>@<iris_host> '<instathaw>'
4. Create Managed Disk from Snapshot
5. Proxy VM - Prep the Proxy VM for refreshed Managed Disk
** unmount /epic/prd01
** lvchange -an /dev/vg-prd01/prd01
** vgchange -an vg-prd01
6. Mount Managed Disk onto Proxy VM
7. Proxy VM - Re-Mount the refreshed Managed Disk
** vgchange -ay vg-prd01
** lvchange -ay /dev/vg-prd01/prd01
** mount /dev/vg-prd01/prd01 /epic/prd01
8. Backup begins

#>

Connect-AzAccount

$date = Get-Date
$dateString = $date.ToString("yyyy-MM-dd_HHmm")

# Time to wait between status checks, in seconds
$statusCheckSecs = 60

$subscriptionId = 'b2e9b0af-7820-42f8-b1cb-e9780a1cde59'
$resourceGroup = 'rg-tong-ultra'

$proxyVM = 'tong-proxy-vm'

#### Create an incremental snapshot of a Ultra / v2 disk ####
# https://learn.microsoft.com/en-us/azure/virtual-machines/disks-incremental-snapshots
# Ultra / v2 disks perform a background copy

# Provide the list of source disks that will be snapshot
$sourceDisks = @('vm-ultra-01_DataDisk_0', 'vm-ultra-01_DataDisk_1')
$diskCount = $sourceDisks.count

# Provide the list of target disks that are mounted on the proxy VM
# that the snapshots will be refreshed to
# Make sure that the order is the same between source-target
# $targetDisks = @('tong-ultra-diskcopy-01', 'tong-ultra-diskcopy-02')

# The name of the disks on the Proxy VM will be appended with the following suffix
# based on the name of each source disk.
$targetDiskSuffix = 'rubrik'

# Create source disk to target disk name mapping
$sourceDiskToTargetDisk = @{}
foreach ($disk in $sourceDisks) {
  $sourceDiskToTargetDisk.$disk = "${disk}-${targetDiskSuffix}"
}

Write-Host "Date: $date"
Write-Host "Subcription ID: $subscriptionId"
Write-Host "Resource Group: $resourceGroup"
Write-Host ""
Write-Host "$diskCount disks will be snapshot and refreshed:"
$index = 0
foreach ($disk in $sourceDisks) {
  Write-Host "Source Disk: $disk,  Target Disk: $($sourceDiskToTargetDisk.$disk)"
  $index++
}

Write-Host ""

# Holds the source disk to snapshot name lookup
$sourceDiskToSnapshot = @{}

# Create a snapshot for each disk
foreach ($disk in $sourceDisks) {
  # Snapshot for each disk will be named with the following: <source_disk>-rubrik-<timestamp>
  $snapshotName = "$disk-rubrik-$dateString"
  $sourceDiskToSnapshot.$disk = $snapshotName
  Write-Host "Creating snapshot for disk: $disk, snapshot name: $snapshotName..."
  # Get the disk info that you need to backup by creating an incremental snapshot
  $diskInfo = Get-AzDisk -DiskName $disk -ResourceGroupName $resourceGroup
  # Create an incremental snapshot by setting the SourceUri property with the value of the Id property of the disk
  $snapshotConfig=New-AzSnapshotConfig -SourceUri $diskInfo.Id -Location $diskInfo.Location -CreateOption Copy -Incremental
  $result = New-AzSnapshot -ResourceGroupName $resourceGroup -SnapshotName $snapshotName -Snapshot $snapshotConfig
  Write-Host "Snapshot result: $($result.ProvisioningState)"
}

Write-Host ""
Write-Host "Waiting for $diskCount incremental snapshots to finish background copy..."
Write-Host ""

# Hash table of snapshots that have completed their background copy
$snapshotComplete = @{}

# For each incremental snapshot, check and wait until the background copy completes
while ($snapshotComplete.count -lt $diskCount) {
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  # Check the status of each snapshot operation
  foreach ($snapshot in $sourceDiskToSnapshot.getEnumerator()) {
    $snapshotInfo = Get-AzSnapshot -ResourceGroupName $resourceGroup -SnapshotName $snapshot.value
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

#### Detach Managed Disk from the Proxy VM ####
# https://learn.microsoft.com/en-us/azure/virtual-machines/windows/detach-disk

Write-Host ""
Write-Host "Detaching existing data disks and delete them from the Proxy VM..."

foreach ($disk in $sourceDisks) {
  $targetDiskName = $sourceDiskToTargetDisk[$disk]
  Write-Host "Detaching disk from Proxy VM: $targetDiskName..."
  $vm = Get-AzVM -ResourceGroupName $resourceGroup -Name $proxyVM
  $resultRemove = Remove-AzVMDataDisk -VM $vm -Name $targetDiskName
  $resultUpdate = Update-AzVM -VM $vm -ResourceGroupName $resourceGroup
  Write-Host "Deleting Proxy VM disk: $targetDiskName..."
  $result = Remove-AzDisk -Name $targetDiskName -ResourceGroupName $resourceGroup -force
  Write-Host "Deletion result: $($result.status)"
}


#### Create a Managed Disk from the snapshot ####
# https://learn.microsoft.com/en-us/azure/virtual-machines/scripts/virtual-machines-powershell-sample-create-managed-disk-from-snapshot
# https://learn.microsoft.com/en-us/powershell/module/az.compute/new-azdiskconfig

Write-Host ""
Write-Host "Starting Managed Disk creation from snapshots..."

foreach ($disk in $sourceDisks) {
  $targetDiskName = $sourceDiskToTargetDisk[$disk]
  $diskInfo = Get-AzDisk -DiskName $disk -ResourceGroupName $resourceGroup
  $snapshotInfo = Get-AzSnapshot -ResourceGroupName $resourceGroup -SnapshotName $sourceDiskToSnapshot[$disk]
  Write-Host "Building disk config for: $disk, $($sourceDiskToSnapshot[$disk]) for target: $targetDiskName"
  $diskConfigParameters = @{
    CreateOption = "Copy"
    SourceResourceId = $snapshotInfo.Id
    DiskSizeGB = $diskInfo.DiskSizeGB
    SkuName = $diskInfo.sku.name
    Zone = $diskInfo.zones[0]
    Location = $diskInfo.location
    DiskIOPSReadWrite = $diskInfo.DiskIOPSReadWrite
    DiskIOPSReadOnly = $diskInfo.DiskIOPSReadOnly
    DiskMBpsReadWrite = $diskInfo.DiskMBpsReadWrite
    DiskMBpsReadOnly = $diskInfo.DiskMBpsReadOnly
  }
  $diskConfigParameters
  $diskConfig = New-AzDiskConfig @diskConfigParameters
  Write-Host ""
  Write-Host "Creating new Managed Disk: $targetDiskName..." -foregroundcolor green
  $result = New-AzDisk -Disk $diskConfig -ResourceGroupName $resourceGroup -DiskName $targetDiskName
  Write-Host "Managed Disk creation result: $($result.ProvisioningState)"
}

Write-Host "Waiting until snapshot to Managed Disk background copy completes..."

# Hash table of Managed Disks that have completed their background copy
$diskComplete = @{}

# For each Managed Disk copy, check and wait until the background copy completes
while ($diskComplete.count -lt $diskCount) {
  $currentTime = Get-Date -format "yyyy-MM-dd HH:mm"
  # Check the status of each Managed Disk operation
  foreach ($disk in $sourceDisks) {
    $targetDiskName = $sourceDiskToTargetDisk[$disk]
    $diskInfo = Get-AzDisk -DiskName $targetDiskName -ResourceGroupName $resourceGroup
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
}

Write-Host "All $diskCount Managed Disks have finished background copy" -foregroundcolor green


#### Attach Managed Disk to proxy VM ####
# https://learn.microsoft.com/en-us/azure/virtual-machines/windows/attach-disk-ps

Write-Host "Attaching new Managed Disks to the Proxy VM..."

$vm = Get-AzVM -ResourceGroupName $resourceGroup -Name $proxyVM

$lunNum = 0

foreach ($disk in $sourceDisks) {
  $targetDiskName = $sourceDiskToTargetDisk[$disk]
  $diskInfo = Get-AzDisk -DiskName $targetDiskName -ResourceGroupName $resourceGroup
  Write-Host "Attaching disk to Proxy VM: $targetDiskName..."
  $vm = Add-AzVMDataDisk -CreateOption Attach -Lun $lunNum -VM $vm -ManagedDiskId $diskInfo.Id
  Update-AzVM -VM $vm -ResourceGroupName $resourceGroup
  $lunNum++
}
