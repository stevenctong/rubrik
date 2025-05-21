<#
.SYNOPSIS
This script shows methods to download a vmdk from Rubrik, convert it to vhd,
upload the vhd to Azure as a page blob, and create a VM from the vhd.

.DESCRIPTION
This script shows methods to download a vmdk from Rubrik, convert it to vhd,
upload the vhd to Azure as a page blob, and create a VM from the vhd.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 5/20/25

Requirements:
- Rubrik Security Cloud PowerShell SDK: https://github.com/rubrikinc/rubrik-powershell-sdk
- Windows VM w/Hyper-V role installed: for 'Resize-VHD' and to easily check if the VHD is bootable
- qemu-img: for converting the .vmdk to a .vhd - https://www.qemu.org/download/
- Azure VM agent on the source VM: for easier troubleshooting in Azure - https://github.com/Azure/WindowsVMAgent

Azure PowerShell Notes:
Get all Azure resource SKUs: $sku = Get-AzComputeResourceSku -location <region>

Notes on conversion:
The boot volume is exported from Rubrik as a vmdk.
The volume has two files: .vmdk which is the descriptor, and -flat.vmdk that contains the data.

There are two partitioning schemes for the boot volume:
1. MBR - traditionally uses BIOS for booting, converts to Azure Gen1 VMs
2. GPT - uses uEFI for booting, converts to Azure Gen2 VM

This script currently supports converting MBR to VHDs for import to Azure.
Some modifications will need to be done to support GPT partitioned volumes.

'qemu-img' is an open source tool that is used to convert the vmdk to a vhd.
The conversion needs to be done with the 'fixed' option to allocate all bytes to the vhd.

Notes on validating the converted vhd:
You can validate the vhd with a few methods to ensure it will work in Azure.
It's easiest to perform these checks on a local Windows host w/Hyper-V role installed.
1. Disk Management - "Attach" the VHD and verify that you can browse the files.
    If it's a boot volume you should also see a "System Partition" of 100 - 500 MB in size.
    If the "System Partition" is not there then the conversion may not have been successful
    or you will need to expand the vhd and add a boot partition.
2. Hyper-V - If the vhd can be spun up in Hyper-V then it should work in Azure.
    Create a Hyper-V VM and attach the vhd as the boot disk. Verify that it can boot.

Notes on using the vhd in Azure:
To use the vhd in Azure, you upload it as a page blob to a Storage Account.
You can either create a Managed Disk directly from the vhd or a specialized or general
image to re-use it. A specialized image keeps the same copy of data while a generalized
image uses 'sysprep' to build a clean OS copy.
This script creates a Managed Disk directly from the vhd and uses that to create
a VM with that Managed Disk as the boot disk.
Some additional options for consideration:
- Size of VM
- Additional Managed Disk options - tier of disk, performance for v2 / Ultra, encryption

#>

##### Convert VMDK to VHD #####

# There should be two files, a '.vmdk' and a '-flat.vmdk'
# '.vmdk' is the descriptor file while the '-flat.vmdk' contains the data and
# System Partition (boot partition)
$qemuPath = "C:\Program Files\qemu\qemu-img.exe"
# qemu-img is pointed to the vmdk descriptor file, not the -flat file
$sourceVMDK = "C:\images\rp-fileserv-01.vmdk"
$targetVHD = "e:\rubrik-c-drive.vhd"

# Within the '.vmdk' descriptor file, there is a line for Extend description:
# Extent description
# RW 125829120 VMDK "rp-fileserv-01-flat.vmdk" 0
# We need to change 'VMDK' to 'FLAT' for PM conversion
$vmdkDescriptor = Get-Content -Path $sourceVMDK

# Search for the Line and Replace 'VMDK' with 'FLAT'
$vmdkDescriptor = $vmdkDescriptor | ForEach-Object {
  if ($_ -match 'RW\s+\d+\s+VMDK') {
      # Locate the first occurrence of 'VMDK' in a case-sensitive manner
      $Index = $_.IndexOf('VMDK')
      # Ensure the index is valid before proceeding
      if ($Index -ge 0) {
          # Replace ONLY the first 'VMDK' instance with 'FLAT'
          $ModifiedLine = $_.Substring(0, $Index) + 'FLAT' + $_.Substring($Index + 4)
          $ModifiedLine
      } else {
          $_
      }
  } else {
      # Leave lines that don't match unchanged
      $_
  }
}
# Write the Modified Content Back to the File
Set-Content -Path $sourceVMDK -Value $vmdkDescriptor

# Convert vmdk to a vhd (vpc) with 'fixed' format that allocates all space
& $qemuPath convert -f "vmdk" -O "vpc" -o "subformat=fixed" $sourceVMDK $targetVHD

# Even after conversion, Windows might mark the VHD as sparse
# Ensure that the VHD does not have the 'sparse' attribute
Get-Item $targetVHD | select-object Attributes
& fsutil sparse setflag $targetVHD 0
Get-Item $targetVHD | select-object Attributes

