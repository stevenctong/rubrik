<#
.SYNOPSIS
This script uploads a vhd to Azure and creates a VM from it.

.DESCRIPTION
This script uploads a vhd to Azure and creates a VM from it.

If the vhd is MBR it will create a Gen 1 Managed Disk.
If the vhd is GPT it will create a Gen 2 Managed Disk.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 5/28/25

Requirements:
- Azure VM agent on the source VM: for easier troubleshooting in Azure - https://github.com/Azure/WindowsVMAgent

Azure PowerShell Notes:
Get all Azure resource SKUs: $sku = Get-AzComputeResourceSku -location <region>

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

.EXAMPLE
./Upload-VHD-Create-AzureVM.ps1 -vmName <VM Name> -sourceVHD <filename of VHD>.ps1
  Uploads and creates an Azure VM from the source VHD file.

#>

param (
  [CmdletBinding()]
  # Azure VM Name - VM resource names will be derived from this
  [Parameter(Mandatory=$true)]
  [string]$vmName = '',
  # Source VHD file to upload
  [Parameter(Mandatory=$true)]
  [string]$sourceVHD = ''
)

$date = Get-Date

# Azure Subscription to login to
$subscription = 'RR-PRD'

## Variables for uploading the .VHD to a target Storage Account as a page blob
$resourceGroup = "rr-tong-lighthouse"
$storageAccountName = "rrtonglighthouse150"
$storageContainerName = "vhds"
$location = "eastus2"

# Managed Disk sku type
# Options: Standard_LRS, Premium_LRS, Premium_ZRS,
# StandardSSD_LRS, StandardSSD_ZRS, PremiumV2_LRS, UltraSSD_LRS
$skuName = "StandardSSD_LRS"

# VM disk sku type
$vmSize = "Standard_E2_v5"

# Networking details
$vnetRG = "rg-rr2-eastus2-networking"
$vnetName = "vnet-rr2-eastus2"
$subnetName = "main1"
$nsgName = "rr-tong-nsg"

## Derived Variables

# $storageBlobName is the name of the blob file that will be uploaded from the vhd
$filename = Split-Path -Path $sourceVHD -Leaf
$storageBlobName = $filename

# Managed Disk name
$diskName = $vmName + "-disk-01"

# NIC name
$nicName = $vmName + "-nic-01"


## Variables for testing

# $vmName = 'tong-lh-vm-01'
# $sourceVHD = "e:\rubrik-c-drive.vhd"
# $storageBlobName = "rubrik-c-drive.vhd"
# $diskName = "tong-lh-c-drive-01"
# $nicName = "tong-lh-vm-01-nic-01"


# Login to Azure PowerShell
Connect-AzAccount -subscription $subscription
Get-AzContext

### Upload the VHD to the Azure Storage Account as a page blob

# Get Storage Account context where the VHD will be uploaded to
$storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroup -Name $storageAccountName
$ctx = $storageAccount.Context

# Upload the VHD as a page blob (mandatory blob type for images & disks)
Set-AzStorageBlobContent `
    -File $sourceVHD `
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