# Ensure that the VHD is aligned to MB and if not, re-size the VHD
$currentSize = (Get-Item $targetVHD).Length

# What the aligned size to 1 MB should be
$alignedSize = [math]::Ceiling($currentSize / 1048576) * 1048576

Get-VHD -Path $targetVHD
Write-Output "Current Size (bytes): $currentSize"
Write-Output "Aligned Size (bytes): $alignedSize"

# If VHD is not aligned to 1 MB then re-size it
if ($currentSize -ne $alignedSize) {
  Resize-VHD -Path $targetVHD -SizeBytes $alignedSize
  Get-VHD -Path $targetVHD
  $currentSize = (Get-Item $targetVHD).Length
  Write-Output "Current Size (bytes): $currentSize"
}

##### Upload VHD to Azure and Create VM #####

# Azure Subscription to login to
$subscription = 'RR-PRD'

## Variables for uploading the .VHD to a target Storage Account as a page blob
$resourceGroup = "rr-tong-lighthouse"
$storageAccountName = "rrtonglighthouse150"
$storageContainerName = "vhds"
$location = "eastus2" # for example, 'eastus'
$localVhdPath = "e:\rubrik-c-drive.vhd"
$storageBlobName = "rubrik-c-drive.vhd"

## Variables for creating the Managed Disk from the uploaded .vhd
$diskName = "tong-lh-c-drive-01"
# Options: Standard_LRS, Premium_LRS, Premium_ZRS,
# StandardSSD_LRS, StandardSSD_ZRS, PremiumV2_LRS, UltraSSD_LRS
$skuName = "StandardSSD_LRS"

## Variables for creating the VM from the Managed Disk
$vmName = "tong-lh-vm-01"
$vmSize = "Standard_E2_v5"
$vnetRG = "rg-rr2-eastus2-networking"
$vnetName = "vnet-rr2-eastus2"
$subnetName = "main1"
$nicName = "tong-lh-vm-01-nic-01"
$nsgName = "rr-tong-nsg"

# Login to Azure PowerShell
Connect-AzAccount -subscription $subscription
Get-AzContext

### Upload the VHD to the Azure Storage Account as a page blob

# Get Storage Account context where the VHD will be uploaded to
$storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroup -Name $storageAccountName
$ctx = $storageAccount.Context

# Upload the VHD as a page blob (mandatory blob type for images & disks)
Set-AzStorageBlobContent `
    -File $localVhdPath `
    -Container $storageContainerName `
    -Blob $storageBlobName `
    -Context $ctx `
    -BlobType Page

### Create a Managed Disk from the uploaded VHD

# Uri of the VHD based on where it was uploaded
$vhdUri = "https://$storageAccountName.blob.core.windows.net/$storageContainerName/$storageBlobName"

# Create a Managed Disk Config based on the uploaded vhd
# Note: additional options are available for creation of Managed Disk
# Eg. if using v2 / Ultra SSDs, disk IOPs and MBps
$diskConfig = New-AzDiskConfig `
    -SkuName $skuName `
    -Location $location `
    -CreateOption Import `
    -SourceUri $vhdUri `
    -StorageAccountId $storageAccount.Id

# Create the Managed Disk using the Managed Disk Config
$managedDisk = New-AzDisk `
    -ResourceGroupName $resourceGroup `
    -DiskName $diskName `
    -Disk $diskConfig

# Check on the created Managed Disk
$disk = Get-AzDisk -ResourceGroupName $resourceGroup -DiskName $diskName
$disk | Select-Object Name, @{n='SkuName';e={$_.Sku.Name}}, DiskSizeGB, ProvisioningState, DiskState, OsType, Location, @{n='SourceUri';e={$disk.CreationData.SourceUri}}

### Create a VM from the Managed Disk

# Get the VNET, Subnet, and NSG details of where to create the VM NIC
$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRG
$subnet = $vnet | Select-Object -ExpandProperty Subnets | Where-Object Name -eq $subnetName
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $resourceGroup -Name $nsgName

# Create a new NIC
$nic = New-AzNetworkInterface -Name $nicName `
  -ResourceGroupName $resourceGroup `
  -Location $location `
  -SubnetId $subnet.Id `
  -NetworkSecurityGroupId $nsg.Id `
  -EnableAcceleratedNetworking

# Create a VM Config and attach the Managed Disk and NIC to it
$vmConfig = New-AzVMConfig -VMName $vmName -VMSize $vmSize
$vmConfig = Set-AzVMOSDisk -VM $vmConfig `
  -ManagedDiskId $disk.Id `
  -Windows `
  -CreateOption Attach
$vmConfig = Add-AzVMNetworkInterface -VM $vmConfig `
  -Id $nic.Id

# Create the VM using the VM Config as a background job
$vmJob = New-AzVM -ResourceGroupName $resourceGroup `
  -Location $location `
  -VM $vmConfig `
  -Verbose `
  -AsJob

# Check on the Job Status
Get-Job -Id $vmJob.id | Select *
